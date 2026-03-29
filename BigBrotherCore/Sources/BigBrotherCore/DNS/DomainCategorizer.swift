import Foundation

/// Categorizes domains and filters infrastructure noise.
/// Used by the VPN tunnel to flag inappropriate domains and skip CDN/analytics junk.
public enum DomainCategorizer {

    // MARK: - Noise Filtering

    /// Returns true if the domain is infrastructure noise (CDN, analytics, ads, OS services).
    public static func isNoise(_ domain: String) -> Bool {
        let lower = domain.lowercased()

        // Apple system services
        if lower.hasSuffix(".apple.com") || lower.hasSuffix(".icloud.com") ||
           lower.hasSuffix(".mzstatic.com") || lower.hasSuffix(".apple-dns.net") { return true }

        // Google infrastructure
        if lower.hasSuffix(".googleapis.com") || lower.hasSuffix(".gstatic.com") ||
           lower.hasSuffix(".googlesyndication.com") || lower.hasSuffix(".googleadservices.com") ||
           lower.hasSuffix(".google-analytics.com") || lower.hasSuffix(".googletagmanager.com") ||
           lower.hasSuffix(".gvt1.com") || lower.hasSuffix(".gvt2.com") ||
           lower.hasSuffix(".1e100.net") { return true }

        // CDNs
        if lower.hasSuffix(".akamaihd.net") || lower.hasSuffix(".akamai.net") ||
           lower.hasSuffix(".akamaiedge.net") || lower.hasSuffix(".akamaitechnologies.com") ||
           lower.hasSuffix(".cloudfront.net") || lower.hasSuffix(".cloudflare.com") ||
           lower.hasSuffix(".cloudflare-dns.com") || lower.hasSuffix(".cdninstagram.com") ||
           lower.hasSuffix(".fbcdn.net") || lower.hasSuffix(".fastly.net") ||
           lower.hasSuffix(".fastlylb.net") || lower.hasSuffix(".edgecastcdn.net") ||
           lower.hasSuffix(".azureedge.net") || lower.hasSuffix(".azurefd.net") ||
           lower.hasSuffix(".jsdelivr.net") || lower.hasSuffix(".unpkg.com") { return true }

        // Ad/tracking networks
        if lower.hasSuffix(".doubleclick.net") || lower.hasSuffix(".adsrvr.org") ||
           lower.hasSuffix(".adnxs.com") || lower.hasSuffix(".criteo.com") ||
           lower.hasSuffix(".moatads.com") || lower.hasSuffix(".scorecardresearch.com") ||
           lower.hasSuffix(".quantserve.com") || lower.hasSuffix(".taboola.com") ||
           lower.hasSuffix(".outbrain.com") || lower.hasSuffix(".unity3d.com") ||
           lower.hasSuffix(".appsflyer.com") || lower.hasSuffix(".adjust.com") ||
           lower.hasSuffix(".branch.io") || lower.hasSuffix(".amplitude.com") ||
           lower.hasSuffix(".mixpanel.com") || lower.hasSuffix(".segment.io") ||
           lower.hasSuffix(".segment.com") || lower.hasSuffix(".sentry.io") ||
           lower.hasSuffix(".crashlytics.com") || lower.hasSuffix(".newrelic.com") ||
           lower.hasSuffix(".demdex.net") || lower.hasSuffix(".omtrdc.net") { return true }

        // DNS/network infrastructure
        if lower.hasSuffix(".in-addr.arpa") || lower.hasSuffix(".ip6.arpa") ||
           lower.hasSuffix(".local") || lower.hasSuffix(".localhost") ||
           lower == "dns.google" || lower == "dns.cloudflare.com" ||
           lower == "dns.quad9.net" { return true }

        // Microsoft/system
        if lower.hasSuffix(".msftconnecttest.com") || lower.hasSuffix(".windowsupdate.com") ||
           lower.hasSuffix(".microsoft.com") && !lower.contains("bing") { return true }

        // Push notification / messaging infra
        if lower.hasSuffix(".push.apple.com") || lower.hasSuffix(".courier.push.apple.com") ||
           lower.hasSuffix(".firebaseio.com") || lower.hasSuffix(".firebaseapp.com") { return true }

        // Certificate / OCSP
        if lower.contains("ocsp") || lower.contains("crl.") ||
           lower.hasSuffix(".digicert.com") || lower.hasSuffix(".letsencrypt.org") ||
           lower.hasSuffix(".pki.goog") { return true }

        // Known short/system domains
        if lower.count < 4 { return true }

        return false
    }

