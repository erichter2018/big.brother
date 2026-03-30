import Foundation

/// Categorizes domains and filters infrastructure noise.
/// Used by the VPN tunnel to flag inappropriate domains and skip CDN/analytics junk.
public enum DomainCategorizer {

    // MARK: - Noise Filtering

    // Root domains that are infrastructure noise — checked against rootDomain() output.
    private static let noiseDomains: Set<String> = [
        // Apple
        "apple.com", "icloud.com", "mzstatic.com", "apple-dns.net", "aaplimg.com",
        "apple-cloudkit.com", "cdn-apple.com", "icloud-content.com",
        "safebrowsing.apple", "app-analytics-services.com",
        // Google
        "googleapis.com", "gstatic.com", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "googletagservices.com",
        "gvt1.com", "gvt2.com", "1e100.net", "googleusercontent.com", "googlevideo.com",
        "ggpht.com", "withgoogle.com", "adtrafficquality.google",
        "2mdn.net", "googlesource.com", "google.com",
        // CDNs
        "akamaihd.net", "akamai.net", "akamaiedge.net", "akamaitechnologies.com",
        "akadns.net", "akam.net", "akahost.net", "edgekey.net", "edgesuite.net",
        "cloudfront.net", "cloudflare.com", "cloudflare.net", "cloudflare-dns.com",
        "cdninstagram.com", "fbcdn.net",
        "fastly.net", "fastlylb.net", "fastly-edge.com", "fastly.com",
        "edgecastcdn.net", "azureedge.net", "azurefd.net", "azure.com",
        "jsdelivr.net", "unpkg.com", "cdnjs.com",
        "llnwd.net", "lldns.net", "hwcdn.net", "stackpathdns.com",
        "bamgrid.com", "go.com",
        // TikTok CDN/infra
        "tiktokcdn.com", "tiktokcdn-us.com", "tiktokv.us", "tiktokv.com",
        "byteoversea.com", "bytecdn.cn", "ibytedtos.com", "bytedance.com",
        "sgsnssdk.com", "musical.ly", "ibyteimg.com", "pstatp.com",
        "ttoverseaus.net",
        // Twitter/X infra
        "twimg.com", "t.co",
        // Meta infra
        "fbsbx.com", "facebook.net", "fbpigeon.com", "accountkit.com",
        // Snap infra
        "sc-cdn.net", "sc-static.net", "snapkit.co", "snapkit.com", "sc-gw.com",
        // Ad tech / programmatic
        "doubleclick.net", "adsrvr.org", "adnxs.com", "criteo.com",
        "moatads.com", "scorecardresearch.com", "quantserve.com",
        "taboola.com", "outbrain.com", "unity3d.com",
        "rubiconproject.com", "casalemedia.com", "doubleverify.com",
        "iponweb.net", "impactradius-event.com", "impactradius.com",
        "pubmatic.com", "openx.net", "spotxchange.com", "smartadserver.com",
        "advertising.com", "mopub.com", "inmobi.com", "vungle.com",
        "chartboost.com", "ironsrc.com", "fyber.com",
        // Analytics / tracking
        "appsflyer.com", "appsflyersdk.com", "adjust.com", "branch.io",
        "amplitude.com", "mixpanel.com", "segment.io", "segment.com",
        "sentry.io", "crashlytics.com", "newrelic.com", "nr-data.net",
        "demdex.net", "omtrdc.net", "app-measurement.com",
        "kochava.com", "onesignal.com", "braze.com", "conviva.com",
        "imrworldwide.com", "nielsencollections.com", "nielsen.com",
        "chartbeat.net", "chartbeat.com", "statsig.com",
        "livesegmentservice.com", "dmed.technology",
        "vtwenty.com", "sng.link", "nc0.co",
        "hotjar.com", "mouseflow.com", "optimizely.com", "launchdarkly.com",
        // Cookie consent / privacy
        "onetrust.com", "onetrust.io", "cookielaw.org",
        // Adobe
        "adobedtm.com", "adobeprimetime.com", "adobepass.com", "adobe.com",
        "typekit.net",
        // Microsoft
        "msftconnecttest.com", "windowsupdate.com", "microsoft.com",
        "msedge.net", "t-msedge.net", "ax-msedge.net",
        "msn.com", "live.com", "bing.net", "appcenter.ms",
        // DNS/network
        "in-addr.arpa", "ip6.arpa", "resolver.arpa",
        "one.one", "dns.google",
        // Push/messaging infra
        "push.apple.com", "firebaseio.com", "firebaseapp.com",
        "firebasedatabase.app",
        // Certificate/OCSP
        "digicert.com", "letsencrypt.org", "pki.goog", "globalsign.com",
        "symantec.com", "verisign.com", "entrust.net",
        // YouTube infra
        "ytimg.com", "yt3.ggpht.com", "youtube-nocookie.com", "youtubei.googleapis.com",
        // CDN/security
        "incapdns.net", "incapsula.com", "imperva.com",
        // Apple additional
        "me.com",
        // Product analytics
        "aptrinsic.com", "gainsight.com", "pendo.io", "walkme.com",
        // Cloud infra
        "amazonaws.com", "awsstatic.com",
        // AMP
        "ampproject.org",
        // Local network
        "fios-router.home", "local", "localhost", "home",
        // Misc tracking / infra
        "fontawesome.com", "fn-pz.com", "dewrain.world", "iteleserve.com",
        "real.vg",
        // Adobe CDN / media
        "scene7.com",
        // Email tracking pixels / ESP
        "fdske.com", "awstrack.me", "esp1.co",
        // Microsoft crash/analytics
        "hockeyapp.net",
        // Marketing / push infra
        "braze-images.com",
        // Oracle / cloud infra
        "oraclecloud.com",
        // Ad/tracking misc
        "akaquill.net", "techsolutions.net",
        // Link shorteners (tracking)
        "bnc.lt",
        // Cloudflare analytics
        "cloudflareinsights.com",
        // Ad networks / mobile ads
        "moloco.com", "supersonicads.com", "tiktokpangle-b.us",
        "craftsmanplus.com", "oldspice.com",
        // Salesforce infra
        "salesforce-scrt.com", "sfdcfc.net",
        // Alibaba Cloud CDN
        "aliyuncsslbintl.com",
        // Apple ad attribution
        "app-ads-services.com",
        // Retail CDN
        "walmartimages.com", "shopifycloud.com",
        // Ad sync / retargeting
        "rezync.com",
        // DNS infra
        "ultradns-wal.co",
        // Content classification
        "assessor.com", "webcontentassessor.com",
        // Azure
        "trafficmanager.net",
        // Ad tech / programmatic (round 2)
        "inbake.com", "appier.net", "pricespider.com",
        "cybermission.tech", "extragum.com", "bidswitch.net",
        // Shopify infra (not shopify.com itself)
        "shopifysvc.com",
        // Generic / tracking
        "site.com",
        // Apple system services
        "apple.news",
        // Retail shortlinks
        "wal.co",
        // Fraud detection / bot protection
        "riskified.com", "px-cloud.net",
        // reCAPTCHA
        "recaptcha.net",
        // Cookie consent (round 2)
        "osano.com",
        // Video / TV ad tech
        "innovid.com", "ispot.tv",
        // Review / UGC infra
        "bazaarvoice.com",
        // Cross-device tracking
        "tapad.com",
        // Ad networks (round 3)
        "adsmoloco.com", "criteo.net", "tiktokpangle.us", "appiersig.com",
        // A/B testing
        "growthbook.io",
        // Shopify store infra
        "myshopify.com",
        // Brand ad landing pages
        "oreo.com",
        // Retail / sports image CDN
        "frgimages.com",
        // App API infra
        "capcutapi.us",
        // Email marketing / tracking (round 2)
        "mlbemail.com", "newyorktimesinfo.com", "flodesk.com",
        // Adobe data collection
        "adobedc.net",
        // ESPN SSL/CDN infra
        "espssl.com",
        // Link tracking
        "spgo.io",
        // College admissions CRM
        "technolutions.net",
        // CDN proxy
        "fastly-masque.net",
        // In-app purchase SDK
        "revenuecat.com",
        // Crash / performance monitoring
        "bugsnag.com", "dynatrace.com",
        // A/B testing / optimization
        "abtasty.com", "polldaddy.com", "visualwebsiteoptimizer.com",
        // E-commerce infra
        "channeladvisor.com", "stylitics.com", "curalate.com", "yotpo.com",
        "signifyd.com", "gorgias.chat", "klarna.net",
        // Video ad / player infra
        "tvpage.com", "connatix.com", "plyr.io", "jwplatform.com",
        "aniview.com", "trinitymedia.ai", "sundaysky.com",
        // Ad exchanges / SSPs / DSPs
        "narrativ.com", "kargo.com", "dotomi.com", "liadm.com",
        "33across.com", "lijit.com", "undertone.com", "turn.com",
        "teads.tv", "3lift.com", "media.net", "id5-sync.com",
        "eu-1-id5-sync.com", "sonobi.com", "contextweb.com",
        "exelator.com", "sharethrough.com", "1rx.io", "thisisdax.com",
        "mookie1.com", "bfmio.com", "deepintent.com", "richaudience.com",
        "loopme.me", "iqzone.com", "hadronid.net", "stackadapt.com",
        "videoamp.com", "emxdgt.com", "colossusssp.com",
        "simpli.fi", "eyeota.net", "bidr.io", "onetag-sys.com",
        "smilewanted.com", "pippio.com", "yieldmo.com",
        "storygize.net", "ipredictive.com", "gumgum.com",
        "blogherads.com", "krushmedia.com", "fastclick.net",
        "rfihub.com", "presage.io", "smaato.net", "rtbsystem.com",
        "sitescout.com", "iqm.com", "prmutv.co", "excelate.ai",
        "mediago.io", "360yield.com", "betweendigital.com",
        "celtra.com", "seedtag.com", "eskimi.com", "openwebmp.com",
        "servenobid.com", "optable.co", "agkn.com", "crwdcntrl.net",
        "ogury.io", "cadent.com", "cadent.app",
        // Ad verification / fraud
        "adsafeprotected.com", "confiant-integrations.net",
        "adlightning.com", "dv.tech", "ad-score.com",
        // Cross-device / identity
        "tapad.com", "intentiq.com", "liveintent.com",
        "thrtle.com", "zetaglobal.io",
        // Email / push marketing
        "boomtrain.com", "iterable.com", "klaviyo.com",
        "pardot.com",
        // Data / audience platforms
        "permutive.com", "permutive.app", "cxense.com",
        "ml314.com", "singular.net", "browsiprod.com",
        // Content analytics
        "parsely.com", "spot.im", "piano.io", "tinypass.com",
        // Audio ads
        "adswizz.com", "tritondigital.com",
        // Misc tracking / ad tech
        "kampyle.com", "yellowblue.io", "skimresources.com",
        "zineone.com", "zineone.live", "tru.am", "crcldu.com",
        "mygaru.com", "mgaru.dev", "b2c.com", "pubmnet.com",
        "px-client.net", "tynt.com", "a-mx.net", "a-mo.net",
        "a-mx.com", "amx1.net", "amxrtb.com", "pghub.io",
        "privacymanager.io", "trustarc.com", "truste.com", "cookiebot.com",
        "2o7.net", "omnitagjs.com", "tsbluebox.com",
        "vistarsagency.com", "bizticket.net", "thinkpivot.io",
        "ss2.us", "trackonomics.net", "addtoany.com", "measureadv.com",
        "ad-delivery.net", "adentifi.com", "targetimg1.com",
        "pmbmonetize.live", "imtwjwoasak.com", "aidemsrv.com",
        "html-load.com", "fwmrm.net", "zeronaught.com",
        "rkdms.com", "adotmob.com", "audienceexposure.com",
        "scalibur.io", "im-apps.net", "geistm.com",
        "cootlogix.com", "acuityplatform.com",
        "usbrowserspeed.com", "bttrack.com", "hs-banner.com",
        "activemetering.com", "rfpx1.com", "medallia.com",
        "plerdy.com", "beamimpact.com", "copper6.com",
        "adn.cloud", "mfadsrvr.com", "rqtrk.eu", "trx-hub.com",
        "clarium.io", "qvdt3feo.com", "postrelease.com",
        "ad.gt", "admaster.cc", "ads-twitter.com",
        "insightexpressai.com", "dxtech.ai", "pitaya-clientai.com",
        // Amazon infra
        "media-amazon.com", "ssl-images-amazon.com", "amazontrust.com",
        "a2z.com", "amazon.dev",
        // Yahoo infra
        "yimg.com", "yahoodns.net",
        // Pinterest CDN
        "pinimg.com",
        // Ulta internal
        "ultainc.com",
        // Misc CDN / infra
        "polyfill-fastly.io", "ionicframework.com", "lencr.org",
        "hcaptcha.com", "dewrain.life", "speedcurve.com",
        "cloudflarestream.com", "rapidssl.com", "elasticbeanstalk.com",
        "streamtheworld.com", "outbrainimg.com", "outbrain.org",
        "ak-is2.net", "ov1o.com", "ln-msedge.net",
        // TikTok additional
        "tiktokw.us", "tiktokglobalshopv.com", "ttdns2.com", "byteglb.com",
        // Payment / commerce infra
        "stripe.com", "stripe.network",
        // CRM / support infra
        "hubspot.com", "hubspotusercontent-na1.net", "niceincontact.com",
        // Publishing / paywall
        "pmc.com",
        // Misc
        "fullstory.com", "godaddy.com", "gravatar.com", "wp.com",
        "onelink.me", "joinaccountingplus.com", "lnk.to",
        // Cloud storage infra
        "backblazeb2.com",
        // TikTok/ByteDance additional
        "byteoversea.net", "tiktokv.eu",
        // WordPress VIP
        "go-vip.net",
        // Unknown tracking
        "trustedstack.com", "puzztake.com", "wp.pl",
    ]

