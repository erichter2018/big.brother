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
        "akamaihd.net", "akamai.net", "akamaiedge.net", "akamaized.net", "akamaitechnologies.com",
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
        // Ad tech / tracking (from DNS logs 2026-03)
        "bounceexchange.com", "bouncex.net", "postscript.io", "flashtalking.com",
        "indexww.com", "rebuyengine.com", "heatmapcore.com", "heatmap.com",
        "recart.com", "infolinks.com", "richpanel.com", "attn.tv",
        "minute-ly.com", "vaultdcr.com", "everesttech.net", "okendo.io",
        "kayzen.io", "strpst.com", "eizzih.com", "judge.me", "wknd.ai",
        "krxd.net", "customily.com", "intelligems.io", "pdscrb.com",
        "getfondue.com", "sendlane.com", "servedbyivo.com", "ipify.org",
        "placed.com", "prreqcroab.icu", "redfastlabs.com", "redfast.com",
        "viacomcbs.digital", "trustx.org", "snackly.co", "ketchjs.com",
        "unablehope.com", "northbeam.io", "minutemedia-prebid.com",
        "vdopia.com", "quantcount.com", "onlinestarten.net", "clipcentric.com",
        "rtb-oveeo.com", "chapturist.com", "ststandard.com", "strpssts-ana.com",
        "dashfi.dev", "wunderkind.co", "fpjs.io", "qprod2.net", "drrv.co",
        "roeye.com", "pdqprod.link", "albss.com", "uxtweak.com",
        "attainplatform.io", "ltmsphrcl.net", "jivox.com", "semasio.net",
        "bc-solutions.net", "getsitectrl.com", "mathtag.com", "dotter.me",
        "ghostmonitor.com", "consentmo.com", "attentivemobile.com",
        "getelevar.com", "researchnow.com", "summerhamster.com",
        "automizely.com", "thebrighttag.com", "rtactivate.com", "ortb.net",
        "zeotap.com", "hrzn-nxt.com", "stickyadstv.com", "tubemogul.com",
        "adition.com", "gcprivacy.id", "gcprivacy.net", "ninthdecimal.com",
        "e-planning.net", "extremereach.io", "tremorhub.com", "mxptint.net",
        "blueconic.net", "reson8.com", "ingage.tech", "tidaltv.com",
        "device9.com", "basis.net", "statsigapi.net",
        // Ad networks / mobile ads (from DNS logs)
        "applovin.com", "applvn.com", "inner-active.mobi", "maxesads.com",
        "afafb.com", "safedk.com", "adsappier.com", "dataseat.com",
        "dataseat.tv", "tpbid.com", "zefrdata.com", "bytegle.tech",
        "acobt.tech", "vaicore.site", "onegg.site", "mczbf.com",
        "claspws.tv", "byteigtm-us.com", "survata.com", "clrt.ai",
        "go-mpulse.net", "contentsquare.net",
        // E-commerce / marketing infra (from DNS logs)
        "shareasale.com", "affirm.com", "cbsi.com", "cbsivideo.com",
        "cbsinteractive.com", "rise-ai.com", "wisepops.com", "wisepops.net",
        "avada.io", "btloader.com", "btmessage.com",
        "freeshipping-essential-apps.uk", "mezereon.net",
        // Content/media infra
        "cachefly.net", "jquery.com", "run.app", "on.aws",
        "herokuapp.com", "vercel.app", "railway.app",
        "fastly-insights.com", "datadome.co",
        "browser-intake-datadoghq.com", "datadoghq-browser-agent.com",
        "browser-intake-us3-datadoghq.com", "browser-intake-us5-datadoghq.com",
        // Shopping infra / payment
        "braintreegateway.com", "braintree-api.com", "paypalobjects.com",
        "shopifynetwork.com", "vtex.com", "vtex.com.br", "vtexassets.com",
        "heap-api.com", "amplience.net", "bigcontent.io",
        "knotch.it", "knotch.com", "clinch.co",
        // Misc noise
        "acsbapp.com", "js7k.com", "lhmos.com", "sectigo.com",
        "impassableretainerexplained.com", "loo3laej.com",
        "sc-prod.net", "thinkingdata.cn", "ppassets.com",
        "1a-1791.com", "cnstrc.com",
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
        "tiktokcdn.com": "TikTok",
        "tiktokcdn-us.com": "TikTok",
        "tiktokv.us": "TikTok",
        "tiktokv.com": "TikTok",
        "snapchat.com": "Snapchat",
        "snap.com": "Snapchat",
        "sc-cdn.net": "Snapchat",
        "bitmoji.com": "Snapchat",
        "instagram.com": "Instagram",
        "cdninstagram.com": "Instagram",
        "facebook.com": "Facebook",
        "fbcdn.net": "Facebook",
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
        "discord.gg": "Discord",
        "discord.media": "Discord",
        "telegram.org": "Telegram",
        "whatsapp.com": "WhatsApp",
        "whatsapp.net": "WhatsApp",
        "wa.me": "WhatsApp",
        "signal.org": "Signal",
        "kik.com": "Kik",
        "viber.com": "Viber",
        "line.me": "LINE",
        // Video & Streaming
        "youtube.com": "YouTube",
        "googlevideo.com": "YouTube",
        "ytimg.com": "YouTube",
        "youtu.be": "YouTube",
        "netflix.com": "Netflix",
        "nflxvideo.net": "Netflix",
        "nflximg.net": "Netflix",
        "nflxso.net": "Netflix",
        "hulu.com": "Hulu",
        "disneyplus.com": "Disney+",
        "max.com": "Max",
        "hbomax.com": "Max",
        "peacocktv.com": "Peacock",
        "paramountplus.com": "Paramount+",
        "crunchyroll.com": "Crunchyroll",
        "twitch.tv": "Twitch",
        "jtvnw.net": "Twitch",
        "twitchcdn.net": "Twitch",
        "kick.com": "Kick",
        "rumble.com": "Rumble",
        // Music
        "spotify.com": "Spotify",
        "scdn.co": "Spotify",
        "spotifycdn.com": "Spotify",
        "tidal.com": "Tidal",
        "soundcloud.com": "SoundCloud",
        "pandora.com": "Pandora",
        // Sports & Disney
        "espn.com": "ESPN",
        "espncdn.com": "ESPN",
        "espn.net": "ESPN",
        "247sports.com": "247Sports",
        "disney.com": "Disney/ESPN",
        "disney-plus.net": "Disney+",
        // Gaming
        "roblox.com": "Roblox",
        "rbxcdn.com": "Roblox",
        "minecraft.net": "Minecraft",
        "fortnite.com": "Fortnite",
        "epicgames.com": "Epic Games",
        "steampowered.com": "Steam",
        "store.steampowered.com": "Steam",
        "ea.com": "EA Games",
        "supercell.com": "Supercell (Clash/Brawl Stars)",
        "mihoyo.com": "HoYoverse (Genshin)",
        "hoyoverse.com": "HoYoverse (Genshin)",
        "boomlings.com": "Geometry Dash",
        "ngfiles.com": "Newgrounds",
        "rovio.com": "Angry Birds",
        "devsisters.cloud": "Cookie Run",
        "devsisters.com": "Cookie Run",
        "devplay.com": "Cookie Run",
        "ovensmash.com": "Cookie Run",
        "sporcle.com": "Sporcle",
        "clean.gg": "Clean (Gaming)",
        "picsart.com": "Picsart",
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
        "walmart.com": "Walmart",
        "target.com": "Target",
        "ulta.com": "Ulta",
        "doordash.com": "DoorDash",
        "starbucks.com": "Starbucks",
        "shopify.com": "Shopify Store",
        // Productivity / AI
        "openai.com": "ChatGPT",
        "chatgpt.com": "ChatGPT",
        "oaiusercontent.com": "ChatGPT",
        "anthropic.com": "Claude",
        "character.ai": "Character.AI",
        "grok.com": "Grok",
        "sierra.chat": "Sierra AI",
        // Messaging (additional)
        "groupme.com": "GroupMe",
        "giphy.com": "Giphy",
        "tenor.com": "Tenor (GIFs)",
        // Education
        "powerschool.com": "PowerSchool",
        "schoology.com": "Schoology",
        "duolingo.com": "Duolingo",
        "quizlet.com": "Quizlet",
        "collegeboard.org": "College Board",
        // News / Media
        "nytimes.com": "NY Times",
        "nyt.com": "NY Times",
        "yahoo.com": "Yahoo",
        "redd.it": "Reddit",
        "redditmedia.com": "Reddit",
        "redditstatic.com": "Reddit",
        // Video / Streaming (additional)
        "plex.tv": "Plex",
        "plex.direct": "Plex",
        "bilibili.com": "Bilibili",
        "bilibili.tv": "Bilibili",
        "dramabox.com": "DramaBox",
        "dramaboxdb.com": "DramaBox",
        "fandom.com": "Fandom Wiki",
        "paramount.com": "Paramount+",
        "paramount.tech": "Paramount+",
        "fox.com": "Fox",
        "nocookie.net": "YouTube (embedded)",
        // Sports
        "mlb.com": "MLB",
        "mlbshop.com": "MLB",
        // Other apps
        "opera.com": "Opera Browser",
        "linkedin.com": "LinkedIn",
        "gmail.com": "Gmail",
        "ourpact.com": "OurPact",
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

    /// Returns all known root domains for a given app name (reverse lookup).
    /// Used to block web access when an app's time limit is exhausted.
    public static func domainsForApp(_ appName: String) -> Set<String> {
        var domains = Set<String>()
        for (domain, name) in appDomainCatalog where name == appName {
            domains.insert(domain)
        }
        return domains
    }

    /// Returns all root domains in the catalog (every known app domain).
    /// Used to compute enforcement DNS blocking: block all app web domains
    /// except those belonging to explicitly allowed apps.
    public static func allAppDomains() -> Set<String> {
        Set(appDomainCatalog.keys)
    }

    /// Returns all unique app names in the catalog.
    public static func allAppNames() -> Set<String> {
        Set(appDomainCatalog.values)
    }

    // MARK: - Web Gaming Domains

    /// Browser-based gaming sites that kids access via Safari.
    /// These have no native app equivalent — blocking at DNS level is the only option.
    /// Used when denyWebGamesWhenRestricted is enabled.
    public static let webGamingDomains: Set<String> = [
        // Popular browser game portals
        "coolmathgames.com",
        "coolmath-games.com",
        "poki.com",
        "crazygames.com",
        "kizi.com",
        "miniclip.com",
        "addictinggames.com",
        "kongregate.com",
        "armorgames.com",
        "newgrounds.com",
        "itch.io",
        "now.gg",
        "iogames.space",
        "gamepix.com",
        "silvergames.com",
        "primarygames.com",
        "friv.com",
        "y8.com",
        "gameflare.com",
        "gamedistribution.com",
        // .io games (hugely popular with kids)
        "slither.io",
        "agar.io",
        "diep.io",
        "krunker.io",
        "surviv.io",
        "shellshock.io",
        "zombsroyale.io",
        "buildroyale.io",
        "moomoo.io",
        "starve.io",
        "skribbl.io",
        "deeeep.io",
        "hole.io",
        "paper.io",
        "powerline.io",
        // Unblocked games (kids search these to bypass school filters)
        "unblockedgames.dev",
        "tyrone-unblocked-games.com",
        "unblockedgames66.com",
        "unblockedgames76.com",
        "unblockedgames77play.com",
        // Popular .io / browser FPS
        "1v1.lol",
        "ev.io",
        "bloxd.io",
        "retrobowl.me",
        "slope-game.com",
        "run3.io",
        "subway-surfers.me",
        // Board / casual gaming
        "boardgamearena.com",
        "chess.com",
        "lichess.org",
        "geoguessr.com",
        // Gambling / casino (underage risk)
        "draftkings.com",
        "fanduel.com",
        "betmgm.com",
        "pokerstars.com",
    ]

    // MARK: - DNS-over-HTTPS Bypass Prevention

    /// Known DoH (DNS-over-HTTPS) resolver domains.
    /// Kids can use these to bypass DNS-level enforcement entirely.
    /// Blocked during enforcement to prevent circumvention.
    public static let dohResolverDomains: Set<String> = [
        "dns.google",
        "dns.google.com",
        "dns.quad9.net",
        "doh.opendns.com",
        "doh.familyshield.opendns.com",
        "dns.nextdns.io",
        "doh.cleanbrowsing.org",
        "dns.adguard.com",
        "doh.mullvad.net",
        "dns.controld.com",
        // Cloudflare DoH endpoints
        "one.one.one.one",
        "cloudflare-dns.com",
        "family.cloudflare-dns.com",
    ]

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
