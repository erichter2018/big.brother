import Foundation

/// Shared utility for filtering out useless app name strings.
public enum AppNameUtils {
    /// Returns true if the name is a meaningful app name (not a token hash, placeholder, etc.).
    public static func isUseful(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !n.isEmpty else { return false }
        if n == "app" || n == "an app" || n == "unknown" { return false }
        if n.hasPrefix("blocked app ") { return false }
        if n.contains("token(") { return false }
        return true
    }
}
