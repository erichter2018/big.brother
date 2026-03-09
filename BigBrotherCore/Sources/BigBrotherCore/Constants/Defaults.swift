import Foundation

/// Default values and reference data for the policy engine.
public enum Defaults {

    /// Reference bundle IDs for the "Essential Only" mode.
    ///
    /// These are for documentation and capability checking only.
    /// Actual enforcement uses opaque ApplicationToken / ActivityCategoryToken
    /// from FamilyControls, which are resolved on-device.
    ///
    /// Note: Some of these (Phone, Messages) cannot be blocked by ManagedSettings
    /// regardless — they are listed here to document the intent.
    public static let essentialAppBundleIDs: Set<String> = [
        "com.apple.MobileSMS",           // Messages
        "com.apple.Maps",                 // Maps
        "com.apple.mobilephone",          // Phone
        "com.apple.facetime",             // FaceTime
        "com.apple.findmy",              // Find My
        "com.apple.camera",              // Camera
        "com.apple.mobiletimer",          // Clock
        "com.apple.MobileAddressBook",    // Contacts
    ]

    /// Category identifiers considered "essential" for the Essential Only mode.
    /// Maps to ActivityCategory tokens on-device.
    public static let essentialCategoryNames: Set<String> = [
        "utilities",
        "communication",
    ]

    /// Character set for enrollment code generation.
    /// Excludes ambiguous characters: 0/O, 1/I/L.
    /// 32 characters → 8-char code = ~1.1 trillion combinations.
    public static let enrollmentCodeCharacterSet: [Character] = Array(
        "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    )

    /// Display names for lock modes, for use in shield screens and logs.
    public static let lockModeDescriptions: [LockMode: String] = [
        .unlocked: "Unlocked — all apps accessible",
        .dailyMode: "Daily Mode — only allowed apps accessible",
        .fullLockdown: "Full Lockdown — all apps restricted",
        .essentialOnly: "Essential Only — limited to essential apps",
    ]
}
