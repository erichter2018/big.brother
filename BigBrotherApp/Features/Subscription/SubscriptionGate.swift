import SwiftUI

/// Non-blocking subscription banner overlay.
/// Shows trial/grace warnings but never blocks access to the parent UI.
/// The paywall only appears as a sheet (from AddChildView or command gate).
/// Child devices are never gated — enforcement works regardless of subscription.
struct SubscriptionBanner<Content: View>: View {
    let subscriptionManager: SubscriptionManager
    @ViewBuilder let content: () -> Content

    @State private var showPaywall = false

    var body: some View {
        content()
            .overlay(alignment: .top) {
                if subscriptionManager.isTrialEndingSoon {
                    trialBanner
                } else if subscriptionManager.subscriptionStatus == .grace {
                    graceBanner
                }
            }
            .task {
                await subscriptionManager.loadProducts()
                await subscriptionManager.updateSubscriptionStatus()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(subscriptionManager: subscriptionManager) {
                    showPaywall = false
                }
            }
    }

    // Keep old name available for any other references.
    typealias SubscriptionGate = SubscriptionBanner

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
