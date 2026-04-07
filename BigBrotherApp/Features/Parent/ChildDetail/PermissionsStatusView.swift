import SwiftUI
import BigBrotherCore

/// Shows per-device permission status with fix buttons.
/// Displayed in the child detail view for each device.
struct PermissionsStatusView: View {
    let device: ChildDevice
    let heartbeat: DeviceHeartbeat?
    let onRequestPermissions: () async -> Void
    @State private var requestCooldown = false

    private var anyIssue: Bool {
        guard let hb = heartbeat else { return true }
        return !hb.familyControlsAuthorized
            || hb.locationAuthorization != "always"
            || hb.tunnelConnected != true
            || hb.motionAuthorized != true
            || hb.notificationsAuthorized != true
    }

    var body: some View {
        if let hb = heartbeat {
            VStack(alignment: .leading, spacing: 8) {
                permissionRow(
                    "Parental Controls",
                    icon: "shield.checkered",
                    status: hb.familyControlsAuthorized ? .ok : .critical,
                    detail: hb.familyControlsAuthorized
                        ? (hb.isChildAuthorization == true ? "Child auth" : "Individual auth")
                        : "Not authorized"
                )

                permissionRow(
                    "Location",
                    icon: "location.fill",
                    status: locationStatus(hb.locationAuthorization),
                    detail: locationDetail(hb.locationAuthorization)
                )

                permissionRow(
                    "VPN Tunnel",
                    icon: "network.badge.shield.half.filled",
                    status: hb.tunnelConnected == true ? .ok : hb.tunnelConnected == false ? .warning : .unknown,
                    detail: hb.tunnelConnected == true ? "Connected" : hb.tunnelConnected == false ? "Disconnected" : "Not reported"
                )

                permissionRow(
                    "Motion & Fitness",
                    icon: "figure.walk",
                    status: hb.motionAuthorized == true ? .ok : hb.motionAuthorized == false ? .warning : .unknown,
                    detail: hb.motionAuthorized == true ? "Authorized" : hb.motionAuthorized == false ? "Denied" : "Not reported"
                )

                permissionRow(
                    "Notifications",
                    icon: "bell.fill",
                    status: hb.notificationsAuthorized == true ? .ok : hb.notificationsAuthorized == false ? .warning : .unknown,
                    detail: hb.notificationsAuthorized == true ? "Authorized" : hb.notificationsAuthorized == false ? "Denied" : "Not reported"
                )

                if anyIssue {
                    Button {
                        requestCooldown = true
                        Task {
                            await onRequestPermissions()
                            try? await Task.sleep(for: .seconds(5))
                            requestCooldown = false
                        }
                    } label: {
                        Label("Re-request Permissions", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(requestCooldown ? .gray : .orange)
                    .controlSize(.small)
                    .disabled(requestCooldown)
                }
            }
        } else {
            HStack {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text("No heartbeat data — device may be offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private enum PermStatus { case ok, warning, critical, unknown }

    @ViewBuilder
    private func permissionRow(_ name: String, icon: String, status: PermStatus, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 20)
                .foregroundStyle(statusColor(status))

            Text(name)
                .font(.subheadline)

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 6, height: 6)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusColor(_ s: PermStatus) -> Color {
        switch s {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .gray
        }
    }

    private func locationStatus(_ auth: String?) -> PermStatus {
        switch auth {
        case "always": return .ok
        case "whenInUse": return .warning
        case "denied", "restricted": return .critical
        default: return .unknown
        }
    }

    private func locationDetail(_ auth: String?) -> String {
        switch auth {
        case "always": return "Always"
        case "whenInUse": return "When In Use (needs Always)"
        case "denied": return "Denied"
        case "restricted": return "Restricted"
        case "notDetermined": return "Not asked yet"
        default: return "Not reported"
        }
    }
}
