import SwiftUI
import StoreKit

/// Subscription paywall shown after onboarding or when subscription expires.
/// Offers monthly and annual plans with a 14-day free trial.
struct PaywallView: View {
    let subscriptionManager: SubscriptionManager
    var onDismiss: (() -> Void)?

    @State private var selectedProduct: Product?
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    featuresSection
                    plansSection
                    trialBadge
                    legalSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)
            }

            ctaSection
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            restoreButton
                .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
        .task {
            await subscriptionManager.loadProducts()
            // Default to annual (better value)
            selectedProduct = subscriptionManager.products.first(where: { $0.id == SubscriptionManager.annualID })
                ?? subscriptionManager.products.first
        }
        .alert("Purchase Failed", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("Big Brother")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Screen time management\nfor the whole family")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Features

    @ViewBuilder
    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            featureRow(icon: "iphone.gen3", color: .blue, text: "Unlimited devices")
            featureRow(icon: "calendar.badge.clock", color: .green, text: "Custom schedules per child")
            featureRow(icon: "lock.shield", color: .purple, text: "App blocking with per-app unlock")
            featureRow(icon: "bell.badge", color: .orange, text: "Real-time dashboard & alerts")
            featureRow(icon: "person.3", color: .teal, text: "Unlimited devices included")
        }
        .padding(16)
        .if_iOS26GlassEffect(fallbackMaterial: .regularMaterial, borderColor: .secondary)
    }

    @ViewBuilder
    private func featureRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: - Plans

    @ViewBuilder
    private var plansSection: some View {
        VStack(spacing: 10) {
            ForEach(subscriptionManager.products, id: \.id) { product in
                planCard(product)
            }
        }
    }

    @ViewBuilder
    private func planCard(_ product: Product) -> some View {
        let isSelected = selectedProduct?.id == product.id
        let isAnnual = product.id == SubscriptionManager.annualID

        Button {
            selectedProduct = product
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isAnnual ? "Annual" : "Monthly")
                            .font(.headline)
                        if isAnnual {
                            Text("Save 40%")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }
                    if isAnnual, let monthly = SubscriptionManager.monthlyEquivalent(for: product) {
                        Text("\(monthly)/mo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(SubscriptionManager.priceLabel(for: product))
                    .font(.headline)
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Trial Badge

    @ViewBuilder
    private var trialBadge: some View {
        if subscriptionManager.isEligibleForTrial {
            HStack(spacing: 6) {
                Image(systemName: "gift")
                    .foregroundStyle(.green)
                Text("Includes 14-day free trial")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Includes 14-day free trial")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text("Free trial already used")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - CTA

    @ViewBuilder
    private var ctaSection: some View {
        Button {
            guard let product = selectedProduct else { return }
            Task {
                await subscriptionManager.purchase(product)
                switch subscriptionManager.purchaseState {
                case .success:
                    onDismiss?()
                case .failed(let msg):
                    errorMessage = msg
                    showError = true
                default:
                    break
                }
            }
        } label: {
            Group {
                if case .purchasing = subscriptionManager.purchaseState {
                    ProgressView()
                        .tint(.white)
                } else if subscriptionManager.isEligibleForTrial {
                    Text("Start 14-Day Free Trial")
                } else {
                    Text("Subscribe")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.blue)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(selectedProduct == nil || subscriptionManager.purchaseState == .purchasing)
    }

    // MARK: - Restore & Legal

    @ViewBuilder
    private var restoreButton: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    await subscriptionManager.restorePurchases()
                    if subscriptionManager.isSubscribed {
                        onDismiss?()
                    }
                }
            } label: {
                Text("Restore Purchases")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = subscriptionManager.restoreError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            #if DEBUG
            Button {
                subscriptionManager.debugOverride = .subscribed
                onDismiss?()
            } label: {
                Text("Debug: Skip (dev only)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            #endif
        }
    }

    @ViewBuilder
    private var legalSection: some View {
        VStack(spacing: 4) {
            Text("Payment will be charged to your Apple ID account at confirmation of purchase. Subscription automatically renews unless cancelled at least 24 hours before the end of the current period.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Link("Terms of Use", destination: URL(string: "https://bigbrother.fr/terms")!)
                Link("Privacy Policy", destination: URL(string: "https://bigbrother.fr/privacy")!)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
