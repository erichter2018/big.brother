import SwiftUI
import BigBrotherCore

/// Consistent device icon based on model identifier.
struct DeviceIcon: View {
    let modelIdentifier: String
    var size: Font = .subheadline

    var body: some View {
        Image(systemName: systemName)
            .font(size)
            .foregroundStyle(.secondary)
    }

    var systemName: String {
        modelIdentifier.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone"
    }

    /// Large variant for device detail headers.
    static func large(for model: String) -> DeviceIcon {
        DeviceIcon(modelIdentifier: model, size: .system(size: 44))
    }

    /// Human-readable device name from model identifier.
    static func displayName(for modelIdentifier: String) -> String {
        // Common recent models. Falls back to cleaned-up identifier.
        let lookup: [String: String] = [
            // iPhone
            "iPhone10,1": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,3": "iPhone X",
            "iPhone10,4": "iPhone 8", "iPhone10,5": "iPhone 8 Plus", "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
            "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd gen)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3rd gen)",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17 Air", "iPhone18,4": "iPhone 17", "iPhone18,5": "iPhone 17 Plus",
            // iPad
            "iPad7,1": "iPad Pro 12.9\" (2nd gen)", "iPad7,2": "iPad Pro 12.9\" (2nd gen)",
            "iPad7,3": "iPad Pro 10.5\"", "iPad7,4": "iPad Pro 10.5\"",
            "iPad7,5": "iPad (6th gen)", "iPad7,6": "iPad (6th gen)",
            "iPad7,11": "iPad (7th gen)", "iPad7,12": "iPad (7th gen)",
            "iPad8,1": "iPad Pro 11\" (1st gen)", "iPad8,2": "iPad Pro 11\" (1st gen)",
            "iPad8,3": "iPad Pro 11\" (1st gen)", "iPad8,4": "iPad Pro 11\" (1st gen)",
            "iPad8,5": "iPad Pro 12.9\" (3rd gen)", "iPad8,6": "iPad Pro 12.9\" (3rd gen)",
            "iPad8,7": "iPad Pro 12.9\" (3rd gen)", "iPad8,8": "iPad Pro 12.9\" (3rd gen)",
            "iPad8,9": "iPad Pro 11\" (2nd gen)", "iPad8,10": "iPad Pro 11\" (2nd gen)",
            "iPad8,11": "iPad Pro 12.9\" (4th gen)", "iPad8,12": "iPad Pro 12.9\" (4th gen)",
            "iPad11,1": "iPad mini (5th gen)", "iPad11,2": "iPad mini (5th gen)",
            "iPad11,3": "iPad Air (3rd gen)", "iPad11,4": "iPad Air (3rd gen)",
            "iPad11,6": "iPad (8th gen)", "iPad11,7": "iPad (8th gen)",
            "iPad12,1": "iPad (9th gen)", "iPad12,2": "iPad (9th gen)",
            "iPad13,1": "iPad Air (4th gen)", "iPad13,2": "iPad Air (4th gen)",
            "iPad13,4": "iPad Pro 11\" (3rd gen)", "iPad13,5": "iPad Pro 11\" (3rd gen)",
            "iPad13,6": "iPad Pro 11\" (3rd gen)", "iPad13,7": "iPad Pro 11\" (3rd gen)",
            "iPad13,8": "iPad Pro 12.9\" (5th gen)", "iPad13,9": "iPad Pro 12.9\" (5th gen)",
            "iPad13,10": "iPad Pro 12.9\" (5th gen)", "iPad13,11": "iPad Pro 12.9\" (5th gen)",
            "iPad13,16": "iPad Air (5th gen)", "iPad13,17": "iPad Air (5th gen)",
            "iPad13,18": "iPad (10th gen)", "iPad13,19": "iPad (10th gen)",
            "iPad14,1": "iPad mini (6th gen)", "iPad14,2": "iPad mini (6th gen)",
            "iPad14,3": "iPad Pro 11\" (4th gen)", "iPad14,4": "iPad Pro 11\" (4th gen)",
            "iPad14,5": "iPad Pro 12.9\" (6th gen)", "iPad14,6": "iPad Pro 12.9\" (6th gen)",
            "iPad14,8": "iPad Air 11\" (M2)", "iPad14,9": "iPad Air 11\" (M2)",
            "iPad14,10": "iPad Air 13\" (M2)", "iPad14,11": "iPad Air 13\" (M2)",
            "iPad15,3": "iPad Air 11\" (M3)", "iPad15,4": "iPad Air 11\" (M3)",
            "iPad15,5": "iPad Air 13\" (M3)", "iPad15,6": "iPad Air 13\" (M3)",
            "iPad15,7": "iPad (A16)", "iPad15,8": "iPad (A16)",
            "iPad16,1": "iPad mini (A17 Pro)", "iPad16,2": "iPad mini (A17 Pro)",
            "iPad16,3": "iPad Pro 11\" (M4)", "iPad16,4": "iPad Pro 11\" (M4)",
            "iPad16,5": "iPad Pro 13\" (M4)", "iPad16,6": "iPad Pro 13\" (M4)",
            // iPod
            "iPod9,1": "iPod touch (7th gen)",
        ]

        if let name = lookup[modelIdentifier] { return name }

        // Fallback: show the identifier so it can be added to the lookup table.
        return modelIdentifier
    }
}
