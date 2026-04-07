import SwiftUI
import MapKit
import BigBrotherCore

/// Shows child's location on a map with 7-day trail, road-following routes,
/// a time scrubber to replay movement history, and a trip list for quick navigation.
struct LocationMapView: View {
    let child: ChildProfile
    let devices: [ChildDevice]
    let heartbeats: [DeviceHeartbeat]
    let cloudKit: (any CloudKitServiceProtocol)?
    let onLocate: () async -> Void
    var autoLocate: Bool = false
    /// When set, auto-selects the trip closest to this timestamp after loading.
    var focusTripAt: Date? = nil

    @State private var breadcrumbs: [DeviceLocation] = []
    @State private var routeSegments: [MKPolyline] = []
    /// Maps each route segment index to the breadcrumb index of its destination waypoint.
    @State private var segmentToBreadcrumbIndex: [Int] = []
    @State private var isLoading = false
    @State private var isLocating = false
    @State private var position: MapCameraPosition = .automatic
    @State private var routeProgress: String?

    // Time scrubber state
    @State private var scrubberValue: Double = 1.0  // 0.0 = oldest, 1.0 = now
    @State private var isScrubbing = false
    @State private var followDot = true  // camera follows scrubbed position

    // Trip list and scoping
    @State private var trips: [Trip] = []
    @State private var showTripList = true
    /// When set, the scrubber is scoped to this trip's breadcrumb range.
    @State private var selectedTrip: Trip?

    // Speed limit lookup for scrubbed position
    private var speedLimitService: SpeedLimitService { .shared }
    @State private var scrubbedSpeedLimit: Int?
    @State private var scrubSpeedLimitTask: Task<Void, Never>?

    // MARK: - Trip Model

    struct Trip: Identifiable {
        let id = UUID()
        let startIndex: Int       // index into breadcrumbs
        let endIndex: Int
        let startLocation: DeviceLocation
        let endLocation: DeviceLocation
        /// Farthest point from start (the "destination" of a round trip).
        let farthestLocation: DeviceLocation?
        let startTime: Date
        let endTime: Date
        let distanceMeters: Double
        let isRoundTrip: Bool
        /// Average speed from GPS readings (m/s), excluding stationary/invalid samples.
        let avgSpeedMPS: Double?

        /// POI or address for start/end/farthest — resolved async after detection.
        var startName: String?
        var farthestName: String?
        var endName: String?

        /// Drive report data (from correlated tripCompleted events).
        var maxSpeedMPH: Int?
        var phoneUsageCount: Int?
        var hardBrakingCount: Int?

        var durationMinutes: Int {
            Int(endTime.timeIntervalSince(startTime) / 60)
        }

        var distanceString: String {
            let miles = distanceMeters / 1609.344
            if miles < 0.1 { return String(format: "%.0f ft", distanceMeters * 3.281) }
            return String(format: "%.1f mi", miles)
        }

        var durationString: String {
            let mins = durationMinutes
            if mins < 60 { return "\(mins)m" }
            return "\(mins / 60)h \(mins % 60)m"
        }

        var timeRangeString: String {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            return "\(f.string(from: startTime)) - \(f.string(from: endTime))"
        }

        var dateString: String {
            let f = DateFormatter()
            let cal = Calendar.current
            if cal.isDateInToday(startTime) { return "Today" }
            if cal.isDateInYesterday(startTime) { return "Yesterday" }
            f.dateFormat = "EEE, MMM d"
            return f.string(from: startTime)
        }

        /// Display name for the start point.
        var startDisplayName: String {
            startName ?? startLocation.address ?? ""
        }

        /// Display name for the destination (farthest point for round trips, end for one-way).
        var destinationDisplayName: String {
            if isRoundTrip {
                return farthestName ?? farthestLocation?.address ?? endLocation.address ?? ""
            }
            return endName ?? endLocation.address ?? ""
        }

        /// Display name for the end point (only meaningful for round trips where end != destination).
        var endDisplayName: String {
            endName ?? endLocation.address ?? ""
        }
    }

    // MARK: - Computed: Current Live Location

    private var currentLocation: CLLocationCoordinate2D? {
        for device in devices {
            if let hb = heartbeats.first(where: { $0.deviceID == device.id }),
               let lat = hb.latitude, let lon = hb.longitude {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return nil
    }

    private var currentAddress: String? {
        for device in devices {
            if let hb = heartbeats.first(where: { $0.deviceID == device.id }) {
                return hb.locationAddress
            }
        }
        return nil
    }

    private var locationAge: String? {
        for device in devices {
            if let hb = heartbeats.first(where: { $0.deviceID == device.id }),
               let ts = hb.locationTimestamp {
                let seconds = Date().timeIntervalSince(ts)
                if seconds < 60 { return "just now" }
                if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
                return "\(Int(seconds / 3600))h ago"
            }
        }
        return nil
    }

    // MARK: - Scrubber Range

    /// The breadcrumb index range the scrubber maps to.
    /// Scoped to a trip when one is selected, or the full range.
    /// Guaranteed: start <= end, both within breadcrumbs bounds.
    private var scrubRange: (start: Int, end: Int) {
        guard !breadcrumbs.isEmpty else { return (0, 0) }
        if let trip = selectedTrip {
            let s = min(trip.startIndex, breadcrumbs.count - 1)
            let e = min(trip.endIndex, breadcrumbs.count - 1)
            return (s, max(e, s))
        }
        return (0, breadcrumbs.count - 1)
    }

    // MARK: - Computed: Scrubbed Position

    /// Smoothly interpolated scrub position along road routes.
    private var scrubPosition: ScrubPosition {
        guard breadcrumbs.count >= 2 else {
            if let c = breadcrumbs.first {
                return ScrubPosition(
                    coord: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude),
                    timestamp: c.timestamp, address: c.address ?? "",
                    isInterpolated: false, speed: nil, breadcrumbIndex: 0
                )
            }
            return ScrubPosition.empty
        }

        let range = scrubRange
        let rangeLength = Double(range.end - range.start)
        guard rangeLength > 0 else {
            let c = breadcrumbs[range.start]
            return ScrubPosition(
                coord: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude),
                timestamp: c.timestamp, address: c.address ?? "",
                isInterpolated: false, speed: nil, breadcrumbIndex: range.start
            )
        }

        let continuous = Double(range.start) + scrubberValue * rangeLength
        let lower = Int(floor(continuous))
        let upper = min(lower + 1, breadcrumbs.count - 1)
        let fraction = continuous - Double(lower)

        let from = breadcrumbs[lower]
        let to = breadcrumbs[upper]

        // At exact breadcrumb position
        if fraction < 0.01 || lower == upper {
            let speed = speedAtIndex(lower)
            return ScrubPosition(
                coord: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude),
                timestamp: from.timestamp, address: from.address ?? "",
                isInterpolated: false, speed: speed, breadcrumbIndex: lower
            )
        }

