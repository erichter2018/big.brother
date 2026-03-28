import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Device hardware identification utilities.
public enum DeviceInfo {
    /// Returns the current device's model identifier (e.g., "iPhone15,2").
    public static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = systemInfo.machine
        return withUnsafePointer(to: machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: machine)) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }

    /// Returns the current OS version string (e.g., "17.4.1").
    public static var osVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}
