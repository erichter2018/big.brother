import Foundation
import CoreLocation
import MapKit
import BigBrotherCore

// MARK: - RouteCache

/// Shared route caching utilities used by both LocationMapView and RouteProcessingService.
/// Extracted from LocationMapView so background pre-processing can populate the same cache.
enum RouteCache {

    /// Directory for cached route polyline files.
    static var cacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("route-cache", isDirectory: true)
    }

    /// Cache key from rounded coordinates (4 decimal places ~ 11m precision).
    static func routeCacheKey(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> String {
        let r = { (v: Double) in String(format: "%.4f", v) }
        return "\(r(from.latitude)),\(r(from.longitude))-\(r(to.latitude)),\(r(to.longitude))"
    }

    /// Persist a polyline to disk under the given cache key.
    static func cacheRoute(_ polyline: MKPolyline, key: String) {
        let dir = cacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let count = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        let encoded = coords.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";")
        let file = dir.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)
        try? encoded.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Load a previously cached polyline. Returns nil on cache miss.
    static func loadCachedRoute(key: String) -> MKPolyline? {
        let file = cacheDir.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let coords = data.split(separator: ";").compactMap { part -> CLLocationCoordinate2D? in
            let comps = part.split(separator: ",")
            guard comps.count == 2, let lat = Double(comps[0]), let lon = Double(comps[1]) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard coords.count >= 2 else { return nil }
        return MKPolyline(coordinates: coords, count: coords.count)
    }

    /// Check whether a segment between two waypoints already has a cached route.
    static func hasCachedRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Bool {
        let key = routeCacheKey(from: from, to: to)
        let file = cacheDir.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)
        return FileManager.default.fileExists(atPath: file.path)
    }
}

// MARK: - RouteProcessingService

/// Background service that pre-processes driving trip routes and speed limits
/// so the parent sees instant map loads when opening a child's location view.
///
/// Processing pipeline per trip:
///   1. Snap GPS breadcrumbs to roads via MKDirections (segment-by-segment)
///   2. Pre-fetch Overpass speed limits for each breadcrumb coordinate
///   3. Mark trip as processed in UserDefaults to avoid re-work
///
/// Runs automatically when the parent app foregrounds. Non-blocking, background queue.
/// Throttles MKDirections calls (300ms apart) to respect Apple rate limits.
final class RouteProcessingService: @unchecked Sendable {

    static let shared = RouteProcessingService()

    /// Minimum distance between waypoints for MKDirections queries (meters).
    private static let waypointMinDistance: CLLocationDistance = 200

    /// Delay between MKDirections API calls to avoid rate limiting.
    private static let directionsThrottleMs: UInt64 = 300

    /// How far back to fetch breadcrumbs (days).
    private static let lookbackDays: TimeInterval = 7 * 86400

    /// Minimum trip distance to process (meters). Ignore short walks.
    private static let minimumTripDistance: Double = 500

    /// Radius for stationary detection (meters).
    private static let stationaryRadius: Double = 80

    /// Maximum dwell between legs to merge into same trip (seconds).
    private static let maxDwellForSameTrip: TimeInterval = 1800

    /// UserDefaults key prefix for tracking processed trips.
    private static let processedKeyPrefix = "routeProcessed."

    /// Active processing task. Checked to avoid duplicate runs.
    private var activeTask: Task<Void, Never>?

    /// Whether processing is currently running.
    private(set) var isProcessing = false

    private init() {}

    // MARK: - Public API

