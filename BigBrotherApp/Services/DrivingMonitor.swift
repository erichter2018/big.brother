import Foundation
import CoreLocation
import CoreMotion
import BigBrotherCore

/// Monitors driving behavior on child devices: speed, phone usage, hard braking.
///
/// Orchestrates all driving safety features:
/// - Tracks max speed per trip, alerts parent when threshold exceeded
/// - Detects phone-while-driving (screen unlocked >10s during automotive activity)
/// - Detects hard braking (deceleration >0.4g via CMDeviceMotion)
/// - Logs trip completion with summary data
///
/// Activated by LocationService when CoreMotion detects automotive activity.
/// All events are logged via EventLogger and immediately synced to CloudKit
/// so the parent gets near-real-time notifications.
final class DrivingMonitor: @unchecked Sendable {

    private let eventLogger: any EventLoggerProtocol
    private let cloudKit: any CloudKitServiceProtocol
    private let storage: any SharedStorageProtocol
    private let keychain: any KeychainProtocol

    /// Serial queue protecting all mutable state below.
    private let stateQueue = DispatchQueue(label: "fr.bigbrother.DrivingMonitor.state")

    // MARK: - Driving State (all access must go through stateQueue)

    private var _isDriving = false
    private(set) var isDriving: Bool {
        get { stateQueue.sync { _isDriving } }
        set { stateQueue.sync { _isDriving = newValue } }
    }
    private var currentTripStartedAt: Date?
    private var maxSpeedMPS: Double = 0         // m/s
    private var speedSamples: [Double] = []     // rolling window for averaging
    private var hardBrakingCount: Int = 0
    private var phoneUsageCount: Int = 0
    private var speedAlertSentThisTrip = false
    private var phoneAlertSentThisTrip = false
    private var tripDistanceMeters: Double = 0
    private var lastTripLocation: CLLocation?

    // Hard braking detection
    private let motionManager = CMMotionManager()
    private var brakingOperationQueue = OperationQueue()
    private var decelSamples: [Double] = []     // recent deceleration magnitudes
    private var lastBrakingEventAt: Date?        // cooldown between events

    // Phone-while-driving detection
    private var screenUnlockedWhileDrivingAt: Date?
    private var phoneCheckTimer: Timer?

    // Speed limit detection
    let speedLimitService = SpeedLimitService.shared
    private var _currentSpeedLimitMPH: Int?
    private(set) var currentSpeedLimitMPH: Int? {
        get { stateQueue.sync { _currentSpeedLimitMPH } }
        set { stateQueue.sync { _currentSpeedLimitMPH = newValue } }
    }
    private var speedLimitAlertCount: Int = 0
    private var lastSpeedLimitAlertAt: Date?

    // MARK: - Settings

    private var settings: DrivingSettings {
        guard let data = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .data(forKey: "drivingSettings"),
              let s = try? JSONDecoder().decode(DrivingSettings.self, from: data)
        else { return .default }
        return s
    }

    private let diagStorage = AppGroupStorage()

    private func logDiag(_ message: String) {
        try? diagStorage.appendDiagnosticEntry(DiagnosticEntry(
            category: .enforcement,
            message: "[Driving] \(message)"
        ))
        #if DEBUG
        print("[DrivingMonitor] \(message)")
        #endif
    }

    init(
        eventLogger: any EventLoggerProtocol,
        cloudKit: any CloudKitServiceProtocol,
        storage: any SharedStorageProtocol = AppGroupStorage(),
        keychain: any KeychainProtocol = KeychainManager()
    ) {
        self.eventLogger = eventLogger
        self.cloudKit = cloudKit
        self.storage = storage
        self.keychain = keychain
        brakingOperationQueue.name = "DrivingMonitor.braking"
        brakingOperationQueue.maxConcurrentOperationCount = 1
    }

    // MARK: - Motion Activity Callbacks

