import Foundation

/// A curated category of web domains for content filtering.
public struct WebFilterCategory: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let icon: String // SF Symbol name
    public let domains: [String]

    public init(id: String, name: String, icon: String, domains: [String]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.domains = domains
    }
}

/// Web filter configuration stored per child.
public struct WebFilterConfig: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case off              // No web filtering
        case blockAll         // Block all web (no allowed domains)
        case allowCategories  // Only allow selected category domains
    }
    public var mode: Mode
    public var selectedCategoryIDs: Set<String>

    public init(mode: Mode = .off, selectedCategoryIDs: Set<String> = []) {
        self.mode = mode
        self.selectedCategoryIDs = selectedCategoryIDs
    }

    /// Compute the effective allowed domain list based on selected categories.
    public func resolvedDomains(from catalog: [WebFilterCategory]) -> [String] {
        guard mode == .allowCategories else { return [] }
        let selected = catalog.filter { selectedCategoryIDs.contains($0.id) }
        return selected.flatMap(\.domains).sorted()
    }
}

/// Curated domain lists shipped with the app.
public enum WebFilterCatalog {

    /// Categories for "allow these" mode — only these domains accessible when web is blocked.
    public static let allowCategories: [WebFilterCategory] = [
        WebFilterCategory(id: "education", name: "Education", icon: "book.fill", domains: [
            "khanacademy.org", "coursera.org", "edx.org", "duolingo.com",
            "quizlet.com", "brainly.com", "chegg.com", "mathway.com",
            "desmos.com", "wolframalpha.com", "scratch.mit.edu",
            "code.org", "codecademy.com", "brilliant.org",
        ]),
        WebFilterCategory(id: "reference", name: "Reference", icon: "globe", domains: [
            "wikipedia.org", "britannica.com", "dictionary.com",
            "thesaurus.com", "merriam-webster.com", "worldbook.com",
            "howstuffworks.com", "nationalgeographic.com",
        ]),
        WebFilterCategory(id: "news", name: "News", icon: "newspaper.fill", domains: [
            "apnews.com", "reuters.com", "bbc.com", "npr.org",
            "pbs.org", "cnn.com", "nytimes.com", "washingtonpost.com",
            "usatoday.com", "abcnews.go.com", "nbcnews.com",
        ]),
        WebFilterCategory(id: "health", name: "Health", icon: "heart.fill", domains: [
            "cdc.gov", "nih.gov", "mayoclinic.org", "webmd.com",
            "healthline.com", "medlineplus.gov", "who.int",
            "kidshealth.org", "childmind.org",
        ]),
        WebFilterCategory(id: "creativity", name: "Creativity", icon: "paintbrush.fill", domains: [
            "canva.com", "figma.com", "tinkercad.com",
            "soundtrap.com", "bandlab.com", "musescore.org",
            "pixlr.com", "coolmathgames.com",
        ]),
        WebFilterCategory(id: "school", name: "School Tools", icon: "graduationcap.fill", domains: [
            "classroom.google.com", "docs.google.com", "drive.google.com",
            "slides.google.com", "sheets.google.com", "forms.google.com",
            "outlook.office.com", "teams.microsoft.com", "onedrive.live.com",
            "canvas.instructure.com", "schoology.com", "clever.com",
            "seesaw.me", "classdojo.com", "zoom.us",
        ]),
    ]

    /// Categories for "block these" mode (informational only — cannot enforce per-category blocking via ManagedSettings).
    public static let blockCategories: [WebFilterCategory] = [
        WebFilterCategory(id: "adult", name: "Adult Content", icon: "eye.slash.fill", domains: []),
        WebFilterCategory(id: "gambling", name: "Gambling", icon: "dice.fill", domains: []),
        WebFilterCategory(id: "social", name: "Social Media", icon: "person.2.fill", domains: [
            "facebook.com", "instagram.com", "twitter.com", "x.com",
            "tiktok.com", "snapchat.com", "reddit.com", "tumblr.com",
            "pinterest.com", "threads.net",
        ]),
        WebFilterCategory(id: "gaming", name: "Gaming Sites", icon: "gamecontroller.fill", domains: [
            "store.steampowered.com", "epicgames.com", "roblox.com",
            "twitch.tv", "discord.com", "itch.io",
        ]),
    ]
}
