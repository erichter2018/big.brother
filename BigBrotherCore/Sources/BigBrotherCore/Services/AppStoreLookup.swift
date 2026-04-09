import Foundation

/// Looks up app category from the iTunes Search API.
/// Pure Foundation — no framework imports. Safe for use in BigBrotherCore.
public enum AppStoreLookup {

    /// Look up the App Store category for an app by name.
    /// Returns the `primaryGenreName` (e.g. "Games", "Social Networking") or nil.
    public static func lookupCategory(appName: String) async -> String? {
        guard !appName.isEmpty,
              let encoded = appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=software&limit=3&country=US")
        else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let genre = first["primaryGenreName"] as? String
            else { return nil }
            return genre
        } catch {
            return nil
        }
    }
}