    /// Called by LocationService when CoreMotion detects automotive activity.
    func onDrivingStarted() {
        let shouldStartBraking: Bool = stateQueue.sync {
            guard !_isDriving else { return false }
            _isDriving = true
            currentTripStartedAt = Date()
            maxSpeedMPS = 0
            speedSamples = []
            hardBrakingCount = 0
            phoneUsageCount = 0
            speedAlertSentThisTrip = false
            phoneAlertSentThisTrip = false
            tripDistanceMeters = 0
            lastTripLocation = nil
            _currentSpeedLimitMPH = nil
            speedLimitAlertCount = 0
            return true
        }

        guard shouldStartBraking else { return }

        let s = settings
        if s.isDriver && s.hardBrakingDetectionEnabled {
            startBrakingDetection()
        }

        logDiag("Trip started (driver=\(s.isDriver) speed alert=\(s.speedAlertEnabled) threshold=\(Int(s.speedThresholdMPH))mph phone=\(s.phoneUsageDetectionEnabled) braking=\(s.hardBrakingDetectionEnabled))")
    }

    /// Called by LocationService when CoreMotion reports stationary for >5 min.
    func onDrivingEnded() {
        let tripSnapshot: (startedAt: Date, maxMPH: Double, avgMPH: Double, miles: Double, brakes: Int, phone: Int, speedViolations: Int)? = stateQueue.sync {
            guard _isDriving else { return nil }
            _isDriving = false

            guard let startedAt = currentTripStartedAt else {
                currentTripStartedAt = nil
                return nil
            }

            let maxMPH = maxSpeedMPS * 2.23694
            let avgMPH = speedSamples.isEmpty ? 0 :
                (speedSamples.reduce(0, +) / Double(speedSamples.count)) * 2.23694
            let miles = tripDistanceMeters / 1609.344
            let snapshot = (startedAt: startedAt, maxMPH: maxMPH, avgMPH: avgMPH, miles: miles,
                            brakes: hardBrakingCount, phone: phoneUsageCount,
                            speedViolations: speedLimitAlertCount)
            currentTripStartedAt = nil
            return snapshot
        }

        guard let snap = tripSnapshot else { return }

        stopBrakingDetection()
        cancelPhoneCheck()

        let duration = Date().timeIntervalSince(snap.startedAt)

        // Filter out false trips — walking, GPS jitter, brief vehicle proximity.
        // Real car trips are > 0.2 miles AND > 10 mph max speed AND > 1 minute.
        if snap.miles < 0.2 || snap.maxMPH < 10 || duration < 60 {
            logDiag("Trip discarded (too short: \(String(format: "%.1f", snap.miles))mi, \(Int(snap.maxMPH))mph max, \(Int(duration))s)")
            return
        }

        // Log trip completion
        let details: [String: Any] = [
            "maxSpeedMPH": Int(snap.maxMPH),
            "avgSpeedMPH": Int(snap.avgMPH),
            "durationMinutes": Int(duration / 60),
            "distanceMiles": String(format: "%.1f", snap.miles),
            "hardBrakingCount": snap.brakes,
            "phoneUsageCount": snap.phone,
            "speedLimitViolations": snap.speedViolations
        ]

        if let json = try? JSONSerialization.data(withJSONObject: details),
           let str = String(data: json, encoding: .utf8) {
            eventLogger.log(.tripCompleted, details: str)
            syncEventsImmediately()
        }

        #if DEBUG
        print("[DrivingMonitor] Trip ended: \(Int(snap.maxMPH)) mph max, \(String(format: "%.1f", snap.miles)) mi, \(snap.brakes) hard brakes, \(snap.phone) phone events")
        #endif
    }

    // MARK: - Location Updates

