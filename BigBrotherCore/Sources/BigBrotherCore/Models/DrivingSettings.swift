import Foundation

/// Per-child driving safety settings configured by the parent.
/// Stored in App Group UserDefaults on the child device.
public struct DrivingSettings: Codable, Sendable, Equatable {
    /// Whether this child is a driver (vs. always a passenger).
    /// Non-drivers still get trip tracking but no speed/phone/braking alerts.
    public var isDriver: Bool

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
        isDriver: Bool = false,
        speedThresholdMPH: Double = 80,
        hardBrakingThresholdG: Double = 0.7,
        phoneUsageDetectionEnabled: Bool = true,
        speedAlertEnabled: Bool = true,
        hardBrakingDetectionEnabled: Bool = true
    ) {
        self.isDriver = isDriver
        self.speedThresholdMPH = speedThresholdMPH
        self.hardBrakingThresholdG = hardBrakingThresholdG
        self.phoneUsageDetectionEnabled = phoneUsageDetectionEnabled
        self.speedAlertEnabled = speedAlertEnabled
        self.hardBrakingDetectionEnabled = hardBrakingDetectionEnabled
    }

    public static let `default` = DrivingSettings()

    // Backward-compatible decoding: old JSON without `isDriver` defaults to false.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isDriver = (try? container.decode(Bool.self, forKey: .isDriver)) ?? false
        speedThresholdMPH = try container.decode(Double.self, forKey: .speedThresholdMPH)
        hardBrakingThresholdG = try container.decode(Double.self, forKey: .hardBrakingThresholdG)
        phoneUsageDetectionEnabled = try container.decode(Bool.self, forKey: .phoneUsageDetectionEnabled)
        speedAlertEnabled = try container.decode(Bool.self, forKey: .speedAlertEnabled)
        hardBrakingDetectionEnabled = try container.decode(Bool.self, forKey: .hardBrakingDetectionEnabled)
    }
}