    /// Returns true if the domain is infrastructure noise (CDN, analytics, ads, OS services).
    public static func isNoise(_ domain: String) -> Bool {
        let lower = domain.lowercased()

        // Check root domain against the noise set (O(1) lookup).
        // rootDomain() extracts "example.com" from "sub.cdn.example.com",
        // so this catches all subdomains of noise roots.
        let root = rootDomain(lower)
        if noiseDomains.contains(root) { return true }
        // Also check the full domain itself (handles edge cases like exact matches)
        if noiseDomains.contains(lower) { return true }

        // If it has a meaningful subdomain prefix on a non-noise root, keep it
        // (e.g., "mail.google.com" or "search.yahoo.com" should show)
        let parts = lower.split(separator: ".")
        if parts.count > 2 {
            let firstSub = String(parts[0])
            if meaningfulSubdomains.contains(firstSub) { return false }
        }

        // Special patterns
        if lower.hasSuffix(".local") || lower.hasSuffix(".localhost") { return true }
        if lower.contains("ocsp") || lower.contains("crl.") { return true }
        if lower.count < 4 { return true }

        // Email tracking subdomains (email.etsy.com, email.myfitnesspal.com, etc.)
        if lower.hasPrefix("email.") { return true }

        // Keyword-based noise detection
        let noiseKeywords = [
            "cdn", "static", "metric", "telemetry", "beacon", "pixel", "tracker",
            "analytics", "adserver", "adsystem", "adtech", "adservice",
            "doubleclick", "impression", "clicktrack", "retarget",
            "syndication", "openx", "pubmatic", "appnexus",
            "measurement", "collect", "reporting",
            "ultradns", "impervadns",
            // Broad ad-tech patterns
            "adsrvr", "adform", "adkernel", "admanmedia", "monetize",
            "bidswitch", "rtbsystem", "dsp", "ssp",
        ]
        for kw in noiseKeywords {
            if root.contains(kw) { return true }
        }

        // TLD-based noise (link shorteners, tracking domains)
        let noiseTLDs = [".link", ".ms", ".arpa"]
        for tld in noiseTLDs {
            if lower.hasSuffix(tld) && root.count < 12 { return true }
        }

        return false
    }