    /// Called by LocationService on each location update during driving.
    func onLocationUpdate(_ location: CLLocation) {
        guard location.speed >= 0 else { return }

        let (avgSpeedMPH, shouldCheckAbsolute, samplesSnapshot, maxMPSSnapshot, limitMPH): (Double, Bool, [Double], Double, Int?) = stateQueue.sync {
            guard _isDriving else { return (0, false, [], 0, nil) }

            // Track distance
            if let last = lastTripLocation {
                tripDistanceMeters += location.distance(from: last)
            }
            lastTripLocation = location

            // Track speed (m/s)
            let speed = location.speed
            maxSpeedMPS = max(maxSpeedMPS, speed)

            // Rolling window of last 5 samples for averaged threshold check
            speedSamples.append(speed)
            if speedSamples.count > 5 {
                speedSamples.removeFirst()
            }

            let avg = speedSamples.isEmpty ? 0 :
                (speedSamples.reduce(0, +) / Double(speedSamples.count)) * 2.23694

            return (avg, true, speedSamples, maxSpeedMPS, _currentSpeedLimitMPH)
        }

        guard shouldCheckAbsolute, settings.isDriver else { return }

        // Query speed limit for this location (async, cached by geohash)
        let coord = location.coordinate
        Task {
            if let limit = await self.speedLimitService.speedLimit(at: coord) {
                self.currentSpeedLimitMPH = limit
                self.checkSpeedAgainstLimit(currentMPH: avgSpeedMPH, limitMPH: limit)
            }
        }

        // Also check absolute speed threshold from parent settings
        let s = settings
        let alertSent = stateQueue.sync { speedAlertSentThisTrip }
        if s.isDriver && s.speedAlertEnabled && avgSpeedMPH > s.speedThresholdMPH && !alertSent {
            let overThreshold = samplesSnapshot.filter { $0 * 2.23694 > s.speedThresholdMPH }
            if overThreshold.count >= 3 {
                stateQueue.sync { speedAlertSentThisTrip = true }
                let limitInfo = limitMPH.map { " (posted \($0) mph)" } ?? ""
                let details = "Max \(Int(maxMPSSnapshot * 2.23694)) mph\(limitInfo) — threshold \(Int(s.speedThresholdMPH)) mph"
                eventLogger.log(.speedingDetected, details: details)
                syncEventsImmediately()
                logDiag("Speeding alert: \(details)")
            }
        }
    }

    /// Check if current speed exceeds the posted speed limit.
    /// Alerts for >10 mph over the limit, throttled to 1 per 5 minutes.
    private func checkSpeedAgainstLimit(currentMPH: Double, limitMPH: Int) {
        let overBy = currentMPH - Double(limitMPH)
        guard overBy > 10 else { return } // Only alert for >10 mph over

        let shouldAlert: Bool = stateQueue.sync {
            // Require 3+ consecutive samples over the limit to avoid GPS spikes
            let overLimit = speedSamples.filter { $0 * 2.23694 > Double(limitMPH) + 5 }
            guard overLimit.count >= 3 else { return false }

            // Throttle: max 1 alert per 5 minutes
            if let last = lastSpeedLimitAlertAt, Date().timeIntervalSince(last) < 300 { return false }
            lastSpeedLimitAlertAt = Date()
            speedLimitAlertCount += 1
            return true
        }

        guard shouldAlert else { return }

        let details = "\(Int(currentMPH)) mph in \(limitMPH) mph zone (\(Int(overBy)) over)"
        eventLogger.log(.speedingDetected, details: details)
        syncEventsImmediately()
        logDiag("Posted limit exceeded: \(details)")
    }

    // MARK: - Phone-While-Driving Detection

    /// Called by DeviceLockMonitor when screen lock state changes.
    func onScreenLockStateChanged(isLocked: Bool) {
        let driving = stateQueue.sync { _isDriving }
        guard driving, settings.isDriver, settings.phoneUsageDetectionEnabled else {
            cancelPhoneCheck()
            stateQueue.sync { screenUnlockedWhileDrivingAt = nil }
            return
        }

        if !isLocked {
            // Screen unlocked while driving — start 10-second timer
            stateQueue.sync { screenUnlockedWhileDrivingAt = Date() }
            schedulePhoneCheck()
        } else {
            let duration: TimeInterval? = stateQueue.sync {
                guard let startedAt = screenUnlockedWhileDrivingAt else { return nil }
                let dur = Date().timeIntervalSince(startedAt)
                screenUnlockedWhileDrivingAt = nil
                return dur
            }
            if let duration, duration >= 10 {
                recordPhoneUsageEvent(duration: duration)
            }
            cancelPhoneCheck()
        }
    }