    // MARK: - Inappropriate Domain Detection

    /// Check if a domain is potentially inappropriate. Returns (flagged, category).
    public static func categorize(_ domain: String) -> (flagged: Bool, category: String?) {
        let lower = domain.lowercased()

        // Explicit adult TLDs
        let adultTLDs = [".xxx", ".porn", ".sex", ".adult", ".sexy", ".cam"]
        for tld in adultTLDs {
            if lower.hasSuffix(tld) { return (true, "adult") }
        }

        // Known adult sites (top domains by traffic)
        let adultDomains: Set<String> = [
            "pornhub.com", "xvideos.com", "xnxx.com", "xhamster.com",
            "redtube.com", "youporn.com", "tube8.com", "spankbang.com",
            "beeg.com", "brazzers.com", "realitykings.com", "bangbros.com",
            "onlyfans.com", "fansly.com", "chaturbate.com", "stripchat.com",
            "bongacams.com", "livejasmin.com", "cam4.com", "myfreecams.com",
            "porntrex.com", "eporner.com", "hqporner.com", "daftsex.com",
            "rule34.xxx", "e-hentai.org", "nhentai.net", "hanime.tv",
            "literotica.com", "sexstories.com",
        ]
        for d in adultDomains {
            if lower == d || lower.hasSuffix("." + d) { return (true, "adult") }
        }

        // Gambling
        let gamblingDomains: Set<String> = [
            "bet365.com", "draftkings.com", "fanduel.com", "betmgm.com",
            "caesars.com", "pointsbet.com", "bovada.lv", "betonline.ag",
            "pokerstars.com", "888poker.com", "partypoker.com",
            "williamhill.com", "ladbrokes.com", "betfair.com",
            "stake.com", "roobet.com", "rollbit.com",
        ]
        for d in gamblingDomains {
            if lower == d || lower.hasSuffix("." + d) { return (true, "gambling") }
        }
        let gamblingKeywords = ["casino", "slots", "betting", "sportsbook", "jackpot"]
        for kw in gamblingKeywords {
            if lower.contains(kw) { return (true, "gambling") }
        }

        // Drug-related
        let drugDomains: Set<String> = [
            "leafly.com", "weedmaps.com", "hightimes.com",
        ]
        for d in drugDomains {
            if lower == d || lower.hasSuffix("." + d) { return (true, "drugs") }
        }

        // Violence / weapons
        let weaponDomains: Set<String> = [
            "bestgore.com", "theync.com", "kaotic.com",
        ]
        for d in weaponDomains {
            if lower == d || lower.hasSuffix("." + d) { return (true, "violence") }
        }

        // Proxy / VPN bypass (kid trying to circumvent controls)
        let proxyDomains: Set<String> = [
            "hidemyass.com", "nordvpn.com", "expressvpn.com", "surfshark.com",
            "protonvpn.com", "windscribe.com", "tunnelbear.com",
            "kproxy.com", "hide.me", "vpngate.net",
            "psiphon3.com", "ultrasurf.us", "hotspotshield.com",
        ]
        for d in proxyDomains {
            if lower == d || lower.hasSuffix("." + d) { return (true, "proxy/vpn") }
        }

        // Dating apps
        let datingDomains: Set<String> = [
            "tinder.com", "bumble.com", "hinge.co", "grindr.com",
            "okcupid.com", "pof.com", "match.com", "eharmony.com",
            "zoosk.com", "badoo.com", "meetme.com",
        ]
        for d in datingDomains {
            if lower == d || lower.hasSuffix("." + d) { return (true, "dating") }
        }

        return (false, nil)
    }

    /// Extract the registerable domain from a full domain name.
    /// e.g., "www.video.tiktok.com" → "tiktok.com"
    /// e.g., "edge.cdn.instagram.com" → "instagram.com"
    public static func rootDomain(_ domain: String) -> String {
        let parts = domain.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return domain.lowercased() }

        // Handle two-part TLDs (co.uk, com.au, etc.)
        let twoPartTLDs: Set<String> = ["co.uk", "com.au", "co.jp", "com.br", "co.kr", "co.nz", "co.za"]
        if parts.count >= 3 {
            let lastTwo = "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
            if twoPartTLDs.contains(lastTwo) {
                return "\(parts[parts.count - 3]).\(lastTwo)"
            }
        }

        return "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
    }
}