    // MARK: - Inappropriate Domain Detection

    // MARK: - Domain Categorization (static sets to avoid per-call allocation)

    private static let adultTLDs: [String] = [".xxx", ".porn", ".sex", ".adult", ".sexy", ".cam"]

    private static let adultDomains: Set<String> = [
        "pornhub.com", "xvideos.com", "xnxx.com", "xhamster.com",
        "redtube.com", "youporn.com", "tube8.com", "spankbang.com",
        "beeg.com", "brazzers.com", "realitykings.com", "bangbros.com",
        "onlyfans.com", "fansly.com", "chaturbate.com", "stripchat.com",
        "bongacams.com", "livejasmin.com", "cam4.com", "myfreecams.com",
        "porntrex.com", "eporner.com", "hqporner.com", "daftsex.com",
        "rule34.xxx", "e-hentai.org", "nhentai.net", "hanime.tv",
        "literotica.com", "sexstories.com",
    ]

    private static let gamblingDomains: Set<String> = [
        "bet365.com", "draftkings.com", "fanduel.com", "betmgm.com",
        "caesars.com", "pointsbet.com", "bovada.lv", "betonline.ag",
        "pokerstars.com", "888poker.com", "partypoker.com",
        "williamhill.com", "ladbrokes.com", "betfair.com",
        "stake.com", "roobet.com", "rollbit.com",
    ]

