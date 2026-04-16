import Foundation
import UIKit
import ImageIO

/// On-disk cache for pre-decoded Firebase avatars.
///
/// Why pre-decoded PNGs instead of base64 blobs: the source payloads from
/// Firebase are multi-MB base64-encoded JPEGs, and decoding them on cold
/// launch — even off the main thread — added enough latency that avatars
/// appeared ~15s after the dashboard rendered. We decode ONCE when the
/// Firebase snapshot arrives, downsample to the dashboard's display size
/// (144×144 @2x retina = 288px), and save as PNG. Next cold launch loads
/// that small PNG instantly and hands it to `AvatarImageCache` — no
/// base64 work, no JPEG decompression, no ImageIO thumbnailing.
///
/// Layout: `Caches/firebase-avatars/<firestoreKidID>.png`.
/// Caches is OS-managed; reinstalls clear it and Firebase re-delivers.
enum FirebaseAvatarDiskCache {

    private static var cacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("firebase-avatars", isDirectory: true)
    }

    /// Target pixel size for stored thumbnails. 288 = 144pt @ 2x, matching
    /// the avatar circle on the parent dashboard cards. Oversizing wastes
    /// disk + decode time; undersizing looks blurry on retina.
    private static let targetPixelSize: CGFloat = 288

    /// Decode the base64 payload, downsample, save as PNG. Returns the
    /// decoded `UIImage` so the caller can also populate the in-memory cache
    /// for the current session (no need to re-read from disk).
    static func persist(base64: String, for kidID: String) -> UIImage? {
        guard let data = Data(base64Encoded: base64),
              let downsampled = Self.downsample(data: data, maxPixelSize: targetPixelSize),
              let png = downsampled.pngData() else {
            return nil
        }
        let dir = cacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(kidID).png")
        try? png.write(to: url, options: .atomic)
        return downsampled
    }

    /// Delete cached avatars for kid IDs no longer present in `currentIDs`
    /// so the cache doesn't grow forever as kids come and go.
    static func pruneExcept(currentIDs: Set<String>) {
        let dir = cacheDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let keep = Set(currentIDs.map { "\($0).png" })
        for file in files where !keep.contains(file) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }

    /// Load all cached PNGs as in-memory `UIImage`s, keyed by firestore kid
    /// ID. Called from `AppState.loadCachedDashboard` to pre-populate the
    /// image cache before the dashboard view mounts.
    static func loadAllDecoded() -> [String: UIImage] {
        let dir = cacheDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return [:]
        }
        var result: [String: UIImage] = [:]
        for file in files where file.hasSuffix(".png") {
            let id = String(file.dropLast(".png".count))
            let url = dir.appendingPathComponent(file)
            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                result[id] = image
            }
        }
        return result
    }

    // MARK: - Downsampling

    /// Downsample image data to a thumbnail of at most `maxPixelSize` px on
    /// the long edge using CGImageSource. Only reads the pixel data needed
    /// for the target size, so works even on multi-MB full-camera JPEGs.
    private static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
