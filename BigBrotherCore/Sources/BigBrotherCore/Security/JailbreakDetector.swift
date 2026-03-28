import Foundation
import MachO

/// Detects common jailbreak indicators on the device.
/// Runs on child device only; result reported via heartbeat.
public enum JailbreakDetector {

    /// Returns true if any jailbreak indicator is found.
    public static func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return checkSuspiciousPaths()
            || checkDyldImages()
            || checkDyldInsertLibraries()
        #endif
    }

    /// Returns a description of which check triggered, for diagnostics.
    /// Returns nil if no jailbreak detected.
    public static func detectedReason() -> String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        if let path = matchingSuspiciousPath() { return "path:\(path)" }
        if let lib = matchingDyldImage() { return "dyld:\(lib)" }
        if checkDyldInsertLibraries() { return "dyld_insert_libraries" }
        return nil
        #endif
    }

    // MARK: - File System Checks

    private static let suspiciousPaths = [
        "/Applications/Cydia.app",
        "/Applications/Sileo.app",
        "/Applications/Zebra.app",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/usr/sbin/sshd",
        "/etc/apt",
        "/private/var/lib/apt/",
        "/usr/bin/ssh",
        "/private/var/stash",
        "/usr/lib/TweakInject",
        "/.installed_unc0ver",
        "/.bootstrapped_electra",
    ]

    private static func checkSuspiciousPaths() -> Bool {
        matchingSuspiciousPath() != nil
    }

    private static func matchingSuspiciousPath() -> String? {
        suspiciousPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - dyld Image Inspection

    /// Known jailbreak/hooking library names. Matched against the last path
    /// component of each loaded dyld image to avoid false positives from
    /// substring matches (e.g. "Shadow" in a legitimate framework path).
    private static let suspiciousLibraries = [
        "FridaGadget", "frida-agent",
        "cynject", "libcycript",
        "SubstrateLoader", "SubstrateInserter", "MobileSubstrate",
        "SSLKillSwitch",
        "TweakInject", "libhooker", "Substitute",
        "rocketbootstrap",
        "Shadow", "Liberty", "Choicy",
        "A-Bypass", "FlyJB",
    ]

    private static func checkDyldImages() -> Bool {
        matchingDyldImage() != nil
    }

    /// Returns the path of the first suspicious dyld image, or nil.
    private static func matchingDyldImage() -> String? {
        let count = _dyld_image_count()
        for i in 0..<count {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let path = String(cString: cName)
            // Match against the filename (last path component) to avoid
            // false positives from substring matches in directory names.
            let filename = (path as NSString).lastPathComponent
            for lib in suspiciousLibraries {
                if filename.contains(lib) {
                    return path
                }
            }
        }
        return nil
    }

    // MARK: - DYLD_INSERT_LIBRARIES

    /// If DYLD_INSERT_LIBRARIES is set, code injection is occurring.
    /// Skipped in DEBUG builds — Xcode's debugger sets this variable normally.
    private static func checkDyldInsertLibraries() -> Bool {
        #if DEBUG
        return false
        #else
        return ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] != nil
        #endif
    }
}