    private static let drugDomains: Set<String> = [
        "leafly.com", "weedmaps.com", "hightimes.com",
    ]

    private static let weaponDomains: Set<String> = [
        "bestgore.com", "theync.com", "kaotic.com",
    ]

    private static let proxyDomains: Set<String> = [
        "hidemyass.com", "nordvpn.com", "expressvpn.com", "surfshark.com",
        "protonvpn.com", "windscribe.com", "tunnelbear.com",
        "kproxy.com", "hide.me", "vpngate.net",
        "psiphon3.com", "ultrasurf.us", "hotspotshield.com",
    ]

    private static let datingDomains: Set<String> = [
        "tinder.com", "bumble.com", "hinge.co", "grindr.com",
        "okcupid.com", "pof.com", "match.com", "eharmony.com",
        "zoosk.com", "badoo.com", "meetme.com",
    ]

    /// Check if a domain is potentially inappropriate. Returns (flagged, category).
    public static func categorize(_ domain: String) -> (flagged: Bool, category: String?) {
        let lower = domain.lowercased()

        for tld in adultTLDs {
            if lower.hasSuffix(tld) { return (true, "adult") }
        }
        if adultDomains.contains(lower) { return (true, "adult") }

        if gamblingDomains.contains(lower) { return (true, "gambling") }
        let gamblingKeywords = ["casino", "slots", "betting", "sportsbook", "jackpot"]
        for kw in gamblingKeywords {
            if lower.contains(kw) { return (true, "gambling") }
        }

        if drugDomains.contains(lower) { return (true, "drugs") }
        if weaponDomains.contains(lower) { return (true, "violence") }
        if proxyDomains.contains(lower) { return (true, "proxy/vpn") }
        if datingDomains.contains(lower) { return (true, "dating") }

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

    // MARK: - App Detection

    /// Maps root domains to human-readable app names.
    /// Used by the VPN tunnel to detect new app activity.
    private static let appDomainCatalog: [String: String] = [
        // Social Media
        "tiktok.com": "TikTok",
        "snapchat.com": "Snapchat",
        "instagram.com": "Instagram",
        "facebook.com": "Facebook",
        "messenger.com": "Messenger",
        "twitter.com": "X (Twitter)",
        "x.com": "X (Twitter)",
        "reddit.com": "Reddit",
        "pinterest.com": "Pinterest",
        "tumblr.com": "Tumblr",
        "threads.net": "Threads",
        "bsky.app": "Bluesky",
        "mastodon.social": "Mastodon",
        "bereal.com": "BeReal",
        "locketcamera.com": "Locket",
        "realapp.com": "Real",
        // Messaging
        "discord.com": "Discord",
        "discordapp.com": "Discord",
        "telegram.org": "Telegram",
        "whatsapp.com": "WhatsApp",
        "whatsapp.net": "WhatsApp",
        "signal.org": "Signal",
        "kik.com": "Kik",
        "viber.com": "Viber",
        "line.me": "LINE",
        // Video & Streaming
        "youtube.com": "YouTube",
        "netflix.com": "Netflix",
        "hulu.com": "Hulu",
        "disneyplus.com": "Disney+",
        "max.com": "Max",
        "hbomax.com": "Max",
        "peacocktv.com": "Peacock",
        "paramountplus.com": "Paramount+",
        "crunchyroll.com": "Crunchyroll",
        "twitch.tv": "Twitch",
        "kick.com": "Kick",
        "rumble.com": "Rumble",
        // Music
        "spotify.com": "Spotify",
        "tidal.com": "Tidal",
        "soundcloud.com": "SoundCloud",
        "pandora.com": "Pandora",
        // Sports & Disney
        "espn.com": "ESPN",
        "espncdn.com": "ESPN",
        "disney.com": "Disney/ESPN",
        // Gaming
        "roblox.com": "Roblox",
        "minecraft.net": "Minecraft",
        "fortnite.com": "Fortnite",
        "epicgames.com": "Epic Games",
        "steampowered.com": "Steam",
        "store.steampowered.com": "Steam",
        "ea.com": "EA Games",
        "supercell.com": "Supercell (Clash/Brawl Stars)",
        "mihoyo.com": "HoYoverse (Genshin)",
        "hoyoverse.com": "HoYoverse (Genshin)",
        // Dating (concerning for minors)
        "tinder.com": "Tinder",
        "bumble.com": "Bumble",
        "hinge.co": "Hinge",
        "grindr.com": "Grindr",
        "badoo.com": "Badoo",
        // Shopping
        "amazon.com": "Amazon",
        "ebay.com": "eBay",
        "etsy.com": "Etsy",
        "shein.com": "SHEIN",
        "temu.com": "Temu",
        // Productivity / AI
        "openai.com": "ChatGPT",
        "anthropic.com": "Claude",
        "character.ai": "Character.AI",
        // Content
        "wattpad.com": "Wattpad",
        "archiveofourown.org": "Archive of Our Own",
        "webtoons.com": "Webtoon",
        // Anonymous / risky
        "omegle.com": "Omegle",
        "chatroulette.com": "Chatroulette",
        "whisper.sh": "Whisper",
        "yolo.live": "YOLO",
        // VPN/Proxy (bypass attempts)
        "nordvpn.com": "NordVPN",
        "expressvpn.com": "ExpressVPN",
        "surfshark.com": "Surfshark",
        "protonvpn.com": "ProtonVPN",
        "windscribe.com": "Windscribe",
        "tunnelbear.com": "TunnelBear",
        "1.1.1.1": "Cloudflare WARP",
    ]

    /// Returns the app name for a root domain, if it's a known app.
    public static func appName(for rootDomain: String) -> String? {
        appDomainCatalog[rootDomain.lowercased()]
    }

    // MARK: - Subdomain Intelligence

    /// Subdomains that reveal meaningful user behavior.
    /// If a query matches one of these prefixes, we preserve "prefix.rootdomain" instead of just "rootdomain".
    private static let meaningfulSubdomains: Set<String> = [
        // Content type
        "video", "videos", "music", "play", "watch", "stream", "live",
        "search", "images", "photos", "maps", "news", "sports",
        "mail", "chat", "messages", "dm",
        "shop", "store", "buy", "checkout", "cart",
        "games", "gaming",
        // Platform sections
        "kids", "family", "teen",
        "shorts",  // YouTube Shorts
        "reels",   // Instagram Reels
        "stories",
    ]

    /// Returns a display-friendly domain that preserves meaningful subdomains.
    /// "video.tiktok.com" → "video.tiktok.com" (watching videos)
    /// "www.tiktok.com" → "tiktok.com" (strips www)
    /// "edge-cdn3.tiktok.com" → "tiktok.com" (strips CDN noise)
    /// "search.yahoo.com" → "search.yahoo.com" (searching)
    /// "mail.google.com" → "mail.google.com" (email)
    public static func displayDomain(_ fullDomain: String) -> String {
        let lower = fullDomain.lowercased()
        let root = rootDomain(lower)
        let parts = lower.split(separator: ".")

        // If it's already a root domain (2 parts), return as-is
        guard parts.count > 2 else { return root }

        // Check if the first subdomain is meaningful
        let firstSub = String(parts[0])
        if meaningfulSubdomains.contains(firstSub) {
            return "\(firstSub).\(root)"
        }

        // For 3-part domains, check if the second part is meaningful
        // e.g., "us.video.example.com" → check "video"
        if parts.count > 3 {
            let secondSub = String(parts[1])
            if meaningfulSubdomains.contains(secondSub) {
                return "\(secondSub).\(root)"
            }
        }

        // Default: just the root domain (strips www, cdn, edge, etc.)
        return root
    }
}
