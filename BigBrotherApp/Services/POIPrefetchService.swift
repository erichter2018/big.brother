import Foundation
import CoreLocation
import MapKit
import BigBrotherCore

/// Parent-side prefetcher that resolves POI names for breadcrumb endpoints and
/// current heartbeat locations, writing results into the same on-disk cache
/// (`caches/poi-cache-v3/`) that `LocationMapView` reads.
///
/// The map view's first-time POI lookups used to run on the main thread when the
/// user opened the trips panel, blocking the "Loading trips..." experience.
/// This service fires on dashboard refresh so cache entries are warm by the
/// time the parent taps into the map.
///
/// All network work happens off the main actor. Cache writes are atomic file
/// writes — safe to race against the map view's own writes.
enum POIPrefetchService {

    // MARK: - Cache format (must match LocationMapView)

    /// Bump in lockstep with `LocationMapView.poiCacheVersion` to invalidate.
    private static let cacheVersion = 3

    private static var cacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("poi-cache-v\(cacheVersion)", isDirectory: true)
    }

    /// 3-decimal precision ≈ 111m. Same key format as the map view so entries
    /// written here are read as hits there.
    private static func key(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.3f,%.3f", lat, lon)
    }

    private static func cacheFile(for key: String) -> URL {
        cacheDir.appendingPathComponent(
            key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        )
    }

    private static func isCached(lat: Double, lon: Double) -> Bool {
        FileManager.default.fileExists(atPath: cacheFile(for: key(lat, lon)).path)
    }

    private static func writeCache(_ name: String?, lat: Double, lon: Double) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let file = cacheFile(for: key(lat, lon))
        let value = name ?? "__none__"
        try? value.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Throttle

    /// Avoid re-running the full breadcrumb scan on every tick; once per 10 min
    /// is plenty since breadcrumbs trickle in at multi-minute intervals.
    private static let minInterval: TimeInterval = 600
    private static var lastRunAt: Date?

    // MARK: - Public entry points

    /// Prefetch POIs for the current location of each heartbeat. Cheap — one
    /// lookup per device, skipped if already cached.
    static func prefetchHeartbeatLocations(_ heartbeats: [DeviceHeartbeat]) async {
        let coords: [(Double, Double)] = heartbeats.compactMap { hb in
            guard let lat = hb.latitude, let lon = hb.longitude else { return nil }
            return (lat, lon)
        }
        await prefetch(coords: coords)
    }

    /// Prefetch POIs for the unique rounded coords of recent breadcrumbs across
    /// the given devices. Throttled to `minInterval` to bound network cost.
    static func prefetchRecentBreadcrumbs(
        cloudKit: any CloudKitServiceProtocol,
        deviceIDs: [DeviceID],
        lookbackHours: Int = 24
    ) async {
        if let last = lastRunAt, Date().timeIntervalSince(last) < minInterval {
            return
        }
        lastRunAt = Date()

        let since = Date().addingTimeInterval(-Double(lookbackHours) * 3600)
        var allCrumbs: [DeviceLocation] = []
        await withTaskGroup(of: [DeviceLocation].self) { group in
            for deviceID in deviceIDs {
                group.addTask {
                    (try? await cloudKit.fetchLocationBreadcrumbs(deviceID: deviceID, since: since)) ?? []
                }
            }
            for await crumbs in group {
                allCrumbs.append(contentsOf: crumbs)
            }
        }

        // Collapse to unique 3-decimal coords — continuous driving dedups to a
        // thin path, dwells dedup to a single point.
        var uniqueCoords: [String: (Double, Double)] = [:]
        for c in allCrumbs {
            uniqueCoords[key(c.latitude, c.longitude)] = (c.latitude, c.longitude)
        }

        await prefetch(coords: Array(uniqueCoords.values))
    }

    // MARK: - Internal

    /// Limit concurrent lookups so we don't stampede Apple's geocoder / MKLocalSearch
    /// (rate-limited ~50/min historically). 4 in flight keeps us well under.
    private static let maxConcurrent = 4

    private static func prefetch(coords: [(Double, Double)]) async {
        // Filter to uncached only — cheap, synchronous.
        let pending = coords.filter { !isCached(lat: $0.0, lon: $0.1) }
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var iter = pending.makeIterator()
            // Seed the pool.
            for _ in 0..<maxConcurrent {
                guard let next = iter.next() else { break }
                group.addTask { await runLookup(lat: next.0, lon: next.1) }
            }
            // Drain-and-refill to maintain at most `maxConcurrent` in flight.
            while await group.next() != nil {
                if let next = iter.next() {
                    group.addTask { await runLookup(lat: next.0, lon: next.1) }
                }
            }
        }
    }

    /// Mirrors `LocationMapView.lookupPOI` strategy so both populate the cache
    /// identically. Any divergence would cause cache misses on the map side.
    private static func runLookup(lat: Double, lon: Double) async {
        // Double-check cache — another task (or the map view) may have raced us.
        if isCached(lat: lat, lon: lon) { return }

        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let target = CLLocation(latitude: lat, longitude: lon)
        var anySucceeded = false

        // Strategy 1: reverse geocode — areasOfInterest.
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(target)
            anySucceeded = true
            if let pm = placemarks.first, let aoi = pm.areasOfInterest?.first, !aoi.isEmpty {
                writeCache(aoi, lat: lat, lon: lon)
                return
            }
            if let pm = placemarks.first, let name = pm.name,
               name != pm.thoroughfare,
               let first = name.first, !first.isNumber {
                writeCache(name, lat: lat, lon: lon)
                return
            }
        } catch {
            // Network/geocoder unavailable — fall through without marking success.
        }

        // Strategy 2: MKLocalSearch for nearby POIs.
        do {
            let req = MKLocalSearch.Request()
            req.region = MKCoordinateRegion(center: coord, latitudinalMeters: 400, longitudinalMeters: 400)
            req.resultTypes = .pointOfInterest
            let response = try await MKLocalSearch(request: req).start()
            anySucceeded = true
            if let name = closestName(in: response.mapItems, target: target, maxDist: 250) {
                writeCache(name, lat: lat, lon: lon)
                return
            }
        } catch {}

        // Strategy 3: explicit "school" search.
        do {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = "school"
            req.region = MKCoordinateRegion(center: coord, latitudinalMeters: 600, longitudinalMeters: 600)
            let response = try await MKLocalSearch(request: req).start()
            anySucceeded = true
            if let name = closestName(in: response.mapItems, target: target, maxDist: 300) {
                writeCache(name, lat: lat, lon: lon)
                return
            }
        } catch {}

        // Only cache the miss if at least one search actually returned; a pure
        // network failure would otherwise poison the cache.
        if anySucceeded {
            writeCache(nil, lat: lat, lon: lon)
        }
    }

    private static func closestName(in items: [MKMapItem], target: CLLocation, maxDist: Double) -> String? {
        items
            .filter { item in
                let loc = CLLocation(latitude: item.placemark.coordinate.latitude,
                                     longitude: item.placemark.coordinate.longitude)
                return target.distance(from: loc) < maxDist
            }
            .min { a, b in
                let la = CLLocation(latitude: a.placemark.coordinate.latitude, longitude: a.placemark.coordinate.longitude)
                let lb = CLLocation(latitude: b.placemark.coordinate.latitude, longitude: b.placemark.coordinate.longitude)
                return target.distance(from: la) < target.distance(from: lb)
            }?
            .name
    }
}