    /// Trigger background route processing for all children.
    /// Safe to call multiple times; concurrent calls are coalesced.
    func processIfNeeded(
        cloudKit: any CloudKitServiceProtocol,
        childDevices: [ChildDevice],
        familyID: FamilyID
    ) {
        // Don't start a new run if one is already active.
        guard activeTask == nil else {
            BBLog("[RouteProcessing] Already running — skipping")
            return
        }

        // Capture values and run on a background task.
        let devices = childDevices
        let fid = familyID

        activeTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await MainActor.run { self.isProcessing = true }

            BBLog("[RouteProcessing] Starting background route processing for \(devices.count) devices")
            let startTime = CFAbsoluteTimeGetCurrent()

            await self.processAllDevices(cloudKit: cloudKit, devices: devices, familyID: fid)

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            BBLog("[RouteProcessing] Complete in \(String(format: "%.1f", elapsed))s")

            await MainActor.run {
                self.isProcessing = false
                self.activeTask = nil
            }
        }
    }

    /// Cancel any in-progress processing.
    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isProcessing = false
    }

    // MARK: - Core Processing

    private func processAllDevices(
        cloudKit: any CloudKitServiceProtocol,
        devices: [ChildDevice],
        familyID: FamilyID
    ) async {
        let since = Date().addingTimeInterval(-Self.lookbackDays)

        // Fetch breadcrumbs for all devices, grouped by device.
        var allBreadcrumbs: [DeviceID: [DeviceLocation]] = [:]
        for device in devices {
            guard !Task.isCancelled else { return }
            do {
                let crumbs = try await cloudKit.fetchLocationBreadcrumbs(
                    deviceID: device.id, since: since
                )
                if !crumbs.isEmpty {
                    allBreadcrumbs[device.id] = crumbs.sorted { $0.timestamp < $1.timestamp }
                }
            } catch {
                BBLog("[RouteProcessing] Failed to fetch breadcrumbs for \(device.displayName): \(error.localizedDescription)")
            }
        }

        guard !allBreadcrumbs.isEmpty else {
            BBLog("[RouteProcessing] No breadcrumbs found — nothing to process")
            return
        }

        // Detect and process trips per device.
        var totalTrips = 0
        var processedTrips = 0
        var skippedTrips = 0

        for (deviceID, breadcrumbs) in allBreadcrumbs {
            guard !Task.isCancelled else { return }

            let trips = detectTrips(from: breadcrumbs)
            totalTrips += trips.count

            for trip in trips {
                guard !Task.isCancelled else { return }

                let tripKey = Self.tripProcessedKey(
                    deviceID: deviceID,
                    startTime: trip.startTime,
                    endTime: trip.endTime
                )

                if Self.isTripProcessed(key: tripKey) {
                    skippedTrips += 1
                    continue
                }

                BBLog("[RouteProcessing] Processing trip: \(trip.startTime) -> \(trip.endTime) (\(trip.breadcrumbCount) points)")

                // Step 1: Snap route to roads via MKDirections.
                let routeResult = await snapRouteToRoads(
                    breadcrumbs: Array(breadcrumbs[trip.startIndex...trip.endIndex])
                )

                guard !Task.isCancelled else { return }

                // Step 2: Pre-fetch speed limits along the route.
                await prefetchSpeedLimits(
                    breadcrumbs: Array(breadcrumbs[trip.startIndex...trip.endIndex])
                )

                guard !Task.isCancelled else { return }

                // Mark trip as processed.
                Self.markTripProcessed(key: tripKey)
                processedTrips += 1

                BBLog("[RouteProcessing] Trip done: \(routeResult.cachedSegments)/\(routeResult.totalSegments) cached, \(routeResult.newSegments) new")
            }
        }

        // Force-save speed limit cache to disk.
        await SpeedLimitService.shared.persistToDisk()

        BBLog("[RouteProcessing] Summary: \(totalTrips) trips total, \(processedTrips) processed, \(skippedTrips) already cached")
    }

    // MARK: - Route Snapping (MKDirections)

    private struct RouteResult {
        let totalSegments: Int
        let cachedSegments: Int
        let newSegments: Int
    }

    private func snapRouteToRoads(breadcrumbs: [DeviceLocation]) async -> RouteResult {
        let points = breadcrumbs.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard points.count >= 2 else {
            return RouteResult(totalSegments: 0, cachedSegments: 0, newSegments: 0)
        }

        // Build waypoints filtering out points too close together (>200m apart).
        var waypoints: [CLLocationCoordinate2D] = [points[0]]
        for i in 1..<points.count {
            let prev = waypoints.last!
            let dist = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                .distance(from: CLLocation(latitude: points[i].latitude, longitude: points[i].longitude))
            if dist > Self.waypointMinDistance {
                waypoints.append(points[i])
            }
        }
        // Ensure last point is included.
        if let last = points.last, let wLast = waypoints.last,
           (wLast.latitude != last.latitude || wLast.longitude != last.longitude) {
            waypoints.append(last)
        }

        guard waypoints.count >= 2 else {
            return RouteResult(totalSegments: 0, cachedSegments: 0, newSegments: 0)
        }

        let totalSegments = waypoints.count - 1
        var cachedSegments = 0
        var newSegments = 0

        for i in 0..<totalSegments {
            guard !Task.isCancelled else { break }

            let from = waypoints[i]
            let to = waypoints[i + 1]
            let cacheKey = RouteCache.routeCacheKey(from: from, to: to)

            // Check cache first.
            if RouteCache.loadCachedRoute(key: cacheKey) != nil {
                cachedSegments += 1
                continue
            }

            // Query MKDirections.
            let source = MKMapItem(placemark: MKPlacemark(coordinate: from))
            let dest = MKMapItem(placemark: MKPlacemark(coordinate: to))

            let request = MKDirections.Request()
            request.source = source
            request.destination = dest
            request.transportType = .automobile

            do {
                let directions = MKDirections(request: request)
                let response = try await directions.calculate()
                if let route = response.routes.first {
                    RouteCache.cacheRoute(route.polyline, key: cacheKey)
                    newSegments += 1
                }
            } catch {
                // On failure, cache a straight-line fallback so we don't retry.
                let coords = [from, to]
                let fallback = MKPolyline(coordinates: coords, count: 2)
                RouteCache.cacheRoute(fallback, key: cacheKey)
                newSegments += 1
            }

            // Throttle between non-cached requests.
            if i < totalSegments - 1 {
                try? await Task.sleep(nanoseconds: Self.directionsThrottleMs * 1_000_000)
            }
        }

        return RouteResult(
            totalSegments: totalSegments,
            cachedSegments: cachedSegments,
            newSegments: newSegments
        )
    }

    // MARK: - Speed Limit Pre-fetching

    private func prefetchSpeedLimits(breadcrumbs: [DeviceLocation]) async {
        var coords: [CLLocationCoordinate2D] = []
        var seen = Set<String>()

        for bc in breadcrumbs {
            // Deduplicate by rounded coordinate (~150m precision, matching geohash).
            let key = "\(String(format: "%.3f", bc.latitude)),\(String(format: "%.3f", bc.longitude))"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            coords.append(CLLocationCoordinate2D(latitude: bc.latitude, longitude: bc.longitude))
        }

        guard !coords.isEmpty else { return }

        // Query in batches of 5 concurrently (matches LocationMapView behavior).
        for batch in stride(from: 0, to: coords.count, by: 5) {
            guard !Task.isCancelled else { return }
            let end = min(batch + 5, coords.count)
            await withTaskGroup(of: Void.self) { group in
                for i in batch..<end {
                    group.addTask {
                        let _ = await SpeedLimitService.shared.speedLimit(at: coords[i])
                    }
                }
            }
        }
    }

    // MARK: - Trip Detection (mirrored from LocationMapView)

    /// Lightweight trip descriptor for background processing.
    private struct DetectedTrip {
        let startIndex: Int
        let endIndex: Int
        let startTime: Date
        let endTime: Date
        let distanceMeters: Double

        var breadcrumbCount: Int { endIndex - startIndex + 1 }
    }

    /// Detect driving trips from breadcrumbs. Mirrors LocationMapView.detectTrips().
    private func detectTrips(from breadcrumbs: [DeviceLocation]) -> [DetectedTrip] {
        guard breadcrumbs.count >= 2 else { return [] }

        struct Leg {
            let startIndex: Int
            let endIndex: Int
            let distance: Double
        }

        var legs: [Leg] = []
        var legStartIdx: Int?
        var legDistance: Double = 0

        for i in 1..<breadcrumbs.count {
            let prev = breadcrumbs[i - 1]
            let curr = breadcrumbs[i]
            let dist = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                .distance(from: CLLocation(latitude: curr.latitude, longitude: curr.longitude))

            if dist >= Self.stationaryRadius {
                if legStartIdx == nil {
                    legStartIdx = max(0, i - 1)
                    legDistance = 0
                }
                legDistance += dist
            } else if let start = legStartIdx {
                if legDistance >= Self.minimumTripDistance {
                    legs.append(Leg(startIndex: start, endIndex: i, distance: legDistance))
                }
                legStartIdx = nil
                legDistance = 0
            }
        }
        if let start = legStartIdx, legDistance >= Self.minimumTripDistance {
            legs.append(Leg(startIndex: start, endIndex: breadcrumbs.count - 1, distance: legDistance))
        }

        guard !legs.isEmpty else { return [] }

        // Merge consecutive legs into trips.
        var result: [DetectedTrip] = []
        var mergedStart = legs[0].startIndex
        var mergedEnd = legs[0].endIndex
        var mergedDistance = legs[0].distance

        for i in 1..<legs.count {
            let prevLeg = legs[i - 1]
            let currLeg = legs[i]

            let dwellTime = breadcrumbs[currLeg.startIndex].timestamp
                .timeIntervalSince(breadcrumbs[prevLeg.endIndex].timestamp)
            let dwellShort = dwellTime < 300

            let originLoc = CLLocation(latitude: breadcrumbs[mergedStart].latitude,
                                       longitude: breadcrumbs[mergedStart].longitude)
            let currEndLoc = CLLocation(latitude: breadcrumbs[currLeg.endIndex].latitude,
                                        longitude: breadcrumbs[currLeg.endIndex].longitude)
            let returnsToOrigin = originLoc.distance(from: currEndLoc) < 500

            if dwellTime < Self.maxDwellForSameTrip && (dwellShort || returnsToOrigin) {
                mergedEnd = currLeg.endIndex
                mergedDistance += currLeg.distance
            } else {
                result.append(buildTrip(breadcrumbs: breadcrumbs, startIdx: mergedStart, endIdx: mergedEnd, distance: mergedDistance))
                mergedStart = currLeg.startIndex
                mergedEnd = currLeg.endIndex
                mergedDistance = currLeg.distance
            }
        }
        result.append(buildTrip(breadcrumbs: breadcrumbs, startIdx: mergedStart, endIdx: mergedEnd, distance: mergedDistance))

        return result
    }

    private func buildTrip(breadcrumbs: [DeviceLocation], startIdx: Int, endIdx: Int, distance: Double) -> DetectedTrip {
        let tripStartTime: Date
        if startIdx + 1 < breadcrumbs.count && startIdx + 1 <= endIdx {
            tripStartTime = breadcrumbs[startIdx + 1].timestamp
        } else {
            tripStartTime = breadcrumbs[startIdx].timestamp
        }

        return DetectedTrip(
            startIndex: startIdx,
            endIndex: endIdx,
            startTime: tripStartTime,
            endTime: breadcrumbs[endIdx].timestamp,
            distanceMeters: distance
        )
    }

    // MARK: - Processed Trip Tracking

    /// Key for tracking whether a trip has been fully processed.
    /// Uses device ID + trip start/end timestamps for uniqueness.
    private static func tripProcessedKey(deviceID: DeviceID, startTime: Date, endTime: Date) -> String {
        let start = Int(startTime.timeIntervalSince1970)
        let end = Int(endTime.timeIntervalSince1970)
        return "\(processedKeyPrefix)\(deviceID.rawValue).\(start).\(end)"
    }

    private static func isTripProcessed(key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    private static func markTripProcessed(key: String) {
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Purge processed-trip markers older than the lookback window.
    /// Call periodically to prevent UserDefaults bloat.
    static func purgeStaleMarkers() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(processedKeyPrefix) }

        // Parse the end-timestamp from the key and remove if older than lookback.
        let cutoff = Date().addingTimeInterval(-lookbackDays).timeIntervalSince1970
        var purged = 0
        for key in allKeys {
            let parts = key.split(separator: ".")
            // Key format: routeProcessed.<deviceID>.<startEpoch>.<endEpoch>
            if let last = parts.last, let endEpoch = Double(last), endEpoch < cutoff {
                defaults.removeObject(forKey: key)
                purged += 1
            }
        }
        if purged > 0 {
            BBLog("[RouteProcessing] Purged \(purged) stale trip markers")
        }
    }
}