    private func schedulePhoneCheck() {
        let schedule = { [weak self] in
            guard let self else { return }
            self.stateQueue.sync {
                self.phoneCheckTimer?.invalidate()
                self.phoneCheckTimer = nil
            }
            let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                guard let self else { return }
                let shouldRecord: Bool = self.stateQueue.sync {
                    self._isDriving && self.screenUnlockedWhileDrivingAt != nil
                }
                if shouldRecord {
                    self.recordPhoneUsageEvent(duration: 10)
                }
            }
            self.stateQueue.sync { self.phoneCheckTimer = timer }
        }
        if Thread.isMainThread {
            schedule()
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    private func cancelPhoneCheck() {
        let cancel = { [weak self] in
            guard let self else { return }
            let timer: Timer? = self.stateQueue.sync {
                let t = self.phoneCheckTimer
                self.phoneCheckTimer = nil
                return t
            }
            timer?.invalidate()
        }
        if Thread.isMainThread {
            cancel()
        } else {
            DispatchQueue.main.async(execute: cancel)
        }
    }

    private func recordPhoneUsageEvent(duration: TimeInterval) {
        let (shouldAlert, speedMPH): (Bool, Int) = stateQueue.sync {
            phoneUsageCount += 1

            guard !phoneAlertSentThisTrip else { return (false, 0) }
            phoneAlertSentThisTrip = true
            let mph = Int((speedSamples.last ?? 0) * 2.23694)
            return (true, mph)
        }

        if shouldAlert {
            let details = "Phone used for \(Int(duration))s while driving at ~\(speedMPH) mph"
            eventLogger.log(.phoneWhileDriving, details: details)
            syncEventsImmediately()
            #if DEBUG
            print("[DrivingMonitor] Phone-while-driving: \(details)")
            #endif
        }
    }

    // MARK: - Hard Braking Detection

    /// Start monitoring accelerometer for hard braking events.
    /// Uses CMDeviceMotion.userAcceleration which removes gravity — orientation-independent.
    private func startBrakingDetection() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0  // 50 Hz
        stateQueue.sync { decelSamples = [] }

        motionManager.startDeviceMotionUpdates(to: brakingOperationQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            let driving = self.stateQueue.sync { self._isDriving }
            guard driving else { return }

            // userAcceleration is in g's, with gravity removed.
            // We use the magnitude of all axes since phone orientation varies.
            let accel = motion.userAcceleration
            let magnitude = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)

            let threshold = self.settings.hardBrakingThresholdG

            let result: (shouldLog: Bool, count: Int, avg: Double, speedMPH: Int)? = self.stateQueue.sync {
                // Track recent samples (last 0.5s = 25 samples at 50Hz)
                self.decelSamples.append(magnitude)
                if self.decelSamples.count > 25 {
                    self.decelSamples.removeFirst()
                }

                // Check if average deceleration over window exceeds threshold.
                // 30-second cooldown between events to avoid counting one braking action multiple times.
                guard self.decelSamples.count >= 15 else { return nil }

                let avg = self.decelSamples.reduce(0, +) / Double(self.decelSamples.count)
                guard avg > threshold else { return nil }

                // Cooldown: ignore if we just triggered
                if let last = self.lastBrakingEventAt, Date().timeIntervalSince(last) < 30 {
                    self.decelSamples = []
                    return nil
                }
                self.lastBrakingEventAt = Date()
                self.hardBrakingCount += 1
                self.decelSamples = [] // Reset to avoid repeated triggers

                let speedMPH = Int((self.speedSamples.last ?? 0) * 2.23694)
                return (shouldLog: self.hardBrakingCount <= 3, count: self.hardBrakingCount, avg: avg, speedMPH: speedMPH)
            }

            if let result {
                let details = "Deceleration: \(String(format: "%.2f", result.avg))g at ~\(result.speedMPH) mph"
                // Only log first 3 events to CloudKit per trip (rest counted in summary)
                if result.shouldLog {
                    self.eventLogger.log(.hardBrakingDetected, details: details)
                    self.syncEventsImmediately()
                }
                self.logDiag("Hard braking #\(result.count): \(details)")
            }
        }
    }

    private func stopBrakingDetection() {
        motionManager.stopDeviceMotionUpdates()
        stateQueue.sync { decelSamples = [] }
    }

    // MARK: - Event Sync

    /// Immediately sync events to CloudKit so parent gets near-real-time alerts.
    private func syncEventsImmediately() {
        Task {
            try? await eventLogger.syncPendingEvents()
        }
    }
}
