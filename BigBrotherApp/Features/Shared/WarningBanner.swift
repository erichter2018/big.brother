import SwiftUI
import BigBrotherCore

struct WarningBanner: View {
    let warnings: [CapabilityWarning]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings, id: \.self) { warning in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                        Text(warning.userMessage)
                            .font(.subheadline)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

extension CapabilityWarning {
    var userMessage: String {
        switch self {
        case .familyControlsNotAuthorized:
            "Screen Time permissions not granted. Restrictions may not work."
        case .someSystemAppsCannotBeBlocked:
            "Some system apps (Phone, Settings) cannot be restricted."
        case .scheduleMayNotFireIfAppKilled:
            "Schedule enforcement depends on the app running in background."
        case .offlineUsingCachedPolicy:
            "Device is offline. Using last known policy."
        case .tokensMissingForDevice:
            "Allowed app list is not configured for this device."
        case .enforcementDegraded:
            "Enforcement is degraded due to missing permissions."
        case .failSafeModeApplied:
            "Fail-safe mode is active due to an error."
        }
    }
}
