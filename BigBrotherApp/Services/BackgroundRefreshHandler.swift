import Foundation
import UIKit
import CloudKit
import os
import BigBrotherCore

/// Handles background refresh and silent push notification wakeups.
///
/// Integration points:
/// - CloudKit CKQuerySubscription silent pushes wake the app
/// - UIApplication background fetch can trigger periodic sync
/// - BGTaskScheduler can schedule deferred work (future enhancement)
///
/// Flow when a silent push arrives:
/// 1. AppDelegate.didReceiveRemoteNotification is called
/// 2. BackgroundRefreshHandler.handleRemoteNotification runs
/// 3. SyncCoordinator performs a quick sync (commands + heartbeat)
/// 4. If command changes mode, enforcement is applied immediately
/// 5. Completion handler is called with the appropriate result
enum BackgroundRefreshHandler {

    /// Minimum interval between push-triggered syncs (seconds).
    /// Pushes arriving faster than this are coalesced.
    private static let pushDebounceInterval: TimeInterval = 10

    /// Timestamp of last push-triggered sync (child path only).
    private static let _lastPushSyncLock = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private static var lastPushSync: Date {
        get { _lastPushSyncLock.withLock { $0 } }
        set { _lastPushSyncLock.withLock { $0 = newValue } }
    }

    /// Handle a CloudKit silent push notification.
    ///
    /// Called from `UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
    /// Performs a quick sync cycle: fetch pending commands, process them,
    /// send heartbeat. The policy pipeline runs if a command changes mode.
    ///
    /// - Parameters:
    ///   - userInfo: The notification payload from CloudKit
    ///   - appState: The app's root state object
    /// - Returns: The fetch result to pass to the completion handler
    static func handleRemoteNotification(
        userInfo: [AnyHashable: Any],
        appState: AppState
    ) async -> UIBackgroundFetchResult {
        #if DEBUG
        print("[BigBrother] Received remote notification")
        #endif

        // Verify this is a CloudKit notification.
        guard let notification = CKNotificationFromUserInfo(userInfo) else {
            #if DEBUG
            print("[BigBrother] Not a CloudKit notification, ignoring")
            #endif
            return .noData
        }

        // Only process query notifications (from our CKQuerySubscription).
        guard notification is CKQueryNotification else {
            #if DEBUG
            print("[BigBrother] Not a query notification, ignoring")
            #endif
            return .noData
        }

        let isParent = await MainActor.run { appState.parentState != nil }
        if isParent {
            // Fast path — pending-app-review subscription. The parent cares most
            // about new kid requests showing up instantly. Short-circuit the full
            // dashboard refresh and only fetch the reviews for the affected child,
            // then upsert directly into AppState. UI updates immediately via the
            // @Observable store; no pull-to-refresh needed.
            if let queryNotif = notification as? CKQueryNotification,
               let subID = queryNotif.subscriptionID,
               subID.hasPrefix("app-reviews-") {
                return await handlePendingReviewPush(queryNotif, appState: appState)
            }

            #if DEBUG
            print("[BigBrother] CloudKit push received (parent) — refreshing dashboard...")
            #endif
            try? await Task.sleep(for: .seconds(0.5))
            do {
                try await appState.refreshDashboard()
                #if DEBUG
                print("[BigBrother] Parent dashboard refreshed after push")
                #endif
                return .newData
            } catch {
                #if DEBUG
                print("[BigBrother] Parent push refresh failed: \(error.localizedDescription)")
                #endif
                return .failed
            }
        } else {
            // Detect if this is an alert push (mode command) vs. silent push.
            // Alert pushes include an "aps" dict with an "alert" key.
            let isAlertPush: Bool = {
                guard let aps = userInfo["aps"] as? [String: Any] else { return false }
                return aps["alert"] != nil
            }()

            BBLog("[BigBrother] Push received (child, \(isAlertPush ? "alert" : "silent")) — processing commands NOW")

            // Suppress duplicate local notifications when the alert push already showed a banner.
            let processor = await MainActor.run { appState.commandProcessor as? CommandProcessorImpl }
            if isAlertPush { processor?.suppressModeNotifications = true }

            // Call processIncomingCommands directly. The previous "fast path"
            // (direct fetch by recordID + process()) bypassed the ProcessingGate
            // and the mode-command coalescing inside processIncomingCommands —
            // when the parent sent rapid mode changes (locked → unlocked →
            // restricted in a few seconds), each push handler raced ahead with
            // the SPECIFIC command in its push payload, with no dedup or
            // ordering guarantees, and intermediate states overwrote the
            // intended final mode. processIncomingCommands always picks the
            // LATEST mode command in CK and processes it under the gate, so
            // rapid sequences settle on the last command issued.
            do {
                try await appState.commandProcessor?.processIncomingCommands()
                processor?.suppressModeNotifications = false
                await MainActor.run { appState.refreshLocalState() }
                BBLog("[BigBrother] Push command processing complete")
                return .newData
            } catch {
                processor?.suppressModeNotifications = false
                BBLog("[BigBrother] Push command processing failed: \(error.localizedDescription)")
                return .failed
            }
        }
    }

