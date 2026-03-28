import Foundation
import StoreKit
import Observation

/// Manages StoreKit 2 subscriptions for Big Brother.
///
/// Handles product loading, purchase flow, transaction verification,
/// and subscription status tracking. Uses auto-renewable subscriptions
/// with a 14-day introductory free trial.
@Observable
@MainActor
final class SubscriptionManager {

    // MARK: - Product IDs

    static let monthlyID = "fr.bigbrother.app.monthly"
    static let annualID = "fr.bigbrother.app.annual"
    private static let productIDs: Set<String> = [monthlyID, annualID]

    // MARK: - State

    private(set) var products: [Product] = []
    private(set) var purchaseState: PurchaseState = .idle
    private(set) var subscriptionStatus: SubscriptionStatus = .unknown
    private(set) var expirationDate: Date?
    private(set) var isEligibleForTrial: Bool = true

    var isSubscribed: Bool {
        switch subscriptionStatus {
        case .subscribed, .trial:
            return true
        case .expired, .revoked, .unknown, .grace:
            return false
        }
    }

    /// For testing: override subscription status.
    var debugOverride: SubscriptionStatus? {
        didSet { if let override = debugOverride { subscriptionStatus = override } }
    }

    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case success
        case failed(String)
    }

    enum SubscriptionStatus: String, Codable {
        case unknown        // Haven't checked yet
        case trial          // In free trial period
        case subscribed     // Active paid subscription
        case grace          // In billing grace period
        case expired        // Subscription expired
        case revoked        // Refunded / revoked
    }

    // MARK: - Transaction Listener

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = listenForTransactions()
    }

    // MARK: - Load Products

    func loadProducts() async {
        do {
            let storeProducts = try await Product.products(for: Self.productIDs)
            // Sort: annual first (better value), then monthly.
            products = storeProducts.sorted { p1, p2 in
                if p1.id == Self.annualID && p2.id != Self.annualID { return true }
                if p2.id == Self.annualID && p1.id != Self.annualID { return false }
                return p1.id < p2.id
            }
        } catch {
            #if DEBUG
            print("[SubscriptionManager] Failed to load products: \(error)")
            #endif
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        purchaseState = .purchasing
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await updateSubscriptionStatus()
                purchaseState = .success
            case .pending:
                purchaseState = .failed("Purchase is pending approval")
            case .userCancelled:
                purchaseState = .idle
            @unknown default:
                purchaseState = .failed("Unknown purchase result")
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Restore Purchases

    var restoreError: String?

    func restorePurchases() async {
        restoreError = nil
        do {
            try await AppStore.sync()
            await updateSubscriptionStatus()
            if !isSubscribed {
                restoreError = "No active subscription found for this Apple ID."
            }
        } catch {
            restoreError = "Could not restore purchases. Check your internet connection and try again."
        }
    }

    // MARK: - Check Status

    func updateSubscriptionStatus() async {
        // Debug override takes precedence
        if debugOverride != nil { return }

        var foundActive = false
        var latestExpiration: Date?
        var latestStatus: SubscriptionStatus = .expired

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard transaction.productType == .autoRenewable else { continue }

            if transaction.revocationDate != nil {
                subscriptionStatus = .revoked
                return
            }

            foundActive = true

            // Keep the entitlement with the latest expiration date.
            if let txExp = transaction.expirationDate,
               latestExpiration == nil || txExp > (latestExpiration ?? .distantPast) {
                latestExpiration = txExp

                if #available(iOS 17.2, *) {
                    if let offer = transaction.offer, offer.type == .introductory {
                        latestStatus = .trial
                    } else {
                        latestStatus = .subscribed
                    }
                } else {
                    latestStatus = .subscribed
                }
            }
        }

        if foundActive {
            expirationDate = latestExpiration
            subscriptionStatus = latestStatus
        }

        if !foundActive {
            // Check for billing grace period
            for id in Self.productIDs {
                if let status = try? await Product.SubscriptionInfo.status(for: id) {
                    for s in status {
                        if case .verified(let renewalInfo) = s.renewalInfo,
                           renewalInfo.gracePeriodExpirationDate != nil,
                           renewalInfo.gracePeriodExpirationDate! > Date() {
                            subscriptionStatus = .grace
                            expirationDate = renewalInfo.gracePeriodExpirationDate
                            return
                        }
                    }
                }
            }
            subscriptionStatus = .expired
            expirationDate = nil
        }

        // Check trial eligibility
        await checkTrialEligibility()
    }

    // MARK: - Trial Eligibility

    private func checkTrialEligibility() async {
        guard let monthly = products.first(where: { $0.id == Self.monthlyID }) else { return }
        isEligibleForTrial = await monthly.subscription?.isEligibleForIntroOffer ?? false
    }

    // MARK: - Transaction Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) {
            for await result in Transaction.updates {
                guard let transaction = try? result.payloadValue else { continue }
                await transaction.finish()
                await updateSubscriptionStatus()
            }
        }
    }

    // MARK: - Helpers

    // MARK: - Trial & Grace Helpers

    /// Days remaining until subscription/trial expires. Nil if no expiration date.
    var daysUntilExpiry: Int? {
        guard let date = expirationDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: date).day
    }

    /// True when trial is ending within 3 days.
    var isTrialEndingSoon: Bool {
        guard subscriptionStatus == .trial, let days = daysUntilExpiry else { return false }
        return days <= 3
    }

    /// Human-readable subscription status for display.
    var statusDisplayText: String {
        switch subscriptionStatus {
        case .unknown: return "Checking..."
        case .trial:
            if let days = daysUntilExpiry {
                return days <= 0 ? "Trial ending today" : "Trial — \(days) day\(days == 1 ? "" : "s") left"
            }
            return "Free Trial"
        case .subscribed: return "Active"
        case .grace: return "Payment issue — retrying"
        case .expired: return "Expired"
        case .revoked: return "Refunded"
        }
    }

    /// Formatted price string for a product (e.g., "$6.99/month")
    static func priceLabel(for product: Product) -> String {
        let period: String
        if let sub = product.subscription {
            switch sub.subscriptionPeriod.unit {
            case .month: period = sub.subscriptionPeriod.value == 1 ? "/month" : "/\(sub.subscriptionPeriod.value) months"
            case .year: period = "/year"
            case .week: period = "/week"
            case .day: period = "/day"
            @unknown default: period = ""
            }
        } else {
            period = ""
        }
        return "\(product.displayPrice)\(period)"
    }

    /// Monthly equivalent price for annual plan (e.g., "$4.17/mo")
    static func monthlyEquivalent(for product: Product) -> String? {
        guard let sub = product.subscription,
              sub.subscriptionPeriod.unit == .year else { return nil }
        let monthly = product.price / 12
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = product.priceFormatStyle.locale
        return formatter.string(from: monthly as NSDecimalNumber)
    }
}
