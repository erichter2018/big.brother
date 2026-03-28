import Foundation
import CoreLocation
import CoreMotion
import BigBrotherCore

/// Manages location tracking on child devices.
///
/// Three modes:
///   .off         — no tracking
///   .onDemand    — parent taps "Locate" for a one-shot
///   .continuous  — significant-location-change monitoring (requires Always authorization)
///
/// In continuous mode, iOS delivers location updates even when the app is
/// suspended or terminated. Significant-location-change wakes the app with
/// ~500m granularity and minimal battery impact.
///
/// The heartbeat timer also calls `refreshLocation()` on each tick so the
/// parent sees reasonably fresh data even if the device hasn't moved enough
/// to trigger a significant change event.
final class LocationService: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    private let locationManager = CLLocationManager()
    private let cloudKit: any CloudKitServiceProtocol
    private let keychain: any KeychainProtocol
    private(set) var mode: LocationTrackingMode = .off

    /// Cached last known location for heartbeat inclusion.
    private(set) var lastLocation: CLLocation?
    private(set) var lastAddress: String?

    /// Continuation for on-demand location requests.
    private var pendingContinuation: CheckedContinuation<CLLocation?, Never>?
    private let continuationLock = NSLock()

    /// Atomically read-and-nil the pending continuation so it can only be resumed once.
    private func consumeContinuation() -> CheckedContinuation<CLLocation?, Never>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let cont = pendingContinuation
        pendingContinuation = nil
        return cont
    }

    /// Throttle breadcrumb saves — interval adapts to movement state.
    /// Throttle breadcrumb saves — reset to nil to force immediate save.
    var lastBreadcrumbSaveAt: Date?

    /// Whether the device is currently moving (speed > threshold).
    /// HeartbeatService can read this to adjust heartbeat frequency.
    private(set) var isMoving = false

    /// When active tracking started (for auto-revert to significant-change monitoring).
    /// When active (high-frequency) tracking started (exposed for diagnostics).
    private(set) var activeTrackingStartedAt: Date?

    /// Time since last detected movement, used to revert to passive tracking.
    private var lastMovementAt: Date?

    /// Breadcrumb interval: 60s when moving, 300s when stationary.
    /// Breadcrumb interval: 60s when moving, 300s when stationary (exposed for diagnostics).
    var breadcrumbInterval: TimeInterval {
        if drivingMonitor?.isDriving == true { return 15 }
        return isMoving ? 60 : 300
    }

    /// Speed threshold for "moving" detection (m/s). ~4.5 mph / walking pace.
    private static let movingSpeedThreshold: CLLocationSpeed = 2.0

    /// Distance threshold for movement detection (meters). If consecutive locations
    /// are this far apart, the device is moving — even if CLLocation.speed is invalid.
    private static let movementDistanceThreshold: CLLocationDistance = 100

    /// How long to stay in active tracking after movement stops (seconds).
    private static let activeTrackingCooldown: TimeInterval = 300

    /// Speed threshold for GPS-based driving detection (m/s). ~20 mph.
    /// When 3+ consecutive location updates exceed this, DrivingMonitor activates
    /// even without CoreMotion automotive classification.
    private static let drivingSpeedThreshold: CLLocationSpeed = 8.9

    /// Consecutive high-speed sample count for GPS-based driving detection.
    private var consecutiveHighSpeedSamples: Int = 0

    /// Previous location for distance-based movement detection.
    private var previousBreadcrumbLocation: CLLocation?

    /// Diagnostic storage for remote reports (writes are cheap — App Group file append).
    private let diagStorage = AppGroupStorage()

    /// Throttle diagnostic logging to avoid flooding (max 1 per category per 30s).
    private var lastDiagLogAt: [String: Date] = [:]

    private func logDiag(_ message: String, throttleKey: String? = nil) {
        if let key = throttleKey, let last = lastDiagLogAt[key],
           Date().timeIntervalSince(last) < 30 { return }
        if let key = throttleKey { lastDiagLogAt[key] = Date() }
        try? diagStorage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "[Location] \(message)"
        ))
        #if DEBUG
        print("[LocationService] \(message)")
        #endif
    }

    /// Previous geocoded location — only re-geocode when moved 200m+ from this point.
    private var lastGeocodedLocation: CLLocation?

    /// CoreMotion activity manager — detects walking/driving/stationary via the
    /// motion coprocessor with near-zero battery impact.
    private let motionManager = CMMotionActivityManager()

    /// Whether CoreMotion is actively monitoring.
    /// Whether CoreMotion is actively monitoring (exposed for diagnostics).
    private(set) var motionMonitoringActive = false

    init(
        cloudKit: any CloudKitServiceProtocol,
        keychain: any KeychainProtocol
    ) {
        self.cloudKit = cloudKit
        self.keychain = keychain
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        // Don't show blue status bar indicator — we want this to be invisible.
        locationManager.showsBackgroundLocationIndicator = false

        // Restore persisted mode, defaulting to .continuous on child devices.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if let raw = defaults?.string(forKey: "locationTrackingMode"),
           let saved = LocationTrackingMode(rawValue: raw) {
            setMode(saved)
        } else {
            // First launch — default to continuous tracking for all devices.
            setMode(.continuous)
        }
    }

    /// Current CLAuthorizationStatus as a heartbeat-friendly string.
    var authorizationStatusString: String {
        switch locationManager.authorizationStatus {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Mode Management

    func setMode(_ newMode: LocationTrackingMode) {
        mode = newMode
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(newMode.rawValue, forKey: "locationTrackingMode")

        switch newMode {
        case .off:
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopUpdatingLocation()
            locationManager.stopMonitoringVisits()
            stopMotionMonitoring()
            for region in locationManager.monitoredRegions {
                locationManager.stopMonitoring(for: region)
            }
        case .onDemand:
            locationManager.stopMonitoringSignificantLocationChanges()
            // Request Always so on-demand works even from background.
            requestAlwaysAuthIfNeeded()
        case .continuous:
            requestAlwaysAuthIfNeeded()
            startContinuousTracking()
        }
    }

    private func requestAlwaysAuthIfNeeded() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            // On iOS, requestAlwaysAuthorization() shows the full 3-option dialog
            // (Allow Once / While Using / Always) if called before requestWhenInUseAuthorization().
            locationManager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            // Already has "When In Use" — request upgrade to Always.
            // iOS shows a follow-up prompt: "Change to Always Allow?"
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            break // Already good
        default:
            break // Denied/restricted — can't re-prompt, user must go to Settings
        }
    }

    private func startContinuousTracking() {
        let status = locationManager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            locationManager.startMonitoringSignificantLocationChanges()
            registerHomeGeofenceIfConfigured()
            locationManager.startMonitoringVisits()
            locationManager.requestLocation()
            startMotionMonitoring()
        }
    }

    // MARK: - CoreMotion Activity Detection

    /// Start monitoring device motion via the motion coprocessor.
    /// Near-zero battery impact. Detects driving/walking/stationary within seconds.
    private func startMotionMonitoring() {
        guard CMMotionActivityManager.isActivityAvailable(), !motionMonitoringActive else {
            #if DEBUG
            if !CMMotionActivityManager.isActivityAvailable() {
                print("[LocationService] CoreMotion activity NOT available on this device")
            }
            #endif
            return
        }
        motionMonitoringActive = true
        logDiag("CoreMotion activity monitoring started")

        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }

            let wasMoving = self.isMoving
            let now = Date()

            // Log activity type for diagnostics (throttled — only on transitions)
            let activityDesc = Self.describeActivity(activity)

            if activity.automotive || activity.cycling || activity.running || activity.walking {
                self.isMoving = true
                self.lastMovementAt = now

                if activity.automotive {
                    self.locationManager.activityType = .automotiveNavigation
                } else {
                    self.locationManager.activityType = .fitness
                }

                if !wasMoving && self.mode == .continuous {
                    self.activateHighFrequencyTracking()
                    self.lastBreadcrumbSaveAt = nil
                    self.onRequestImmediateHeartbeat?()
                    self.logDiag("Movement started: \(activityDesc) → high-frequency tracking ON")
                }

                // Notify driving monitor of automotive start
                if activity.automotive && self.drivingMonitor?.isDriving != true {
                    self.drivingMonitor?.onDrivingStarted()
                    self.logDiag("Driving started (CoreMotion automotive)")
                }
            } else if activity.stationary, self.isMoving,
                      let lastMove = self.lastMovementAt,
                      now.timeIntervalSince(lastMove) > Self.activeTrackingCooldown {
                // Notify driving monitor of trip end
                if self.drivingMonitor?.isDriving == true {
                    self.drivingMonitor?.onDrivingEnded()
                    self.consecutiveHighSpeedSamples = 0
                    self.logDiag("Driving ended (stationary for \(Int(Self.activeTrackingCooldown))s)")
                }
                self.logDiag("Movement stopped: stationary → high-frequency tracking OFF")
                self.isMoving = false
                self.locationManager.activityType = .other
                if self.mode == .continuous {
                    self.deactivateHighFrequencyTracking()
                }
            }
        }
    }

    private func stopMotionMonitoring() {
        guard motionMonitoringActive else { return }
        motionManager.stopActivityUpdates()
        motionMonitoringActive = false
    }

    /// Describe a CoreMotion activity for diagnostic logging.
    private static func describeActivity(_ a: CMMotionActivity) -> String {
        var parts: [String] = []
        if a.automotive { parts.append("automotive") }
        if a.cycling { parts.append("cycling") }
        if a.running { parts.append("running") }
        if a.walking { parts.append("walking") }
        if a.stationary { parts.append("stationary") }
        if a.unknown { parts.append("unknown") }
        let conf: String
        switch a.confidence {
        case .high: conf = "high"
        case .medium: conf = "medium"
        case .low: conf = "low"
        @unknown default: conf = "?"
        }
        return "\(parts.joined(separator: "+")) (\(conf) confidence)"
    }

    // MARK: - Adaptive Tracking

    /// Switch to active location updates for higher-resolution tracking while moving.
    /// Sets showsBackgroundLocationIndicator = true, which is REQUIRED since iOS 16.4
    /// for reliable background delivery with distanceFilter + startUpdatingLocation().
    private func activateHighFrequencyTracking() {
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 50  // meters
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        activeTrackingStartedAt = Date()
        #if DEBUG
        print("[LocationService] Activated high-frequency tracking (moving, blue indicator on)")
        #endif
    }

    /// Revert to passive significant-location-change monitoring.
    /// Hides the blue location indicator (only shown during active tracking).
    private func deactivateHighFrequencyTracking() {
        locationManager.stopUpdatingLocation()
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.showsBackgroundLocationIndicator = false
        activeTrackingStartedAt = nil
        #if DEBUG
        print("[LocationService] Deactivated high-frequency tracking (stationary, blue indicator off)")
        #endif
    }

    // MARK: - Home Geofence

    private static let homeRegionIdentifier = "bigbrother.home"
    private static let homeRadiusMeters: CLLocationDistance = 200

    /// Registers a geofence around the home location if coordinates are stored in App Group defaults.
    private func registerHomeGeofenceIfConfigured() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        guard let lat = defaults?.object(forKey: "homeLatitude") as? Double,
              let lon = defaults?.object(forKey: "homeLongitude") as? Double else {
            logDiag("No home coordinates configured — skipping geofence")
            return
        }

        // Remove any existing home region before re-registering.
        for region in locationManager.monitoredRegions {
            if region.identifier == Self.homeRegionIdentifier {
                locationManager.stopMonitoring(for: region)
            }
        }

        let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let region = CLCircularRegion(
            center: center,
            radius: min(Self.homeRadiusMeters, locationManager.maximumRegionMonitoringDistance),
            identifier: Self.homeRegionIdentifier
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        locationManager.startMonitoring(for: region)
        logDiag("Home geofence registered at (\(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))) radius \(Int(Self.homeRadiusMeters))m")
    }

    // MARK: - On-Demand & Heartbeat Refresh

    /// Called by the heartbeat timer to keep location fresh.
    /// Does a lightweight requestLocation() if the cached location is stale (>5 min).
    func refreshLocation() {
        guard mode != .off else { return }
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }

        // Only request if last known is stale (>5 min) or nil.
        if let last = lastLocation, Date().timeIntervalSince(last.timestamp) < 300 {
            return // Fresh enough
        }
        locationManager.requestLocation()
    }

    func requestCurrentLocation() async -> CLLocation? {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestAlwaysAuthorization()
            try? await Task.sleep(for: .seconds(2))
        }
        return await withCheckedContinuation { continuation in
            continuationLock.lock()
            let oldContinuation = pendingContinuation
            pendingContinuation = continuation
            continuationLock.unlock()
            // If a previous request was still pending, resolve it with nil to avoid a leak.
            oldContinuation?.resume(returning: nil)
            locationManager.requestLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location

        // Fulfill on-demand request if pending.
        if let continuation = consumeContinuation() {
            continuation.resume(returning: location)
        }

        // Detect movement by comparing to previous location (more reliable than
        // CLLocation.speed, which is often -1 from significant-location-change updates).
        let now = Date()
        let wasMoving = isMoving

        let distFromPrevious: Double
        if let prev = previousBreadcrumbLocation {
            distFromPrevious = location.distance(from: prev)
        } else {
            distFromPrevious = 0
        }
        previousBreadcrumbLocation = location

        // Also check CLLocation.speed as a secondary signal (valid when > 0).
        let speedValid = location.speed >= Self.movingSpeedThreshold

        if distFromPrevious >= Self.movementDistanceThreshold || speedValid {
            isMoving = true
            lastMovementAt = now

            // Switch to active tracking if we were in passive mode.
            if !wasMoving && mode == .continuous {
                activateHighFrequencyTracking()
            }
        } else if isMoving, let lastMove = lastMovementAt,
                  now.timeIntervalSince(lastMove) > Self.activeTrackingCooldown {
            // Stopped moving for long enough — revert to passive tracking.
            if drivingMonitor?.isDriving == true {
                drivingMonitor?.onDrivingEnded()
                consecutiveHighSpeedSamples = 0
                logDiag("Driving ended (GPS: stationary for \(Int(Self.activeTrackingCooldown))s)")
            }
            isMoving = false
            if mode == .continuous {
                deactivateHighFrequencyTracking()
            }
        }

        // Log location update with speed (throttled to every 30s to avoid log flooding)
        let speedMPH = location.speed >= 0 ? location.speed * 2.23694 : -1
        logDiag("Location: \(String(format: "%.4f,%.4f", location.coordinate.latitude, location.coordinate.longitude)) speed=\(String(format: "%.0f", speedMPH))mph dist=\(String(format: "%.0f", distFromPrevious))m moving=\(isMoving)", throttleKey: "locUpdate")

        // GPS-based driving detection: if sustained high speed, activate DrivingMonitor
        // even without CoreMotion automotive classification (CoreMotion often misses
        // short/urban drives at low speeds).
        if let dm = drivingMonitor, !dm.isDriving {
            if location.speed >= Self.drivingSpeedThreshold {
                consecutiveHighSpeedSamples += 1
                if consecutiveHighSpeedSamples >= 3 {
                    dm.onDrivingStarted()
                    logDiag("Driving started (GPS speed \(Int(location.speed * 2.237))mph, 3+ consecutive)")
                }
            } else {
                consecutiveHighSpeedSamples = 0
            }
        } else if drivingMonitor?.isDriving == true && location.speed >= 0 {
            // Reset counter while driving (for potential re-trigger after brief stop)
            consecutiveHighSpeedSamples = 0
        }

        // Forward to driving monitor for speed/braking tracking.
        drivingMonitor?.onLocationUpdate(location)

        // Save breadcrumb (throttle adapts to movement: 60s moving, 300s stationary).
        if lastBreadcrumbSaveAt == nil || now.timeIntervalSince(lastBreadcrumbSaveAt!) > breadcrumbInterval {
            lastBreadcrumbSaveAt = now
            logDiag("Breadcrumb saved (interval=\(Int(breadcrumbInterval))s)")
            Task { await saveBreadcrumb(from: location) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        #if DEBUG
        print("[LocationService] Failed: \(error.localizedDescription)")
        #endif
        consumeContinuation()?.resume(returning: nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        #if DEBUG
        print("[LocationService] Authorization changed: \(status.rawValue)")
        #endif
        if mode == .continuous && (status == .authorizedAlways || status == .authorizedWhenInUse) {
            startContinuousTracking()
        }
    }

    // MARK: - Region Monitoring (Geofence)

    /// Called when a heartbeat should be sent immediately (e.g., geofence transition).
    /// Set by AppState during service configuration.
    var onRequestImmediateHeartbeat: (() -> Void)?

    /// Driving safety monitor — receives location updates and motion activity.
    var drivingMonitor: DrivingMonitor?

    /// Event logger for named place arrival/departure.
    var eventLogger: (any EventLoggerProtocol)?

    /// Named place geofence prefix.
    private static let namedPlacePrefix = "bigbrother.place."

    // MARK: - Named Place Geofences

    /// Register CLCircularRegions for named places. Called after syncNamedPlaces command.
    /// iOS limit: 20 regions. Home uses 1, so max 19 named places.
    func registerNamedPlaces(_ places: [NamedPlace]) {
        // Remove existing named place regions (keep home)
        for region in locationManager.monitoredRegions {
            if region.identifier.hasPrefix(Self.namedPlacePrefix) {
                locationManager.stopMonitoring(for: region)
            }
        }
        // Register up to 19 places
        for place in places.prefix(19) {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                radius: min(place.radiusMeters, locationManager.maximumRegionMonitoringDistance),
                identifier: "\(Self.namedPlacePrefix)\(place.id.uuidString)"
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            locationManager.startMonitoring(for: region)
        }
        // Persist places for lookup on entry/exit
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
                .set(data, forKey: "namedPlaces")
        }
        #if DEBUG
        print("[LocationService] Registered \(min(places.count, 19)) named place geofences")
        #endif
    }

    /// Look up a named place by its geofence region identifier.
    private func namedPlace(for regionID: String) -> NamedPlace? {
        guard regionID.hasPrefix(Self.namedPlacePrefix) else { return nil }
        let idStr = String(regionID.dropFirst(Self.namedPlacePrefix.count))
        guard let data = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .data(forKey: "namedPlaces"),
              let places = try? JSONDecoder().decode([NamedPlace].self, from: data) else { return nil }
        return places.first { $0.id.uuidString == idStr }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        #if DEBUG
        print("[LocationService] Entered region: \(region.identifier)")
        #endif

        // Named place arrival
        if let place = namedPlace(for: region.identifier) {
            logDiag("Geofence ENTER: \(place.name) (\(region.identifier))")
            eventLogger?.log(.namedPlaceArrival, details: "Arrived at \(place.name)")
            Task { try? await eventLogger?.syncPendingEvents() }
            lastBreadcrumbSaveAt = nil
            locationManager.requestLocation()
            onRequestImmediateHeartbeat?()
            return
        }

        guard region.identifier == Self.homeRegionIdentifier else {
            locationManager.requestLocation()
            return
        }
        // Arrived home
        logDiag("Geofence ENTER: Home")
        eventLogger?.log(.namedPlaceArrival, details: "Arrived at Home")
        Task { try? await eventLogger?.syncPendingEvents() }
        locationManager.requestLocation()
        lastBreadcrumbSaveAt = nil
        onRequestImmediateHeartbeat?()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        #if DEBUG
        print("[LocationService] Exited region: \(region.identifier)")
        #endif

        // Named place departure
        if let place = namedPlace(for: region.identifier) {
            logDiag("Geofence EXIT: \(place.name) (\(region.identifier))")
            eventLogger?.log(.namedPlaceDeparture, details: "Left \(place.name)")
            Task { try? await eventLogger?.syncPendingEvents() }
            lastBreadcrumbSaveAt = nil
            locationManager.requestLocation()
            onRequestImmediateHeartbeat?()
            return
        }

        guard region.identifier == Self.homeRegionIdentifier else {
            locationManager.requestLocation()
            return
        }
        // Left home
        logDiag("Geofence EXIT: Home → high-frequency tracking activated")
        eventLogger?.log(.namedPlaceDeparture, details: "Left Home")
        Task { try? await eventLogger?.syncPendingEvents() }
        isMoving = true
        lastMovementAt = Date()
        if mode == .continuous {
            activateHighFrequencyTracking()
        }
        lastBreadcrumbSaveAt = nil
        locationManager.requestLocation()
        onRequestImmediateHeartbeat?()
        #if DEBUG
        print("[LocationService] Exited home geofence — high-frequency tracking activated")
        #endif
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        #if DEBUG
        print("[LocationService] Region monitoring failed for \(region?.identifier ?? "nil"): \(error.localizedDescription)")
        #endif
    }

    // MARK: - Visit Monitoring

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        #if DEBUG
        print("[LocationService] Visit: lat=\(visit.coordinate.latitude) lon=\(visit.coordinate.longitude) arrival=\(visit.arrivalDate) departure=\(visit.departureDate)")
        #endif
        // Update lastLocation with visit coordinate if it's more recent.
        let visitLocation = CLLocation(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
        if let last = lastLocation {
            if visitLocation.timestamp > last.timestamp {
                lastLocation = visitLocation
            }
        } else {
            lastLocation = visitLocation
        }
        // The primary value of visit monitoring is that iOS relaunches the app.
        // Also request a proper location fix.
        locationManager.requestLocation()
    }

    // MARK: - Breadcrumb

    private func saveBreadcrumb(from location: CLLocation) async {
        guard let enrollment = try? keychain.get(
            ChildEnrollmentState.self,
            forKey: StorageKeys.enrollmentState
        ) else { return }

        // Reverse geocode — only when moved 200m+ from last geocoded point
        // to avoid rate-limiting and unnecessary network calls during active tracking.
        var address: String? = lastAddress  // Reuse previous address by default
        let shouldGeocode: Bool
        if let lastGeocoded = lastGeocodedLocation {
            shouldGeocode = location.distance(from: lastGeocoded) >= 200
        } else {
            shouldGeocode = true
        }
        if shouldGeocode {
            do {
                let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
                if let pm = placemarks.first {
                    let parts = [pm.thoroughfare, pm.locality].compactMap { $0 }
                    address = parts.isEmpty ? pm.administrativeArea : parts.joined(separator: ", ")
                }
                lastGeocodedLocation = location
            } catch {
                #if DEBUG
                print("[LocationService] Geocode failed: \(error.localizedDescription)")
                #endif
            }
        }
        lastAddress = address

        let breadcrumb = DeviceLocation(
            deviceID: enrollment.deviceID,
            familyID: enrollment.familyID,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp,
            address: address,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.course >= 0 ? location.course : nil
        )

        do {
            try await cloudKit.saveLocationBreadcrumb(breadcrumb)
        } catch {
            #if DEBUG
            print("[LocationService] Failed to save breadcrumb: \(error.localizedDescription)")
            #endif
        }
    }
}
