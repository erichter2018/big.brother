import SwiftUI
import UIKit

/// Renders an avatar from a base64 payload without ever blocking the main
/// thread on decode.
///
/// Flow:
///   1. On first appear, check `AvatarImageCache.cached(_:)` synchronously.
///      If hit → show the decoded image immediately (common case after the
///      first session).
///   2. On miss, show `fallback` (emoji or initials) and kick off
///      `AvatarImageCache.image(for:)` in a `.task` so the decode runs on
///      a background queue. When it completes, fade the photo in.
///
/// The heavy base64 + JPEG decode used to run synchronously inside
/// `avatarContent` on every SwiftUI body rebuild. With 6 kids × MB photos
/// that backed up the main thread for tens of seconds after cold launch
/// and left the dashboard showing blank avatars until the backlog cleared.
struct AsyncAvatarImage<Fallback: View>: View {
    let base64: String
    @ViewBuilder let fallback: () -> Fallback

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                fallback()
            }
        }
        .task(id: base64) {
            // Fast path: already decoded in this session (AppState pre-warms
            // this cache at init so cold launches hit here on first frame).
            if let hit = AvatarImageCache.cached(for: base64) {
                NSLog("[AvatarCache] HIT at mount (src=\(base64.count) bytes)")
                image = hit
                return
            }
            NSLog("[AvatarCache] MISS at mount — pre-warm didn't beat view, decoding now (src=\(base64.count) bytes)")
            let t0 = Date()
            let decoded = await AvatarImageCache.image(for: base64)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            NSLog("[AvatarCache] MISS resolved in \(ms)ms")
            await MainActor.run {
                image = decoded
            }
        }
    }
}
