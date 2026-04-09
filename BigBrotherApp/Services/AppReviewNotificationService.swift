import Foundation
import UserNotifications
import BigBrotherCore

/// Posts local notifications when a child submits a new app review request.
/// Tracks notified review IDs in UserDefaults to avoid duplicates.
/// Tapping the notification navigates to the child's detail view.
enum AppReviewNotificationService {

    static let categoryID = "APP_REVIEW_REQUEST"

    private static let notifiedKey = "fr.bigbrother.notifiedAppReviews"

    /// Check for new pending reviews and post notifications for any unseen ones.
    static func checkAndNotify(
        reviews: [PendingAppReview],
        childName: String,
        childProfileID: ChildProfileID
    ) {
        guard !reviews.isEmpty else { return }

        let defaults = UserDefaults.standard
        var notifiedIDs = Set(defaults.stringArray(forKey: notifiedKey) ?? [])

        // Prune old entries.
        if notifiedIDs.count > 200 {
            notifiedIDs = Set(Array(notifiedIDs).suffix(200))
        }

        for review in reviews {
            let idString = review.id.uuidString
            guard !notifiedIDs.contains(idString) else { continue }

            // Only notify for reviews from the last 30 minutes.
            guard review.createdAt.timeIntervalSinceNow > -1800 else {
                notifiedIDs.insert(idString)
                continue
            }

            // Fingerprint-level dedup — don't re-notify for the same app within 24 hours.
            // Prevents duplicate notifications if the child re-requests or zombie reviews.
            let fpKey = "appReviewNotified-\(review.appFingerprint)"
            let lastNotifiedForApp = defaults.double(forKey: fpKey)
            if Date().timeIntervalSince1970 - lastNotifiedForApp < 86400 {
                notifiedIDs.insert(idString)
                continue
            }

            let content = UNMutableNotificationContent()
            content.title = "\(childName) wants an app"
            content.body = "Requesting access to \(review.appName)"
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.userInfo = [
                "childProfileID": childProfileID.rawValue,
                "reviewID": idString,
                "type": "appReview"
            ]

            let request = UNNotificationRequest(
                identifier: "app-review-\(idString)",
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request)
            notifiedIDs.insert(idString)
            defaults.set(Date().timeIntervalSince1970, forKey: fpKey)
        }

        defaults.set(Array(notifiedIDs), forKey: notifiedKey)
    }

    /// Handle a tap on an app review notification. Returns the child profile ID to navigate to.
    static func handleTap(_ response: UNNotificationResponse) -> ChildProfileID? {
        let userInfo = response.notification.request.content.userInfo
        guard userInfo["type"] as? String == "appReview",
              let rawID = userInfo["childProfileID"] as? String else {
            return nil
        }
        return ChildProfileID(rawValue: rawID)
    }
}