    /// Handle a silent push fired by the pending-app-review CKQuerySubscription.
    /// Fetches that child's reviews (single CK query), upserts into AppState, and
    /// posts the parent notification. Much faster than a full dashboard refresh,
    /// and since AppState is observable the child-detail UI updates instantly.
    private static func handlePendingReviewPush(
        _ queryNotif: CKQueryNotification,
        appState: AppState
    ) async -> UIBackgroundFetchResult {
        guard let recordID = queryNotif.recordID,
              let cloudKit = await MainActor.run(body: { appState.cloudKit })
        else { return .noData }

        // Fast path: payload carries the record via desiredKeys (v2 subscription).
        // Upsert immediately — ZERO CK round-trips on the critical path. UI updates
        // the instant the push is dispatched.
        if let inline = pendingReviewFromNotification(queryNotif) {
            let childID = inline.childProfileID
            let configs = (try? await cloudKit.fetchTimeLimitConfigs(childProfileID: childID)) ?? []
            if shouldSuppressPendingReview(inline, configs: configs) {
                Task.detached { [cloudKit] in
                    try? await cloudKit.deletePendingAppReview(inline.id)
                }
                await MainActor.run {
                    appState.removePendingReviews(childID: childID) { $0.id == inline.id }
                    if (appState.pendingReviewsByChild[childID] ?? []).isEmpty {
                        appState.childrenWithPendingRequests.remove(childID)
                    }
                }
                BBLog("[BigBrother] Push review INLINE suppressed: child=\(childID.rawValue.prefix(8)) app=\(inline.appName)")
                return .newData
            }
            await MainActor.run {
                appState.upsertPendingReview(inline)
                appState.childrenWithPendingRequests.insert(childID)
            }
            let name = await MainActor.run {
                appState.childProfiles.first(where: { $0.id == childID })?.name ?? "Child"
            }
            AppReviewNotificationService.checkAndNotify(
                reviews: [inline],
                childName: name,
                childProfileID: childID
            )
            BBLog("[BigBrother] Push review INLINE upsert: child=\(childID.rawValue.prefix(8)) app=\(inline.appName)")
            // Reconcile the full list in the background so dedup/auto-approve
            // filters catch up without making the UI wait.
            Task.detached { [cloudKit] in
                if let full = try? await cloudKit.fetchPendingAppReviews(childProfileID: childID) {
                    let liveReviews = full.filter { !shouldSuppressPendingReview($0, configs: configs) }
                    await MainActor.run {
                        appState.setPendingReviews(liveReviews, for: childID)
                        if liveReviews.isEmpty {
                            appState.childrenWithPendingRequests.remove(childID)
                        } else {
                            appState.childrenWithPendingRequests.insert(childID)
                        }
                    }
                    let stale = full.filter { review in
                        !liveReviews.contains(where: { $0.id == review.id })
                    }
                    for staleReview in stale {
                        try? await cloudKit.deletePendingAppReview(staleReview.id)
                    }
                }
            }
            return .newData
        }

        // Fallback: payload didn't carry the fields (v1 subscription, old device,
        // or CK truncated). Do a single-record fetch and upsert.
        try? await Task.sleep(for: .milliseconds(500))
        guard let review = try? await cloudKit.fetchPendingAppReview(recordID: recordID) else {
            BBLog("[BigBrother] Push review fetch failed for \(recordID.recordName)")
            return .failed
        }
        let childID = review.childProfileID
        let configs = (try? await cloudKit.fetchTimeLimitConfigs(childProfileID: childID)) ?? []
        let allForChild = (try? await cloudKit.fetchPendingAppReviews(childProfileID: childID)) ?? [review]
        let liveReviews = allForChild.filter { !shouldSuppressPendingReview($0, configs: configs) }
        await MainActor.run {
            appState.setPendingReviews(liveReviews, for: childID)
            if liveReviews.isEmpty {
                appState.childrenWithPendingRequests.remove(childID)
            } else {
                appState.childrenWithPendingRequests.insert(childID)
            }
        }
        let name = await MainActor.run {
            appState.childProfiles.first(where: { $0.id == childID })?.name ?? "Child"
        }
        AppReviewNotificationService.checkAndNotify(
            reviews: liveReviews,
            childName: name,
            childProfileID: childID
        )
        let stale = allForChild.filter { review in
            !liveReviews.contains(where: { $0.id == review.id })
        }
        if !stale.isEmpty {
            Task.detached { [cloudKit] in
                for review in stale {
                    try? await cloudKit.deletePendingAppReview(review.id)
                }
            }
        }
        BBLog("[BigBrother] Push review FETCH upsert: child=\(childID.rawValue.prefix(8)) count=\(liveReviews.count)")
        return .newData
    }

