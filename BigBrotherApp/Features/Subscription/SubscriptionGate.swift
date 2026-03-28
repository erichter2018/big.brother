import SwiftUI

/// Gates parent access behind an active subscription.
/// Shows the paywall if the subscription is expired or unknown.
/// During grace period, allows read-only access with a banner.
/// Child devices are never gated — enforcement works regardless of subscription.
struct SubscriptionGate<Content: View>: View {
    let subscriptionManager: SubscriptionManager
    let debugMode: Bool
    @ViewBuilder let content: () -> Content

    @State private var hasChecked = false
    @State private var showPaywall = false

    var body: some View {
        Group {
            if debugMode || subscriptionManager.isSubscribed || !hasChecked {
                content()
                    .overlay(alignment: .top) {
                        if subscriptionManager.isTrialEndingSoon {
                            trialBanner
                        }
                    }
            } else if subscriptionManager.subscriptionStatus == .grace {
                // Grace period: show content with warning banner
                content()
                    .overlay(alignment: .top) {
                        graceBanner
                    }
            } else {
                PaywallView(subscriptionManager: subscriptionManager) {
                    showPaywall = false
                }
            }
        }
        .task {
            await subscriptionManager.loadProducts()
            await subscriptionManager.updateSubscriptionStatus()
            hasChecked = true
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(subscriptionManager: subscriptionManager) {
                showPaywall = false
            }
        }
    }

    @ViewBuilder
    private var trialBanner: some View {
        let days = subscriptionManager.daysUntilExpiry ?? 0
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark")
                Text(days <= 0 ? "Trial ends today — subscribe to keep access" : "Trial ends in \(days) day\(days == 1 ? "" : "s") — subscribe now")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.orange)
            .foregroundStyle(.white)
        }
        .accessibilityLabel("Trial ending soon. Tap to subscribe.")
    }

    @ViewBuilder
    private var graceBanner: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Payment issue — update your payment method in App Store settings")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.red)
            .foregroundStyle(.white)
        }
        .accessibilityLabel("Payment issue. Tap to update payment method.")
    }
}
