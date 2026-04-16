import Foundation

/// Domains that must ALWAYS resolve, even when DNS filtering / blackhole is
/// active.  These are Apple infrastructure required for CloudKit command
/// delivery, APNs push, iCloud sync, and Apple ID authentication.
///
/// Single source of truth — both the fast-path resolver and the blackhole
/// exemption check delegate here.  Never duplicate this list.
public enum CriticalDomains {

    /// Canonical suffix list.  Every entry is stored **lowercased** and
    /// without a leading dot — the dot is prepended at match time so we get
    /// label-boundary semantics for free (e.g. `.push.apple.com` matches
    /// `gateway.push.apple.com` but not `notpush.apple.com`).
    public static let suffixes: [String] = [
        // Apple Push Notification Service
        "push.apple.com",
        "push-apple.com.akadns.net",
        "courier.push.apple.com",
        // CloudKit / iCloud
        "icloud-content.com",
        "icloud.com",
        // Apple ID / authentication
        "apple.com",
        "apple-dns.net",
        // Apple CDN
        "aaplimg.com",
        "apple.com.akadns.net",
        "cdn-apple.com",
    ]

    // Pre-computed with leading dot for fast suffix matching.
    // Stored as UTF-8 byte arrays so we never allocate during the hot path.
    private static let dotSuffixesUTF8: [[UInt8]] = suffixes.map {
        Array(("." + $0).utf8)
    }

    // Also store the exact suffixes as UTF-8 for the equality check
    // (domain == suffix exactly, no subdomain).
    private static let exactSuffixesUTF8: [[UInt8]] = suffixes.map {
        Array($0.utf8)
    }

    /// Returns `true` when `domain` matches any critical suffix at a DNS
    /// label boundary.  Case-insensitive, allocation-free on the hot path.
    ///
    /// A domain matches when it either **equals** a suffix exactly or
    /// **ends with** `.<suffix>`.  This prevents `notpush.apple.com` from
    /// matching the `push.apple.com` suffix while still allowing
    /// `gateway.push.apple.com`.
    public static func matches(_ domain: String) -> Bool {
        // ASCII-lowercase the domain into a stack buffer.
        // DNS names are always ASCII, so this is safe and avoids
        // Foundation's locale-aware lowercased() allocation.
        var domainBytes = Array(domain.utf8)
        for i in domainBytes.indices {
            let b = domainBytes[i]
            if b >= 0x41 && b <= 0x5A {  // A-Z
                domainBytes[i] = b | 0x20
            }
        }
        let count = domainBytes.count

        for i in 0..<dotSuffixesUTF8.count {
            let dotSuffix = dotSuffixesUTF8[i]
            let exact = exactSuffixesUTF8[i]

            // Exact match: domain == suffix
            if count == exact.count && domainBytes.elementsEqual(exact) {
                return true
            }

            // Subdomain match: domain ends with .suffix
            let suffLen = dotSuffix.count
            if count >= suffLen {
                var match = true
                let offset = count - suffLen
                for j in 0..<suffLen {
                    if domainBytes[offset + j] != dotSuffix[j] {
                        match = false
                        break
                    }
                }
                if match { return true }
            }
        }
        return false
    }
}
