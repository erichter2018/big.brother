import Foundation
import CoreLocation
import BigBrotherCore

/// Queries OpenStreetMap Overpass API for posted speed limits at a given coordinate.
/// Results are cached by geohash cell to avoid redundant queries for the same road.
actor SpeedLimitService {
    /// Shared instance — speed limits are location-based, not child-specific.
    /// All children share the same cache since they take similar routes.
    static let shared = SpeedLimitService()

    /// Cached speed limit result.
    struct CachedLimit: Codable, Sendable {
        let speedMPH: Int?      // nil = no data found
        let roadName: String?
        let fetchedAt: Date
    }

    private var cache: [String: CachedLimit] = [:]
    private static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    private static let diskCacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("speed-limit-cache.json")
    }()

    /// Cache expiry (30 days — speed limits rarely change).
    private static let cacheExpiry: TimeInterval = 30 * 86400

    /// Minimum distance between queries (meters). Avoids hammering API on the same stretch.
    private var lastQueryLocation: CLLocation?
    private static let minQueryDistance: CLLocationDistance = 200

    /// Geohash precision: 7 chars ≈ 150m × 150m cells. Good enough for road-level caching.
    private static let geohashPrecision = 7

    private var needsSave = false

    init() {
        // Flush cache when build number changes (geometry-aware queries produce different results)
        let buildKey = "speedLimitCacheBuild"
        let defaults = UserDefaults.standard
        let lastBuild = defaults.integer(forKey: buildKey)
        if lastBuild != AppConstants.appBuildNumber {
            try? FileManager.default.removeItem(at: Self.diskCacheURL)
            defaults.set(AppConstants.appBuildNumber, forKey: buildKey)
        }

        // Load disk cache
        if let data = try? Data(contentsOf: Self.diskCacheURL),
           let loaded = try? JSONDecoder().decode([String: CachedLimit].self, from: data) {
            let now = Date()
            // Filter out expired entries
            self.cache = loaded.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.cacheExpiry }
        }
    }

    // MARK: - Public API

    /// Get the posted speed limit (in MPH) for the nearest road at the given coordinate.
    /// Returns nil if no speed limit data is available or query fails.
    func speedLimit(at coordinate: CLLocationCoordinate2D) async -> Int? {
        let hash = geohash(latitude: coordinate.latitude, longitude: coordinate.longitude,
                           precision: Self.geohashPrecision)

        // Check cache
        if let cached = cache[hash], Date().timeIntervalSince(cached.fetchedAt) < Self.cacheExpiry {
            return cached.speedMPH
        }

        // Skip if too close to last query
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let last = lastQueryLocation, loc.distance(from: last) < Self.minQueryDistance,
           let nearbyHash = nearestCachedHash(for: coordinate) {
            return cache[nearbyHash]?.speedMPH
        }

        // Query Overpass API
        lastQueryLocation = loc
        do {
            let result = try await queryOverpass(latitude: coordinate.latitude,
                                                  longitude: coordinate.longitude)
            cache[hash] = result
            saveToDiskThrottled()
            return result.speedMPH
        } catch {
            // Cache the miss for 5 minutes to avoid hammering, but allow retry after
            cache[hash] = CachedLimit(speedMPH: nil, roadName: nil,
                                       fetchedAt: Date().addingTimeInterval(-Self.cacheExpiry + 300))
            return nil
        }
    }

    /// Save to disk, but not on every single query — batch saves.
    private func saveToDiskThrottled() {
        needsSave = true
        // Save every 10 new entries
        if cache.count % 10 == 0 {
            persistToDisk()
        }
    }

    /// Force save (call when app backgrounds or view disappears).
    func persistToDisk() {
        guard needsSave else { return }
        needsSave = false
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: Self.diskCacheURL, options: .atomic)
        }
    }

    /// Cache-only lookup — no API call. Searches exact geohash, then broader neighbors.
    /// Use this during scrubbing to avoid firing API requests on every slider change.
    func cachedSpeedLimit(at coordinate: CLLocationCoordinate2D) -> Int? {
        let hash = geohash(latitude: coordinate.latitude, longitude: coordinate.longitude,
                           precision: Self.geohashPrecision)
        // Exact match
        if let cached = cache[hash], cached.speedMPH != nil {
            return cached.speedMPH
        }
        // Search broader area (precision-1 = ~1km cells)
        let broader = String(hash.prefix(Self.geohashPrecision - 1))
        // Find the nearest cached entry with actual data (not a nil miss)
        for (key, value) in cache where key.hasPrefix(broader) {
            if let speed = value.speedMPH {
                return speed
            }
        }
        return nil
    }

    /// Get cached limit details (for diagnostics).
    func cachedLimitDetails(at coordinate: CLLocationCoordinate2D) -> (speedMPH: Int?, roadName: String?)? {
        let hash = geohash(latitude: coordinate.latitude, longitude: coordinate.longitude,
                           precision: Self.geohashPrecision)
        guard let cached = cache[hash] else { return nil }
        return (cached.speedMPH, cached.roadName)
    }

    // MARK: - Overpass Query

    private func queryOverpass(latitude: Double, longitude: Double) async throws -> CachedLimit {
        // Request geometry so we can pick the closest road (important at interchanges/overpasses)
        let query = """
        [out:json][timeout:5];
        way[maxspeed][highway](around:100,\(latitude),\(longitude));
        out body geom;
        """

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            .data(using: .utf8)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return CachedLimit(speedMPH: nil, roadName: nil, fetchedAt: Date())
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else {
            return CachedLimit(speedMPH: nil, roadName: nil, fetchedAt: Date())
        }

        // Pick the closest road by minimum distance from query point to any node in the way.
        let queryPoint = (lat: latitude, lon: longitude)
        var bestSpeed: Int?
        var bestRoad: String?
        var bestDistance: Double = .greatestFiniteMagnitude

        for element in elements {
            guard let tags = element["tags"] as? [String: String],
                  let maxspeed = tags["maxspeed"] else { continue }

            if let mph = parseSpeedMPH(maxspeed) {
                let roadName = tags["name"] ?? tags["ref"]

                // Compute minimum distance from query point to this way's geometry
                var minDist = Double.greatestFiniteMagnitude
                if let geometry = element["geometry"] as? [[String: Double]] {
                    for node in geometry {
                        if let nLat = node["lat"], let nLon = node["lon"] {
                            let dLat = nLat - queryPoint.lat
                            let dLon = (nLon - queryPoint.lon) * cos(queryPoint.lat * .pi / 180)
                            let dist = sqrt(dLat * dLat + dLon * dLon)
                            minDist = min(minDist, dist)
                        }
                    }
                }

                if minDist < bestDistance {
                    bestDistance = minDist
                    bestSpeed = mph
                    bestRoad = roadName
                }
            }
        }

        return CachedLimit(speedMPH: bestSpeed, roadName: bestRoad, fetchedAt: Date())
    }

    // MARK: - Speed Parsing

    /// Parse OSM maxspeed tag into MPH.
    /// Handles: "55 mph", "90", "50 km/h", "none", etc.
    private func parseSpeedMPH(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // Special values
        if trimmed == "none" || trimmed == "signals" || trimmed == "variable" { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 1)
        guard let first = parts.first, let value = Int(first) else { return nil }

        if parts.count > 1 {
            let unit = parts[1].lowercased()
            if unit == "mph" {
                return value
            } else if unit == "km/h" || unit == "kmh" || unit == "kph" {
                return Int(Double(value) * 0.621371)
            } else if unit == "knots" {
                return Int(Double(value) * 1.15078)
            }
        }

        // No unit = km/h by default in OSM... but in the US, most are tagged "mph"
        // Heuristic: if value > 90, it's probably km/h (no US road has >90 mph limit)
        if value > 90 {
            return Int(Double(value) * 0.621371)
        }
        // In the US, bare numbers are often mph (tagging inconsistency)
        // Since this is a US family app, assume mph for reasonable values
        return value
    }

    // MARK: - Geohash

    private func nearestCachedHash(for coordinate: CLLocationCoordinate2D) -> String? {
        let hash = geohash(latitude: coordinate.latitude, longitude: coordinate.longitude,
                           precision: Self.geohashPrecision)
        if cache[hash] != nil { return hash }
        // Check truncated hash (broader area)
        let broader = String(hash.prefix(Self.geohashPrecision - 1))
        return cache.keys.first { $0.hasPrefix(broader) }
    }

    /// Simple geohash implementation.
    private func geohash(latitude: Double, longitude: Double, precision: Int) -> String {
        let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var isEven = true
        var bit = 0
        var ch = 0
        var hash = ""

        while hash.count < precision {
            if isEven {
                let mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid {
                    ch |= (1 << (4 - bit))
                    lonRange.0 = mid
                } else {
                    lonRange.1 = mid
                }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid {
                    ch |= (1 << (4 - bit))
                    latRange.0 = mid
                } else {
                    latRange.1 = mid
                }
            }
            isEven.toggle()
            bit += 1
            if bit == 5 {
                hash.append(base32[ch])
                ch = 0
                bit = 0
            }
        }
        return hash
    }
}