    /// Reconstitute a PendingAppReview from CKQueryNotification.recordFields when
    /// the subscription included desiredKeys. Returns nil if fields missing.
    private static func pendingReviewFromNotification(
        _ queryNotif: CKQueryNotification
    ) -> PendingAppReview? {
        guard let fields = queryNotif.recordFields,
              let familyID = fields[CKFieldName.familyID] as? String,
              let childProfileID = fields[CKFieldName.profileID] as? String,
              let deviceID = fields[CKFieldName.deviceID] as? String,
              let fingerprint = fields[CKFieldName.appFingerprint] as? String,
              let appName = fields[CKFieldName.appName] as? String,
              let createdAt = fields[CKFieldName.createdAt] as? Date,
              let updatedAt = fields[CKFieldName.updatedAt] as? Date,
              let recordID = queryNotif.recordID
        else { return nil }

        let nameResolved: Bool = {
            if let n = fields[CKFieldName.nameResolved] as? Int64 { return n != 0 }
            if let n = fields[CKFieldName.nameResolved] as? Int { return n != 0 }
            if let n = fields[CKFieldName.nameResolved] as? Bool { return n }
            return false
        }()

        let uuidString = recordID.recordName.replacingOccurrences(
            of: "BBPendingAppReview_", with: ""
        )
        return PendingAppReview(
            id: UUID(uuidString: uuidString) ?? UUID(),
            familyID: FamilyID(rawValue: familyID),
            childProfileID: ChildProfileID(rawValue: childProfileID),
            deviceID: DeviceID(rawValue: deviceID),
            appFingerprint: fingerprint,
            appName: appName,
            bundleID: fields["appBundleID"] as? String,
            nameResolved: nameResolved,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func normalizeBundleID(_ bundleID: String?) -> String? {
        guard let bid = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bid.isEmpty else {
            return nil
        }
        return bid.lowercased()
    }

    private static func normalizeAppName(_ appName: String) -> String {
        appName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUsefulAppName(_ appName: String) -> Bool {
        let normalized = normalizeAppName(appName).lowercased()
        return !normalized.isEmpty &&
            normalized != "app" &&
            normalized != "an app" &&
            normalized != "unknown" &&
            normalized != "unknown app" &&
            !normalized.hasPrefix("app ") &&
            !normalized.hasPrefix("temporary") &&
            !normalized.hasPrefix("blocked app ") &&
            !normalized.contains("token(") &&
            !normalized.contains("data:") &&
            !normalized.contains("bytes)")
    }

    private static func shouldSuppressPendingReview(
        _ review: PendingAppReview,
        configs: [TimeLimitConfig]
    ) -> Bool {
        configs.contains { config in
            guard AppIdentityMatcher.same(review.identityCandidate, config.identityCandidate) else {
                return false
            }
            return config.isActive || config.updatedAt >= review.updatedAt
        }
    }

    /// Register for remote notifications.
    ///
    /// Must be called after app launch. The system requires explicit registration
    /// before silent pushes from CKQuerySubscription will be delivered.
    static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

// MARK: - CloudKit Notification Helper

/// Parse a CKNotification from the raw push userInfo dictionary.
/// Returns nil if the payload is not a CloudKit notification.
private func CKNotificationFromUserInfo(_ userInfo: [AnyHashable: Any]) -> CKNotification? {
    CKNotification(fromRemoteNotificationDictionary: userInfo)
}
