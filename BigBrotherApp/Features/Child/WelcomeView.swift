import SwiftUI

struct WelcomeView: View {

    let onContinue: () -> Void

    private struct Step: Identifiable {
        let id = UUID()
        let icon: String
        let color: Color
        let title: String
        let detail: String
    }

    private let steps: [Step] = [
        Step(
            icon: "shield.checkered",
            color: .blue,
            title: "Screen Time",
            detail: "You'll be asked to allow Screen Time access. This is required for app controls to work."
        ),
        Step(
            icon: "location.fill",
            color: .green,
            title: "Location",
            detail: "Choose \"Always Allow\" so location works even when the app is closed."
        ),
        Step(
            icon: "bell.badge.fill",
            color: .red,
            title: "Notifications",
            detail: "Allow notifications so your child sees schedule changes and unlock approvals."
        ),
        Step(
            icon: "network",
            color: .purple,
            title: "VPN",
            detail: "A local VPN will be installed. It doesn't send data anywhere — it's used for DNS filtering on this device."
        ),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        VStack(spacing: 20) {
                            ForEach(steps) { step in
                                stepRow(step)
                            }
                        }
                        .padding(.horizontal, 24)
                        Text("Each step takes one tap. You can fix any skipped permissions later from the child's home screen.")
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
                        Text("Start Setup")
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
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            Text("Device Setup")
                .font(.title.bold())
            Text("A few permissions are needed for Big Brother to protect this device. Here's what you'll be asked for:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: step.icon)
                .font(.title2)
                .foregroundStyle(step.color)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.headline)
                Text(step.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