        // Between two breadcrumbs — check if stationary or moving
        let interpolatedTime = from.timestamp.addingTimeInterval(
            fraction * to.timestamp.timeIntervalSince(from.timestamp)
        )
        let speed = speedAtIndex(lower)
        let dist = CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))

        // If the two breadcrumbs are close (stationary/dwell), don't route-interpolate —
        // just use the breadcrumb position. This prevents the dot from sliding along
        // a road during a dwell at a destination.
        if dist < Self.stationaryRadius {
            return ScrubPosition(
                coord: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude),
                timestamp: interpolatedTime, address: from.address ?? "",
                isInterpolated: false, speed: speed, breadcrumbIndex: lower
            )
        }

        // Moving — try to interpolate along the road route
        if let coord = interpolateAlongRoute(from: lower, to: upper, fraction: fraction) {
            return ScrubPosition(
                coord: coord, timestamp: interpolatedTime,
                address: fraction < 0.5 ? (from.address ?? "") : (to.address ?? ""),
                isInterpolated: true, speed: speed, breadcrumbIndex: lower
            )
        }

        // Fallback: linear interpolation between breadcrumb coordinates
        let lat = from.latitude + fraction * (to.latitude - from.latitude)
        let lon = from.longitude + fraction * (to.longitude - from.longitude)
        return ScrubPosition(
            coord: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            timestamp: interpolatedTime,
            address: fraction < 0.5 ? (from.address ?? "") : (to.address ?? ""),
            isInterpolated: true, speed: speed, breadcrumbIndex: lower
        )
    }

    /// Convenience accessors from scrubPosition
    private var scrubbedIndex: Int { scrubPosition.breadcrumbIndex }
    private var scrubbedCoord: CLLocationCoordinate2D? { scrubPosition.coord }
    private var scrubbedTimeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: scrubPosition.timestamp)
    }
    private var scrubbedAddress: String { scrubPosition.address }
    private var scrubbedSpeed: String? { scrubPosition.speed }
    private var isInterpolated: Bool { scrubPosition.isInterpolated }

    /// Interpolate a position along a cached route polyline.
    private func interpolateAlongRoute(from lower: Int, to upper: Int, fraction: Double) -> CLLocationCoordinate2D? {
        guard !segmentToBreadcrumbIndex.isEmpty, !routeSegments.isEmpty else { return nil }

        // Find the route segment that SPANS the breadcrumb pair (lower, upper).
        // A segment spans (lower, upper) if its source breadcrumb <= lower and destination >= upper.
        // Source breadcrumb for segment i is: segmentToBreadcrumbIndex[i-1] (or 0 for i=0).
        var segIdx: Int?
        for i in 0..<segmentToBreadcrumbIndex.count {
            let segStart = i > 0 ? segmentToBreadcrumbIndex[i - 1] : 0
            let segEnd = segmentToBreadcrumbIndex[i]
            if segStart <= lower && segEnd >= upper {
                segIdx = i
                break
            }
        }
        guard let idx = segIdx, idx < routeSegments.count else { return nil }

        let polyline = routeSegments[idx]
        let pointCount = polyline.pointCount
        guard pointCount >= 2 else { return nil }

        // Extract polyline coordinates
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))

        // Calculate cumulative distances along the polyline
        var cumDist = [Double](repeating: 0, count: pointCount)
        for i in 1..<pointCount {
            let d = CLLocation(latitude: coords[i-1].latitude, longitude: coords[i-1].longitude)
                .distance(from: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude))
            cumDist[i] = cumDist[i-1] + d
        }
        let totalDist = cumDist.last ?? 0
        guard totalDist > 0 else { return nil }

        // Map the breadcrumb fraction to the sub-range of the polyline.
        // If the segment spans breadcrumbs segStart..segEnd and we're between
        // lower..upper, we need to find where (lower + fraction) falls proportionally
        // within the segment's breadcrumb range.
        let segStart = idx > 0 ? segmentToBreadcrumbIndex[idx - 1] : 0
        let segEnd = segmentToBreadcrumbIndex[idx]
        let segBreadcrumbSpan = Double(segEnd - segStart)
        let positionInSegment: Double
        if segBreadcrumbSpan > 0 {
            positionInSegment = (Double(lower - segStart) + fraction) / segBreadcrumbSpan
        } else {
            positionInSegment = fraction
        }
        let targetDist = positionInSegment * totalDist

        for i in 1..<pointCount {
            if cumDist[i] >= targetDist {
                let segFraction = (targetDist - cumDist[i-1]) / (cumDist[i] - cumDist[i-1])
                let lat = coords[i-1].latitude + segFraction * (coords[i].latitude - coords[i-1].latitude)
                let lon = coords[i-1].longitude + segFraction * (coords[i].longitude - coords[i-1].longitude)
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return coords.last
    }

    /// Speed label for the current scrubbed position.
    /// When inside a detected trip, uses total distance / total time for a stable average.
    /// Otherwise uses a sliding window of nearby breadcrumbs.
    private func speedAtIndex(_ index: Int) -> String? {
        let bc = breadcrumbs[index]

        // Use the GPS speed from the breadcrumb if available
        if let speed = bc.speed, speed >= 0 {
            let mph = Int(speed * 2.237)
            if mph < 2 { return "stationary" }
            return "\(mph) mph"
        }

        // Fallback: compute speed from distance/time to the nearest neighbor.
        // Use the closer of (prev→current) and (current→next) for best accuracy.
        var bestMPH: Double = 0
        if index > 0 {
            let prev = breadcrumbs[index - 1]
            let dist = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                .distance(from: CLLocation(latitude: bc.latitude, longitude: bc.longitude))
            let time = bc.timestamp.timeIntervalSince(prev.timestamp)
            if time > 0 { bestMPH = max(bestMPH, (dist / time) * 2.237) }
        }
        if index < breadcrumbs.count - 1 {
            let next = breadcrumbs[index + 1]
            let dist = CLLocation(latitude: bc.latitude, longitude: bc.longitude)
                .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
            let time = next.timestamp.timeIntervalSince(bc.timestamp)
            if time > 0 { bestMPH = max(bestMPH, (dist / time) * 2.237) }
        }
        if bestMPH < 2 { return "stationary" }
        if bestMPH < 8 { return "walking" }
        return "\(Int(bestMPH)) mph"
    }

    struct ScrubPosition {
        let coord: CLLocationCoordinate2D
        let timestamp: Date
        let address: String
        let isInterpolated: Bool
        let speed: String?
        let breadcrumbIndex: Int

        static let empty = ScrubPosition(
            coord: CLLocationCoordinate2D(), timestamp: Date(),
            address: "", isInterpolated: false, speed: nil, breadcrumbIndex: 0
        )
    }

    /// Number of route segments to highlight based on the current scrubber position.
    private var activeRouteSegmentCount: Int {
        guard !segmentToBreadcrumbIndex.isEmpty else {
            return 0
        }
        let target = scrubbedIndex
        var count = 0
        for destIndex in segmentToBreadcrumbIndex {
            if destIndex <= target {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    // MARK: - Trip Detection

    /// Minimum distance (meters) between consecutive breadcrumbs to count as movement.
    /// Points closer than this are considered GPS jitter while stationary.
    private static let stationaryRadius: Double = 150

    /// Minimum distance (meters) for a sequence of movement to qualify as a trip.
    private static let minimumTripDistance: Double = 300

    /// Maximum dwell time between movement segments to still be considered part of the same trip.
    private static let maxDwellForSameTrip: TimeInterval = 1800 // 30 minutes

    /// Distance threshold (meters) to consider "returned to start" for round trip detection.
    private static let roundTripReturnRadius: Double = 500

    /// Detect trips from breadcrumbs. Merges outbound + return legs into single round trips
    /// when the child leaves a place and returns within a reasonable time.
    private func detectTrips() -> [Trip] {
        guard breadcrumbs.count >= 2 else { return [] }

        // Step 1: Find individual movement legs (runs of consecutive movement).
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
                    // Include the previous (departure) breadcrumb for correct start location,
                    // but trip time uses the first moving breadcrumb's timestamp (see buildTrip).
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
        // Close open leg
        if let start = legStartIdx, legDistance >= Self.minimumTripDistance {
            legs.append(Leg(startIndex: start, endIndex: breadcrumbs.count - 1, distance: legDistance))
        }

        guard !legs.isEmpty else { return [] }

        // Step 2: Merge consecutive legs into trips.
        // Legs are merged when:
        //   a) The dwell between them is < maxDwellForSameTrip, AND
        //   b) The next leg ends near the original start (round trip forming)
        //      OR the dwell is short (< 30 min, just a stop along the way)
        var result: [Trip] = []
        var mergedStart = legs[0].startIndex
        var mergedEnd = legs[0].endIndex
        var mergedDistance = legs[0].distance

        for i in 1..<legs.count {
            let prevLeg = legs[i - 1]
            let currLeg = legs[i]

            let dwellTime = breadcrumbs[currLeg.startIndex].timestamp
                .timeIntervalSince(breadcrumbs[prevLeg.endIndex].timestamp)
            let dwellShort = dwellTime < 300 // < 5 min stop (red light, gas station)
            let dwellReasonable = dwellTime < Self.maxDwellForSameTrip

            // Check if current leg returns near the merged trip's origin
            let originLoc = CLLocation(latitude: breadcrumbs[mergedStart].latitude,
                                       longitude: breadcrumbs[mergedStart].longitude)
            let currEndLoc = CLLocation(latitude: breadcrumbs[currLeg.endIndex].latitude,
                                        longitude: breadcrumbs[currLeg.endIndex].longitude)
            let returnsToOrigin = originLoc.distance(from: currEndLoc) < Self.roundTripReturnRadius

            if dwellReasonable && (dwellShort || returnsToOrigin) {
                // Merge this leg into the current trip
                mergedEnd = currLeg.endIndex
                mergedDistance += currLeg.distance
            } else {
                // Finalize previous trip, start new one
                result.append(buildTrip(startIdx: mergedStart, endIdx: mergedEnd, distance: mergedDistance))
                mergedStart = currLeg.startIndex
                mergedEnd = currLeg.endIndex
                mergedDistance = currLeg.distance
            }
        }
        // Finalize last trip
        result.append(buildTrip(startIdx: mergedStart, endIdx: mergedEnd, distance: mergedDistance))

        return result
    }

    /// Build a Trip, detecting round trips and finding the farthest point.
    /// startIdx is the departure breadcrumb (stationary location before movement).
    /// The first moving breadcrumb (startIdx+1) provides accurate departure time.
    private func buildTrip(startIdx: Int, endIdx: Int, distance: Double) -> Trip {
        let startLoc = breadcrumbs[startIdx]
        let endLoc = breadcrumbs[endIdx]

        // Use the first moving breadcrumb's time as the trip start time
        // (the departure breadcrumb is the last stationary point — could be minutes old).
        let tripStartTime: Date
        if startIdx + 1 < breadcrumbs.count && startIdx + 1 <= endIdx {
            tripStartTime = breadcrumbs[startIdx + 1].timestamp
        } else {
            tripStartTime = startLoc.timestamp
        }

        let origin = CLLocation(latitude: startLoc.latitude, longitude: startLoc.longitude)
        let destination = CLLocation(latitude: endLoc.latitude, longitude: endLoc.longitude)
        let isRound = origin.distance(from: destination) < Self.roundTripReturnRadius

        // Find farthest point from origin within the trip
        var farthestIdx = startIdx
        var farthestDist: Double = 0
        for i in startIdx...endIdx {
            let loc = CLLocation(latitude: breadcrumbs[i].latitude, longitude: breadcrumbs[i].longitude)
            let d = origin.distance(from: loc)
            if d > farthestDist {
                farthestDist = d
                farthestIdx = i
            }
        }

        // Compute average speed from GPS speed readings (excludes invalid/stationary)
        let validSpeeds = (startIdx...endIdx).compactMap { i -> Double? in
            guard let s = breadcrumbs[i].speed, s > 1.0 else { return nil } // >1 m/s (~2 mph)
            return s
        }
        let avgSpeed: Double? = validSpeeds.isEmpty ? nil :
            validSpeeds.reduce(0, +) / Double(validSpeeds.count)
        // Max speed from GPS breadcrumbs (m/s → mph)
        let maxSpeedFromBreadcrumbs: Int? = validSpeeds.isEmpty ? nil :
            Int((validSpeeds.max() ?? 0) * 2.237)

        var trip = Trip(
            startIndex: startIdx,
            endIndex: endIdx,
            startLocation: startLoc,
            endLocation: endLoc,
            farthestLocation: farthestIdx != startIdx ? breadcrumbs[farthestIdx] : nil,
            startTime: tripStartTime,
            endTime: endLoc.timestamp,
            distanceMeters: distance,
            isRoundTrip: isRound,
            avgSpeedMPS: avgSpeed
        )
        trip.maxSpeedMPH = maxSpeedFromBreadcrumbs
        return trip
    }

    /// Pre-fetch speed limits for all trip breadcrumbs so they're cached before scrubbing.
    /// Deduplicates by geohash (150m cells) to avoid redundant queries.
    /// Runs queries concurrently in batches of 5 to respect Overpass rate limits.
    @State private var speedLimitPrefetchProgress: String?

    private func prefetchSpeedLimitsForTrips() async {
        guard !trips.isEmpty else { return }
        var coords: [CLLocationCoordinate2D] = []
        var seen = Set<String>()

        for trip in trips {
            let start = max(trip.startIndex, 0)
            let end = min(trip.endIndex, breadcrumbs.count - 1)
            guard start <= end else { continue }

            for i in start...end {
                let bc = breadcrumbs[i]
                // Deduplicate by rounded coordinate (~150m precision, matching geohash)
                let key = "\(String(format: "%.3f", bc.latitude)),\(String(format: "%.3f", bc.longitude))"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                coords.append(CLLocationCoordinate2D(latitude: bc.latitude, longitude: bc.longitude))
            }
        }

        let total = coords.count
        if total > 0 {
            speedLimitPrefetchProgress = "Loading speed limits (0/\(total))..."
        }

        // Query in batches of 5 concurrently
        for batch in stride(from: 0, to: total, by: 5) {
            let end = min(batch + 5, total)
            await withTaskGroup(of: Void.self) { group in
                for i in batch..<end {
                    group.addTask {
                        let _ = await self.speedLimitService.speedLimit(at: coords[i])
                    }
                }
            }
            if (batch + 5) % 20 == 0 || end == total {
                speedLimitPrefetchProgress = "Loading speed limits (\(end)/\(total))..."
            }
        }
        speedLimitPrefetchProgress = nil
    }

    /// Correlate tripCompleted/speeding/braking/phone events from CloudKit with detected trips.
    /// Matches events to trips by timestamp overlap.
    private func correlateDriveReportEvents() async {
        guard !trips.isEmpty, let cloudKit else { return }
        let familyID = child.familyID
        let since = trips.map(\.startTime).min() ?? Date().addingTimeInterval(-86400)
        guard let events = try? await cloudKit.fetchEventLogs(familyID: familyID, since: since) else { return }

        // Filter to driving-related events for this child's devices
        let deviceIDs = Set(devices.map(\.id.rawValue))
        let drivingEvents = events.filter { event in
            guard deviceIDs.contains(event.deviceID.rawValue) else { return false }
            switch event.eventType {
            case .tripCompleted, .speedingDetected, .hardBrakingDetected, .phoneWhileDriving:
                return true
            default:
                return false
            }
        }

        for i in trips.indices {
            let trip = trips[i]
            // Find tripCompleted event within ±5 min of trip end
            if let completedEvent = drivingEvents.first(where: {
                $0.eventType == .tripCompleted &&
                abs($0.timestamp.timeIntervalSince(trip.endTime)) < 300
            }), let details = completedEvent.details,
               let data = details.data(using: String.Encoding.utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                trips[i].maxSpeedMPH = json["maxSpeedMPH"] as? Int
                trips[i].hardBrakingCount = json["hardBrakingCount"] as? Int
                trips[i].phoneUsageCount = json["phoneUsageCount"] as? Int
            }

            // If no tripCompleted event, count individual events during the trip window
            if trips[i].maxSpeedMPH == nil {
                let tripEvents = drivingEvents.filter {
                    $0.timestamp >= trip.startTime && $0.timestamp <= trip.endTime.addingTimeInterval(60)
                }
                let speedEvents = tripEvents.filter { $0.eventType == .speedingDetected }
                let brakeEvents = tripEvents.filter { $0.eventType == .hardBrakingDetected }
                let phoneEvents = tripEvents.filter { $0.eventType == .phoneWhileDriving }

                if !speedEvents.isEmpty || !brakeEvents.isEmpty || !phoneEvents.isEmpty {
                    trips[i].hardBrakingCount = brakeEvents.count
                    trips[i].phoneUsageCount = phoneEvents.count
                    // Try to parse max speed from speeding event details
                    if let speedDetail = speedEvents.first?.details,
                       let match = speedDetail.range(of: "Max \\d+", options: .regularExpression) {
                        let numStr = speedDetail[match].dropFirst(4)
                        trips[i].maxSpeedMPH = Int(numStr)
                    }
                }
            }
        }
    }

    /// Resolve POI names for trip endpoints using MKLocalSearch.
    /// Falls back to existing address if no POI is found.
    private func resolveTripPOIs() async {
        guard !trips.isEmpty else { return }

        for i in trips.indices {
            let trip = trips[i]

            // Skip if near home — we already label those "Home"
            if !isNearHome(trip.startLocation) {
                trips[i].startName = await lookupPOI(
                    latitude: trip.startLocation.latitude,
                    longitude: trip.startLocation.longitude
                )
            }
            if !isNearHome(trip.endLocation) {
                trips[i].endName = await lookupPOI(
                    latitude: trip.endLocation.latitude,
                    longitude: trip.endLocation.longitude
                )
            }
            if let farthest = trip.farthestLocation, !isNearHome(farthest) {
                trips[i].farthestName = await lookupPOI(
                    latitude: farthest.latitude,
                    longitude: farthest.longitude
                )
            }

            // Auto-geofence: if a POI contains "School", auto-save as a named place
            for name in [trips[i].startName, trips[i].endName, trips[i].farthestName].compactMap({ $0 }) {
                if isSchoolName(name) {
                    let loc = name == trips[i].startName ? trip.startLocation :
                              name == trips[i].farthestName ? (trip.farthestLocation ?? trip.endLocation) :
                              trip.endLocation
                    await autoCreateNamedPlaceIfNeeded(name: name, location: loc)
                }
            }
        }
    }

    private func isSchoolName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("school") || lower.contains("elementary") ||
               lower.contains("middle school") || lower.contains("high school") ||
               lower.contains("academy") || lower.contains("preschool")
    }

    /// Auto-create a named place for a school if one doesn't already exist nearby.
    private func autoCreateNamedPlaceIfNeeded(name: String, location: DeviceLocation) async {
        guard let cloudKit else { return }

        // Check if we already auto-created this (stored in UserDefaults to avoid re-querying)
        let key = "autoPlace.\(String(format: "%.3f,%.3f", location.latitude, location.longitude))"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        // Check if a named place already exists near this location
        if let familyID = devices.first?.familyID {
            if let existing = try? await cloudKit.fetchNamedPlaces(familyID: familyID) {
                let loc = CLLocation(latitude: location.latitude, longitude: location.longitude)
                let nearbyExists = existing.contains { place in
                    CLLocation(latitude: place.latitude, longitude: place.longitude)
                        .distance(from: loc) < 500
                }
                if nearbyExists { return }
            }

            // Auto-create the named place
            let place = NamedPlace(
                familyID: familyID,
                name: name,
                latitude: location.latitude,
                longitude: location.longitude,
                radiusMeters: 200,
                createdBy: "Auto-detected"
            )
            try? await cloudKit.saveNamedPlace(place)
            #if DEBUG
            print("[LocationMap] Auto-created named place: \(name)")
            #endif
        }
    }

    // MARK: - POI Cache

    /// Bump this to invalidate all cached POI lookups.
    private static let poiCacheVersion = 3

    private static var poiCacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("poi-cache-v\(poiCacheVersion)", isDirectory: true)
    }

    /// Cache key from rounded coordinates (3 decimal places ~ 111m precision).
    private static func poiCacheKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.3f,%.3f", latitude, longitude)
    }

    private static func loadCachedPOI(latitude: Double, longitude: Double) -> String?? {
        let key = poiCacheKey(latitude: latitude, longitude: longitude)
        let file = poiCacheDir.appendingPathComponent(
            key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        )
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return nil } // no cache entry
        if data == "__none__" { return .some(nil) } // cached "no POI found"
        return .some(data) // cached POI name
    }

    private static func cachePOI(_ name: String?, latitude: Double, longitude: Double) {
        let dir = poiCacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = poiCacheKey(latitude: latitude, longitude: longitude)
        let file = dir.appendingPathComponent(
            key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        )
        let value = name ?? "__none__"
        try? value.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Look up the nearest POI at a coordinate. Tries multiple search strategies:
    /// 1. Reverse geocode — check areasOfInterest (most reliable, no query needed)
    /// 2. MKLocalSearch for nearby POIs (schools, parks, businesses)
    /// 3. Explicit "school" search (wider radius)
    /// Returns the POI name if found, otherwise nil (caller falls back to address).
    /// Only caches successful results — network failures won't poison the cache.
    private func lookupPOI(latitude: Double, longitude: Double) async -> String? {
        // Check cache first (double-optional: nil = no cache, .some(nil) = cached "no POI")
        if let cached = Self.loadCachedPOI(latitude: latitude, longitude: longitude) {
            #if DEBUG
            print("[POI] Cache hit for (\(String(format: "%.3f,%.3f", latitude, longitude))): \(cached ?? "none")")
            #endif
            return cached
        }

        #if DEBUG
        print("[POI] Looking up (\(String(format: "%.4f,%.4f", latitude, longitude)))...")
        #endif

        let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let target = CLLocation(latitude: latitude, longitude: longitude)
        var anySearchSucceeded = false

        // Strategy 1: Reverse geocode — areasOfInterest is most reliable and lightweight
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(target)
            anySearchSucceeded = true
            if let pm = placemarks.first, let aoi = pm.areasOfInterest?.first, !aoi.isEmpty {
                #if DEBUG
                print("[POI] Found via geocode areasOfInterest: \(aoi)")
                #endif
                Self.cachePOI(aoi, latitude: latitude, longitude: longitude)
                return aoi
            }
            // Also check the placemark name — sometimes it's a POI name (e.g. a school).
            // Skip if it looks like a street address (starts with a number).
            if let pm = placemarks.first, let name = pm.name,
               name != pm.thoroughfare,
               !name.first!.isNumber { // Street addresses start with house number
                #if DEBUG
                print("[POI] Found via geocode name: \(name)")
                #endif
                Self.cachePOI(name, latitude: latitude, longitude: longitude)
                return name
            }
            #if DEBUG
            if let pm = placemarks.first {
                print("[POI] Geocode returned: name=\(pm.name ?? "nil") thoroughfare=\(pm.thoroughfare ?? "nil") aoi=\(pm.areasOfInterest ?? [])")
            }
            #endif
        } catch {
            #if DEBUG
            print("[POI] Geocode failed: \(error.localizedDescription)")
            #endif
        }

        // Strategy 2: MKLocalSearch for nearby POIs
        do {
            let request = MKLocalSearch.Request()
            request.region = MKCoordinateRegion(
                center: coord, latitudinalMeters: 400, longitudinalMeters: 400
            )
            request.resultTypes = .pointOfInterest
            let search = MKLocalSearch(request: request)
            let response = try await search.start()
            anySearchSucceeded = true

            #if DEBUG
            print("[POI] MKLocalSearch returned \(response.mapItems.count) items")
            for item in response.mapItems.prefix(5) {
                let d = target.distance(from: CLLocation(latitude: item.placemark.coordinate.latitude,
                                                          longitude: item.placemark.coordinate.longitude))
                print("[POI]   \(item.name ?? "?") — \(Int(d))m")
            }
            #endif

            if let name = closestPOIName(from: response.mapItems, target: target, maxDist: 250) {
                Self.cachePOI(name, latitude: latitude, longitude: longitude)
                return name
            }
        } catch {
            #if DEBUG
            print("[POI] MKLocalSearch failed: \(error.localizedDescription)")
            #endif
        }

        // Strategy 3: Explicit "school" search (wider radius)
        do {
            let schoolReq = MKLocalSearch.Request()
            schoolReq.naturalLanguageQuery = "school"
            schoolReq.region = MKCoordinateRegion(
                center: coord, latitudinalMeters: 600, longitudinalMeters: 600
            )
            let search = MKLocalSearch(request: schoolReq)
            let response = try await search.start()
            anySearchSucceeded = true
            if let name = closestPOIName(from: response.mapItems, target: target, maxDist: 300) {
                #if DEBUG
                print("[POI] Found school: \(name)")
                #endif
                Self.cachePOI(name, latitude: latitude, longitude: longitude)
                return name
            }
        } catch {
            #if DEBUG
            print("[POI] School search failed: \(error.localizedDescription)")
            #endif
        }

        // Only cache "no POI" if at least one search actually succeeded (not all network errors)
        if anySearchSucceeded {
            #if DEBUG
            print("[POI] No POI found — caching miss")
            #endif
            Self.cachePOI(nil, latitude: latitude, longitude: longitude)
        } else {
            #if DEBUG
            print("[POI] All searches failed (network?) — NOT caching, will retry next time")
            #endif
        }
        return nil
    }

    private func closestPOIName(from items: [MKMapItem], target: CLLocation, maxDist: Double) -> String? {
        items
            .filter { item in
                let loc = CLLocation(latitude: item.placemark.coordinate.latitude,
                                     longitude: item.placemark.coordinate.longitude)
                return target.distance(from: loc) < maxDist
            }
            .min { a, b in
                let aLoc = CLLocation(latitude: a.placemark.coordinate.latitude,
                                      longitude: a.placemark.coordinate.longitude)
                let bLoc = CLLocation(latitude: b.placemark.coordinate.latitude,
                                      longitude: b.placemark.coordinate.longitude)
                return target.distance(from: aLoc) < target.distance(from: bLoc)
            }?
            .name
    }

    /// Deduplicate consecutive stationary breadcrumbs before route resolution.
    /// Keeps the first breadcrumb in each stationary cluster and all moving breadcrumbs.
    private func deduplicatedBreadcrumbs() -> [DeviceLocation] {
        guard breadcrumbs.count >= 2 else { return breadcrumbs }

        var result: [DeviceLocation] = [breadcrumbs[0]]
        for i in 1..<breadcrumbs.count {
            let prev = result.last!
            let curr = breadcrumbs[i]
            let dist = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                .distance(from: CLLocation(latitude: curr.latitude, longitude: curr.longitude))
            if dist >= Self.stationaryRadius {
                result.append(curr)
            }
        }
        // Always include the last breadcrumb
        if let last = breadcrumbs.last, result.last?.id != last.id {
            result.append(last)
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Map — always visible, pinned at top
            mapView
                .frame(minHeight: 300)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if isScrubbing {
                        Button {
                            followDot.toggle()
                            if followDot, let coord = scrubbedCoord {
                                withAnimation { position = .camera(MapCamera(centerCoordinate: coord, distance: 2000)) }
                            } else if !followDot {
                                zoomToFitTrail()
                            }
                        } label: {
                            Image(systemName: followDot ? "scope" : "map")
                                .font(.body)
                                .padding(10)
                                .background {
                                    if #available(iOS 26, *) {
                                        Circle().fill(.clear).glassEffect(.regular.interactive(), in: .circle)
                                    } else {
                                        Circle().fill(.ultraThinMaterial)
                                    }
                                }
                        }
                        .padding(12)
                    }
                }

            // Controls + trip list — fixed height, scrolls independently
            VStack(spacing: 0) {
                // Scrubber + info panel
                VStack(spacing: 6) {
                    // Time scrubber
                    if breadcrumbs.count >= 2 {
                        timeScrubber
                    }

                    // Info line
                    if isScrubbing, scrubbedCoord != nil {
                        scrubberInfoLine
                    } else if let address = currentAddress, let age = locationAge {
                        HStack {
                            Image(systemName: "location.fill").foregroundStyle(.blue)
                            Text(address).font(.subheadline)
                            Spacer()
                            Text(age).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No location data yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if routeProgress != nil || speedLimitPrefetchProgress != nil {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.7)
                            VStack(alignment: .leading, spacing: 1) {
                                if let rp = routeProgress {
                                    Text(rp).font(.caption2).foregroundStyle(.secondary)
                                }
                                if let sp = speedLimitPrefetchProgress {
                                    Text(sp).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // (Locate button is now on the map overlay)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                // Trip list — scrolls independently
                if !trips.isEmpty {
                    Divider()
                    ScrollView {
                        tripListSection
                    }
                    .frame(maxHeight: 300)
                }
            }
        }
        .navigationTitle("Location")
        .task {
            if let coord = currentLocation {
                position = .camera(MapCamera(centerCoordinate: coord, distance: 2000))
            }
            if autoLocate {
                Task { await locateAndCenter() }
            }
            await loadBreadcrumbs()
            trips = detectTrips()
            await correlateDriveReportEvents()
            await resolveTripPOIs()
            // Auto-focus on a specific trip if requested
            if let target = focusTripAt, let match = trips.min(by: {
                abs($0.endTime.timeIntervalSince(target)) < abs($1.endTime.timeIntervalSince(target))
            }), abs(match.endTime.timeIntervalSince(target)) < 600 {
                jumpToTrip(match)
            }
            // Routes and speed limits load in parallel
            async let routes: () = resolveRoutes()
            async let speedLimits: () = prefetchSpeedLimitsForTrips()
            _ = await (routes, speedLimits)
        }
        .onChange(of: heartbeats.first?.latitude) { _, _ in
            if !isScrubbing, let coord = currentLocation {
                withAnimation { position = .camera(MapCamera(centerCoordinate: coord, distance: 2000)) }
            }
        }
        .onDisappear {
            Task { await speedLimitService.persistToDisk() }
        }
    }

    // MARK: - Trip List

    @ViewBuilder
    private var tripListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // "All Data" row to return to full timeline
            Button {
                returnToAllData()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(selectedTrip == nil ? .blue : .secondary)
                    Text("All Data")
                        .font(.subheadline.weight(selectedTrip == nil ? .semibold : .regular))
                        .foregroundStyle(selectedTrip == nil ? .blue : .primary)
                    Spacer()
                    Text("\(trips.count) trips")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(selectedTrip == nil ? Color.blue.opacity(0.08) : Color.clear)
            }
            .buttonStyle(.plain)

            Divider()

            LazyVStack(spacing: 0) {
                ForEach(trips.reversed()) { trip in
                    tripRow(trip)
                    Divider().padding(.leading, 40)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Home coordinates from parent-side storage (per-device keys in UserDefaults.standard).
    private var homeCoordinate: CLLocation? {
        // Try per-device keys (parent side stores as homeLatitude.<deviceID>)
        for device in devices {
            let latKey = "homeLatitude.\(device.id.rawValue)"
            let lonKey = "homeLongitude.\(device.id.rawValue)"
            if let lat = UserDefaults.standard.object(forKey: latKey) as? Double,
               let lon = UserDefaults.standard.object(forKey: lonKey) as? Double {
                return CLLocation(latitude: lat, longitude: lon)
            }
        }
        // Fallback: try App Group defaults (child side stores as homeLatitude)
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if let lat = defaults?.object(forKey: "homeLatitude") as? Double,
           let lon = defaults?.object(forKey: "homeLongitude") as? Double {
            return CLLocation(latitude: lat, longitude: lon)
        }
        // Last resort: scan all UserDefaults keys for any homeLatitude.*
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("homeLatitude.") {
                let suffix = String(key.dropFirst("homeLatitude.".count))
                if let lat = UserDefaults.standard.object(forKey: key) as? Double,
                   let lon = UserDefaults.standard.object(forKey: "homeLongitude.\(suffix)") as? Double {
                    return CLLocation(latitude: lat, longitude: lon)
                }
            }
        }
        return nil
    }

    /// Check if a location is near the configured home coordinates.
    private func isNearHome(_ loc: DeviceLocation) -> Bool {
        guard let home = homeCoordinate else { return false }
        let point = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
        return home.distance(from: point) < 150
    }

    /// Display name for a trip endpoint — uses "Home" if near home, POI name if resolved, or address.
    private func displayName(for loc: DeviceLocation, poiName: String?) -> String {
        if isNearHome(loc) { return "Home" }
        if let poi = poiName, !poi.isEmpty { return poi }
        return loc.address ?? coordString(loc)
    }

    @ViewBuilder
    private func tripRow(_ trip: Trip) -> some View {
        Button {
            jumpToTrip(trip)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Route icon
                VStack(spacing: 2) {
                    Circle().fill(.blue).frame(width: 8, height: 8)
                    Rectangle().fill(.blue.opacity(0.3)).frame(width: 2, height: 20)
                    if trip.isRoundTrip {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.blue)
                    } else {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    // Date header
                    Text(trip.dateString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // Start
                    Text(displayName(for: trip.startLocation, poiName: trip.startName))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    // Destination (farthest point for round trips, end for one-way)
                    if trip.isRoundTrip, let farthest = trip.farthestLocation {
                        Text(displayName(for: farthest, poiName: trip.farthestName))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text(displayName(for: trip.endLocation, poiName: trip.endName))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(trip.timeRangeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(trip.distanceString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\u{00B7}")
                            .foregroundStyle(.tertiary)
                        Text(trip.durationString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let avg = trip.avgSpeedMPS, avg > 0.5 {
                            Text("\u{00B7}")
                                .foregroundStyle(.tertiary)
                            Text("\(Int(avg * 2.237)) avg")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if let maxSpd = trip.maxSpeedMPH, maxSpd > 0 {
                            Text("\u{00B7}")
                                .foregroundStyle(.tertiary)
                            Text("\(maxSpd) max")
                                .font(.caption2)
                                .foregroundStyle(maxSpd > 65 ? .red : .orange)
                        }
                    }
                    // Drive report badges
                    HStack(spacing: 6) {
                        if let phone = trip.phoneUsageCount, phone > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "iphone.gen3")
                                    .font(.system(size: 8))
                                Text("\(phone)")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.orange)
                        }
                        if let braking = trip.hardBrakingCount, braking > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "exclamationmark.octagon")
                                    .font(.system(size: 8))
                                Text("\(braking)")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(selectedTrip?.id == trip.id ? Color.blue.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func coordString(_ loc: DeviceLocation) -> String {
        String(format: "%.4f, %.4f", loc.latitude, loc.longitude)
    }

    private func jumpToTrip(_ trip: Trip) {
        guard breadcrumbs.count >= 2 else { return }

        // Scope the scrubber to this trip's range and start at the beginning.
        withAnimation {
            selectedTrip = trip
            scrubberValue = 0.0
            isScrubbing = true
        }

        // Zoom to fit the trip
        let tripCrumbs = breadcrumbs[trip.startIndex...trip.endIndex]
        let lats = tripCrumbs.map(\.latitude)
        let lons = tripCrumbs.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.005),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.005)
        )
        withAnimation {
            position = .region(MKCoordinateRegion(center: center, span: span))
            followDot = false
        }
    }

    private func returnToAllData() {
        withAnimation {
            selectedTrip = nil
            scrubberValue = 1.0
            isScrubbing = false
            followDot = true
        }
        if let coord = currentLocation {
            withAnimation {
                position = .camera(MapCamera(centerCoordinate: coord, distance: 2000))
            }
        }
    }

    // MARK: - Time Scrubber

    @ViewBuilder
    private var timeScrubber: some View {
        VStack(spacing: 2) {
            // Timestamp label
            HStack {
                if selectedTrip != nil {
                    Button {
                        returnToAllData()
                    } label: {
                        Label("All Data", systemImage: "arrow.uturn.backward")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                Spacer()
                Text(isScrubbing ? scrubbedTimeLabel : "Now")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(isScrubbing ? .blue : .secondary)
                Spacer()
                if selectedTrip != nil {
                    // Spacer for symmetry
                    Text("All Data").font(.caption2).hidden()
                }
            }

            HStack(spacing: 8) {
                Text(scrubStartLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Slider(value: $scrubberValue, in: 0...1)
                    .tint(.blue)
                    .onChange(of: scrubberValue) { _, newValue in
                        // When a trip is selected, always stay in scrubbing mode
                        // (the slider represents the trip's full extent, not "Now").
                        if selectedTrip != nil {
                            isScrubbing = true
                        } else {
                            isScrubbing = newValue < 0.99
                        }
                        if isScrubbing, let coord = scrubbedCoord {
                            if followDot {
                                position = .camera(MapCamera(centerCoordinate: coord, distance: 2000))
                            }
                        }
                        if !isScrubbing {
                            scrubbedSpeedLimit = nil
                            if let coord = currentLocation {
                                position = .camera(MapCamera(centerCoordinate: coord, distance: 2000))
                            }
                        }
                    }
                    // Debounce speed limit lookup — only fetch when scrubbing pauses
                    .onReceive(
                        NotificationCenter.default.publisher(for: .init("scrubberIdle"))
                    ) { _ in }
                    .onChange(of: scrubbedIndex) { _, _ in
                        // Speed limit lookup on breadcrumb index change (not every pixel)
                        guard isScrubbing, let coord = scrubbedCoord else { return }
                        scrubSpeedLimitTask?.cancel()
                        scrubSpeedLimitTask = Task {
                            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
                            guard !Task.isCancelled else { return }
                            if let cached = await speedLimitService.cachedSpeedLimit(at: coord) {
                                scrubbedSpeedLimit = cached
                            } else {
                                scrubbedSpeedLimit = await speedLimitService.speedLimit(at: coord)
                            }
                        }
                    }

                Text(scrubEndLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var scrubStartLabel: String {
        let range = scrubRange
        guard range.start < breadcrumbs.count else { return "" }
        let ts = breadcrumbs[range.start].timestamp
        let f = DateFormatter()
        f.dateFormat = selectedTrip != nil ? "h:mm a" : "EEE"
        return f.string(from: ts)
    }

    private var scrubEndLabel: String {
        if selectedTrip == nil { return "Now" }
        let range = scrubRange
        guard range.end < breadcrumbs.count else { return "" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: breadcrumbs[range.end].timestamp)
    }

    // MARK: - Scrubber Info Line

    @ViewBuilder
    private var scrubberInfoLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: isInterpolated ? "circle.dotted" : "clock.fill")
                    .foregroundStyle(isInterpolated ? .yellow : .blue)
                    .font(.caption)
                Text(scrubbedTimeLabel).font(.subheadline).fontWeight(.medium)
                if isInterpolated {
                    Text("estimated")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if let speed = scrubbedSpeed {
                    Text("\u{00B7}").foregroundStyle(.tertiary)
                    let overLimit = scrubbedSpeedLimit.map { limit in
                        // Parse mph from speed string
                        let mph = Int(speed.replacingOccurrences(of: " mph", with: "").replacingOccurrences(of: "stationary", with: "0")) ?? 0
                        return mph > limit + 10
                    } ?? false
                    Text(speed)
                        .font(.caption)
                        .foregroundStyle(overLimit ? .red : (speed.contains("mph") ? .orange : .secondary))
                    if let limit = scrubbedSpeedLimit {
                        Text("/ \(limit) limit")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                Spacer()
            }
            if !scrubbedAddress.isEmpty {
                Text(scrubbedAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Route Segment Helpers

    /// Returns the indices of route segments whose destination breadcrumb falls within the given range.
    private func segmentIndices(forBreadcrumbRange startIdx: Int, endIdx: Int) -> [Int] {
        var result: [Int] = []
        for (i, destBreadcrumb) in segmentToBreadcrumbIndex.enumerated() {
            if destBreadcrumb > startIdx && destBreadcrumb <= endIdx {
                result.append(i)
            }
        }
        return result
    }

    /// Route segment indices to draw based on current context:
    /// - Trip selected: only that trip's segments
    /// - Scrubbing all data: segments up to scrubbed position
    /// - Not scrubbing: segments for the most recent trip only (avoids overlapping round-trips)
    private var visibleSegmentIndices: [Int] {
        if let trip = selectedTrip {
            return segmentIndices(forBreadcrumbRange: trip.startIndex, endIdx: trip.endIndex)
        }
        if isScrubbing {
            let range = scrubRange
            let target = range.start + Int(scrubberValue * Double(range.end - range.start))
            return segmentIndices(forBreadcrumbRange: range.start, endIdx: target)
        }
        // Not scrubbing, no trip selected: show current location only, no old routes
        return []
    }

    // MARK: - Map

    @ViewBuilder
    private var mapView: some View {
        Map(position: $position) {
            // Visible route segments (context-dependent)
            let visible = visibleSegmentIndices
            ForEach(visible, id: \.self) { i in
                if i < routeSegments.count {
                    MapPolyline(routeSegments[i])
                        .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }

            // Fallback dashed lines while routes are loading
            if routeSegments.isEmpty && breadcrumbs.count >= 2 {
                let fbRange = scrubRange
                let fbEnd = isScrubbing
                    ? fbRange.start + Int(scrubberValue * Double(fbRange.end - fbRange.start))
                    : fbRange.end
                let safeStart = min(fbRange.start, breadcrumbs.count - 1)
                let safeEnd = min(max(fbEnd, safeStart), breadcrumbs.count - 1)
                let slice = breadcrumbs[safeStart...safeEnd]
                MapPolyline(coordinates: slice.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(.blue.opacity(0.4), style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
            }

            // Breadcrumb dots (subtle, only within visible range)
            let dotRange = scrubRange
            let dotStart = min(dotRange.start, max(breadcrumbs.count - 1, 0))
            let dotEnd = min(dotRange.end, max(breadcrumbs.count - 1, 0))
            let visibleCrumbs = breadcrumbs.isEmpty ? [] : Array(breadcrumbs[dotStart...dotEnd])
            ForEach(visibleCrumbs) { crumb in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: crumb.latitude, longitude: crumb.longitude)) {
                    Circle()
                        .fill(.blue.opacity(0.2))
                        .frame(width: 5, height: 5)
                }
            }

            // Scrubbed time dot — orange for real breadcrumbs, yellow for interpolated
            if isScrubbing, let coord = scrubbedCoord {
                let dotColor: Color = isInterpolated ? .yellow : .orange
                Annotation("", coordinate: coord) {
                    ZStack {
                        Circle()
                            .fill(dotColor.opacity(0.3))
                            .frame(width: 28, height: 28)
                        Circle()
                            .fill(dotColor)
                            .frame(width: 14, height: 14)
                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                    }
                }
            }

            // Current location pin (always visible)
            if let coord = currentLocation {
                Annotation(isScrubbing ? "" : (currentAddress ?? "Current"), coordinate: coord) {
                    ZStack {
                        Circle()
                            .fill(.blue)
                            .frame(width: 14, height: 14)
                        Circle()
                            .fill(.white)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                Task { await locateAndCenter() }
            } label: {
                Image(systemName: isLocating ? "location.fill" : "location")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.blue)
                    .padding(10)
                    .background {
                        if #available(iOS 26, *) {
                            RoundedRectangle(cornerRadius: 8).fill(.clear).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial)
                        }
                    }
            }
            .disabled(isLocating)
            .padding(.trailing, 12)
            .padding(.top, 60)
        }
    }

    // MARK: - Actions

    private func locateAndCenter() async {
        isScrubbing = false
        scrubberValue = 1.0
        isLocating = true
        await onLocate()
        // Reload breadcrumbs to include the new location
        await loadBreadcrumbs()
        // Center on the latest location: try heartbeat first, then latest breadcrumb
        let coord = currentLocation ?? breadcrumbs.last.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        if let coord {
            withAnimation(.easeInOut(duration: 0.5)) {
                position = .camera(MapCamera(centerCoordinate: coord, distance: 2000))
            }
        }
        isLocating = false
    }

    private func zoomToFitTrail() {
        guard !breadcrumbs.isEmpty else { return }
        let lats = breadcrumbs.map(\.latitude)
        let lons = breadcrumbs.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.3, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.3, 0.01)
        )
        withAnimation {
            position = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    // MARK: - Data Loading

    // Shared breadcrumb cache — persists across view appearances.
    // Key: sorted device IDs joined. Value: (breadcrumbs, fetchedAt).
    private static var breadcrumbCache: [String: ([DeviceLocation], Date)] = [:]
    private static let breadcrumbCacheTTL: TimeInterval = 300 // 5 minutes

    private func loadBreadcrumbs() async {
        guard let cloudKit else { return }
        let deviceIDs = devices.map(\.id)
        let cacheKey = deviceIDs.map(\.rawValue).sorted().joined(separator: ",")

        // Return cached if fresh
        if let (cached, fetchedAt) = Self.breadcrumbCache[cacheKey],
           Date().timeIntervalSince(fetchedAt) < Self.breadcrumbCacheTTL {
            breadcrumbs = cached
            return
        }

        isLoading = true
        let since = Date().addingTimeInterval(-30 * 86400)
        var all: [DeviceLocation] = []
        for deviceID in deviceIDs {
            if let crumbs = try? await cloudKit.fetchLocationBreadcrumbs(deviceID: deviceID, since: since) {
                all.append(contentsOf: crumbs)
            }
        }
        let sorted = all.sorted { $0.timestamp < $1.timestamp }
        breadcrumbs = sorted
        Self.breadcrumbCache[cacheKey] = (sorted, Date())
        isLoading = false
    }

    // MARK: - Road Route Resolution

    private func resolveRoutes() async {
        // Use deduplicated breadcrumbs to avoid phantom routes from GPS jitter.
        let deduped = deduplicatedBreadcrumbs()
        let points = deduped.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard points.count >= 2 else { return }

        // Map deduplicated points back to original breadcrumb indices for the segment mapping.
        var dedupedToOriginal: [Int] = []
        var origIdx = 0
        for d in deduped {
            while origIdx < breadcrumbs.count && breadcrumbs[origIdx].id != d.id {
                origIdx += 1
            }
            dedupedToOriginal.append(min(origIdx, breadcrumbs.count - 1))
            origIdx += 1
        }

        // Build waypoints filtering out points too close together (>200m apart).
        var waypoints: [CLLocationCoordinate2D] = [points[0]]
        var waypointDedupedIndices: [Int] = [0]
        for i in 1..<points.count {
            let prev = waypoints.last!
            let dist = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                .distance(from: CLLocation(latitude: points[i].latitude, longitude: points[i].longitude))
            if dist > 200 {
                waypoints.append(points[i])
                waypointDedupedIndices.append(i)
            }
        }
        if let last = points.last,
           let wLast = waypoints.last,
           (wLast.latitude != last.latitude || wLast.longitude != last.longitude) {
            waypoints.append(last)
            waypointDedupedIndices.append(points.count - 1)
        }

        guard waypoints.count >= 2 else { return }

        // Build segment → original breadcrumb index mapping.
        var segMapping: [Int] = []
        for i in 1..<waypointDedupedIndices.count {
            let dedupIdx = waypointDedupedIndices[i]
            segMapping.append(dedupIdx < dedupedToOriginal.count ? dedupedToOriginal[dedupIdx] : breadcrumbs.count - 1)
        }

        let totalSegments = waypoints.count - 1
        routeProgress = "Loading routes (0/\(totalSegments))..."
        var resolved: [MKPolyline] = []

        for i in 0..<(waypoints.count - 1) {
            let from = waypoints[i]
            let to = waypoints[i + 1]
            let cacheKey = RouteCache.routeCacheKey(from: from, to: to)

            // Check cache first
            if let cached = RouteCache.loadCachedRoute(key: cacheKey) {
                resolved.append(cached)
            } else {
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
                        resolved.append(route.polyline)
                        RouteCache.cacheRoute(route.polyline, key: cacheKey)
                    }
                } catch {
                    let coords = [from, to]
                    resolved.append(MKPolyline(coordinates: coords, count: 2))
                }

                // Throttle only for non-cached requests
                if i < waypoints.count - 2 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }

            if (i + 1) % 5 == 0 || i == waypoints.count - 2 {
                routeSegments = resolved
                routeProgress = "Loading routes (\(i + 1)/\(totalSegments))..."
            }
        }

        routeSegments = resolved
        segmentToBreadcrumbIndex = segMapping
        routeProgress = nil
    }

    // MARK: - Route Cache

    /// Cache key from rounded coordinates (4 decimal places ~ 11m precision).
    private static func routeCacheKey(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> String {
        let r = { (v: Double) in String(format: "%.4f", v) }
        return "\(r(from.latitude)),\(r(from.longitude))-\(r(to.latitude)),\(r(to.longitude))"
    }

    private static var cacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("route-cache", isDirectory: true)
    }

    private static func cacheRoute(_ polyline: MKPolyline, key: String) {
        let dir = cacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let count = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        let encoded = coords.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";")
        let file = dir.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)
        try? encoded.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func loadCachedRoute(key: String) -> MKPolyline? {
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
}
