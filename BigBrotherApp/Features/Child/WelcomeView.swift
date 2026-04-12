import SwiftUI

/// First-launch intro screen for a freshly-enrolled child device.
///
/// Shown before `PermissionFixerView` so the kid (or the parent holding
/// the device) understands what Big Brother is, what it's about to ask
/// for, and why — before any system permission prompts fire. Dismissed
/// via "Get started," which hands off to the permission fixer.
///
/// Intentionally lightweight: no AppState dependency, no side effects.
/// The caller owns the presentation state and decides what to do on
/// dismiss.
struct WelcomeView: View {

    let onContinue: () -> Void

    private struct Bullet: Identifiable {
        let id = UUID()
        let icon: String
        let color: Color
        let title: String
        let detail: String
    }

    private let bullets: [Bullet] = [
        Bullet(
            icon: "shield.checkered",
            color: .blue,
            title: "Screen Time rules",
            detail: "Your parent sets which apps are allowed and when they unlock. Big Brother enforces those rules on this device."
        ),
        Bullet(
            icon: "location.fill",
            color: .green,
            title: "Location",
            detail: "Your parent can see where you are, including saved places like home and school."
        ),
        Bullet(
            icon: "car.fill",
            color: .orange,
            title: "Driving safety",
            detail: "If you're moving in a car, Big Brother blocks phone use until you stop."
        ),
        Bullet(
            icon: "bell.badge.fill",
            color: .red,
            title: "Notifications",
            detail: "Get alerts about schedule changes, unlock approvals, and messages from your parent."
        ),
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        VStack(spacing: 20) {
                            ForEach(bullets) { bullet in
                                bulletRow(bullet)
                            }
                        }
                        .padding(.horizontal, 24)
                        Text("The next few screens will ask you to grant each permission. You can tap \"Skip\" on any of them and enable it later.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.top, 8)
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 24)
                }

                VStack(spacing: 8) {
                    Button(action: onContinue) {
                        Text("Get started")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .background(.ultraThinMaterial)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
            Text("Welcome to Big Brother")
                .font(.title.bold())
            Text("Here's what this app does on your device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private func bulletRow(_ bullet: Bullet) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: bullet.icon)
                .font(.title2)
                .foregroundStyle(bullet.color)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(bullet.title)
                    .font(.headline)
                Text(bullet.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
