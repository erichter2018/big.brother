import Foundation

/// Per-child driving safety settings configured by the parent.
/// Stored in App Group UserDefaults on the child device.
public struct DrivingSettings: Codable, Sendable, Equatable {
    /// Speed threshold in mph — alert parent when exceeded.
    public var speedThresholdMPH: Double

    /// Deceleration threshold in g — flag as hard braking when exceeded.
    public var hardBrakingThresholdG: Double

    /// Whether phone-while-driving detection is enabled.
    public var phoneUsageDetectionEnabled: Bool

    /// Whether speed alerts are enabled.
    public var speedAlertEnabled: Bool

    /// Whether hard braking detection is enabled.
    public var hardBrakingDetectionEnabled: Bool

    public init(
        speedThresholdMPH: Double = 80,
        hardBrakingThresholdG: Double = 0.7,
        phoneUsageDetectionEnabled: Bool = true,
        speedAlertEnabled: Bool = true,
        hardBrakingDetectionEnabled: Bool = true
    ) {
        self.speedThresholdMPH = speedThresholdMPH
        self.hardBrakingThresholdG = hardBrakingThresholdG
        self.phoneUsageDetectionEnabled = phoneUsageDetectionEnabled
        self.speedAlertEnabled = speedAlertEnabled
        self.hardBrakingDetectionEnabled = hardBrakingDetectionEnabled
    }

    public static let `default` = DrivingSettings()
}
