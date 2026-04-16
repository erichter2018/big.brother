import Foundation
import UIKit
import ImageIO

/// Async in-memory cache for decoded avatar `UIImage`s, keyed by the raw
/// base64 payload stored on the `ChildProfile` record.
///
/// Why this exists: avatar photos are kept as base64 strings on CloudKit so
/// they ride along with the profile record in one query. Rendering uses
/// `Data(base64Encoded:)` + `UIImage(data:)`, both main-thread work. SwiftUI
/// rebuilds every card body on each published change (countdown tick, every
/// heartbeat refresh, observation churn), and with 6 kids × MB-sized JPEGs
/// that redecode chewed the main thread for tens of seconds after a cold
/// launch — the UI showed blank avatars until the backlog cleared.
///
/// All decoding happens off the main thread. Callers read synchronously via
/// `cached(for:)` for an instant cache hit, or await `image(for:)` to kick
/// off a background decode if missing. The card view shows a placeholder
/// until `image(for:)` completes, so the main thread is never blocked.
///
/// Cache keys combine length + a 64-char prefix so equal-content photos
/// hit regardless of how many copies live in memory, and edits naturally
/// miss the cache and trigger a fresh decode.
enum AvatarImageCache {

    private static let cache = NSCache<NSString, UIImage>()

    /// Serial queue isolating in-flight task bookkeeping. The decode itself
    /// runs on a detached task, but the "is anyone already decoding this
    /// key" check must be atomic to prevent duplicate decodes when multiple
    /// cards for the same avatar mount in the same frame.
    private static let lock = NSLock()
    private static var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Synchronous cache lookup. Returns nil on miss — caller should await
    /// `image(for:)` to populate the cache.
    static func cached(for base64: String) -> UIImage? {
        guard !base64.isEmpty else { return nil }
        let key = cacheKey(for: base64)
        return cache.object(forKey: key as NSString)
    }

    /// Synchronous cache lookup by arbitrary key (e.g. "firebase-kid:\(id)").
    /// Used for pre-decoded disk-cached avatars that don't have their base64
    /// payload available — we register the decoded `UIImage` under a stable
    /// key tied to the entity (the firestore kid ID, say) so the dashboard
    /// can hit the cache on first frame without holding the raw bytes.
    static func cachedByKey(_ key: String) -> UIImage? {
        guard !key.isEmpty else { return nil }
        return cache.object(forKey: key as NSString)
    }

    /// Register an already-decoded image under a base64 payload. Used when
    /// the decode happened somewhere else (e.g. during PNG persist) so the
    /// `cached(for:)` path still hits for the current session.
    static func preload(_ image: UIImage, for base64: String) {
        guard !base64.isEmpty else { return }
        cache.setObject(image, forKey: cacheKey(for: base64) as NSString)
    }

    /// Register an already-decoded image under an arbitrary key.
    static func preload(_ image: UIImage, forKey key: String) {
        guard !key.isEmpty else { return }
        cache.setObject(image, forKey: key as NSString)
    }

    /// Returns the decoded image, running the decode off the main thread if
    /// needed. Coalesces concurrent requests for the same payload so we only
    /// decode once per unique avatar.
    static func image(for base64: String) async -> UIImage? {
        guard !base64.isEmpty else { return nil }
        let key = cacheKey(for: base64)
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }

        // Coalesce: if another caller already kicked off a decode for this
        // key, await their task instead of doing redundant work.
        let task: Task<UIImage?, Never> = {
            lock.lock()
            defer { lock.unlock() }
            if let existing = inFlight[key] {
                return existing
            }
            let newTask = Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = Data(base64Encoded: base64) else { return nil }
                // Downsample via ImageIO instead of decoding the full JPEG.
                // Some avatars in the wild are full-camera-resolution (the
                // 200×200 resize path in AvatarPickerView was added later —
                // older uploads are MBs each). Decoding 6 of those on the
                // main thread was the root cause of the 15-second "avatars
                // slow" window: full-res decode is expensive, even off-main.
                // ImageIO's thumbnail path reads only the pixel data needed
                // for the target size, so multi-MB source photos cost the
                // same as a correctly-sized 200×200 one.
                let decoded = downsampledImage(from: data, maxPixelSize: 288) // 144pt @ 2x retina
                    ?? UIImage(data: data)?.eagerlyDecoded()
                    ?? UIImage(data: data)
                if let decoded {
                    cache.setObject(decoded, forKey: key as NSString)
                }
                return decoded
            }
            inFlight[key] = newTask
            Task {
                _ = await newTask.value
                // Async context can't hold NSLock across suspension (Swift 6
                // diagnostic). Confine the mutation to a sync closure that
                // locks + unlocks within its own scope.
                Self.withLock { inFlight[key] = nil }
            }
            return newTask
        }()

        return await task.value
    }

    /// Synchronous scoped locking — kept out of async contexts so Swift 6's
    /// concurrency checker is happy. Callers from sync contexts can still
    /// use `lock.lock()/defer unlock` directly.
    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func cacheKey(for base64: String) -> String {
        // Combine length + short prefix for a cheap, unique-enough key.
        // NSCache keys must be NSString, and hashing the full multi-MB
        // string on every lookup would negate the point of the cache.
        let prefix = String(base64.prefix(64))
        return "\(base64.count):\(prefix)"
    }
}

/// Decode a JPEG/PNG to a thumbnail of at most `maxPixelSize` px on the long
/// edge without fully decompressing the source. Uses CGImageSource's thumbnail
/// API, which reads directly to the target size — the fast path for handling
/// oversized photos that would otherwise spend seconds decoding at full res.
///
/// Returns nil if the data isn't a recognizable image format; callers should
/// fall back to `UIImage(data:)` so we still handle exotic sources.
private func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
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

private extension UIImage {
    /// Force the underlying image decoder to run now (on the calling thread)
    /// instead of lazily on the main thread at first draw. Without this, the
    /// expensive JPEG/PNG decode still lands on main when SwiftUI composites.
    func eagerlyDecoded() -> UIImage? {
        guard let cg = cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let decoded = context.makeImage() else { return nil }
        return UIImage(cgImage: decoded, scale: scale, orientation: imageOrientation)
    }
}
