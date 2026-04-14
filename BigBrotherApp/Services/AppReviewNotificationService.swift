import Foundation
import UserNotifications
import BigBrotherCore

/// Posts local notifications when a child submits a new app review request.
/// Tracks notified review IDs in UserDefaults to avoid duplicates.
/// Tapping the notification navigates to the child's detail view.
enum AppReviewNotificationService {

    static let categoryID = "APP_REVIEW_REQUEST"

    /// Shared dedup store. See `NotificationDedupStore`. Content keys here
    /// encode both the `(childProfileID, normalizedName)` and the `fingerprint`
    /// axes so that a rename-then-re-fetch or a cross-device duplicate
    /// (same app, different ApplicationToken bytes) both collapse to "already
    /// notified". 24h window.
    private static let dedupStore = NotificationDedupStore(
        configuration: .init(
            notifiedIDsKey: "fr.bigbrother.notifiedAppReviews",
            contentKeysKey: "fr.bigbrother.appReviewContentKeys",
            maxNotifiedIDs: 200,
            maxContentKeys: 200
        )
    )

    private static let contentWindow: TimeInterval = 86_400

    /// Check for new pending reviews and post notifications for any unseen ones.
    static func checkAndNotify(
        reviews: [PendingAppReview],
        childName: String,
        childProfileID: ChildProfileID
    ) {
        guard !reviews.isEmpty else { return }

        let toPost: [PendingAppReview] = dedupStore.withLock { state in
            var items: [PendingAppReview] = []

            for review in reviews {
                let idString = review.id.uuidString
                guard !state.hasNotified(idString) else { continue }

                // Only notify for reviews from the last 30 minutes.
                guard review.createdAt.timeIntervalSinceNow > -1800 else {
                    state.markNotified(idString)
                    continue
                }

                // Dedup by (childProfileID, normalized appName) primarily —
                // stable across token rotation — and by fingerprint as a
                // fallback for legacy entries without a resolved name.
                let normalizedName = review.appName
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let nameKey = "appReview:name:\(childProfileID.rawValue):\(normalizedName)"
                let fpKey = "appReview:fp:\(review.appFingerprint)"
                if state.isRecentContentKey(nameKey, within: contentWindow) ||
                   state.isRecentContentKey(fpKey, within: contentWindow) {
                    state.markNotified(idString)
                    continue
                }

                state.recordContentKey(nameKey)
                state.recordContentKey(fpKey)
                state.markNotified(idString)
                items.append(review)
            }
            return items
        }

        for review in toPost {
            let content = UNMutableNotificationContent()
            content.title = "\(childName) wants an app"
            content.body = "Requesting access to \(review.appName)"
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.userInfo = [
                "childProfileID": childProfileID.rawValue,
                "reviewID": review.id.uuidString,
                "type": "appReview"
            ]

            let request = UNNotificationRequest(
                identifier: "app-review-\(review.id.uuidString)",
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Handle a tap on an app review notification.
    /// Returns the child profile ID to navigate to, plus the specific review ID
    /// so the detail view can auto-scroll to and highlight that card.
    static func handleTap(_ response: UNNotificationResponse) -> (childProfileID: ChildProfileID, reviewID: UUID?)? {
        let userInfo = response.notification.request.content.userInfo
        guard userInfo["type"] as? String == "appReview",
              let rawID = userInfo["childProfileID"] as? String else {
            return nil
        }
        let reviewID = (userInfo["reviewID"] as? String).flatMap(UUID.init(uuidString:))
        return (ChildProfileID(rawValue: rawID), reviewID)
    }
}
