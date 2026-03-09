import SwiftUI
import BigBrotherCore

struct TemporaryUnlockCard: View {
    let state: TemporaryUnlockState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.orange)
                Text("Temporary Unlock Active")
                    .font(.headline)
                Spacer()
            }

            HStack {
                Text("Expires in")
                    .foregroundStyle(.secondary)
                Text(remainingText)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }
            .font(.subheadline)

            HStack {
                Text("Origin:")
                    .foregroundStyle(.secondary)
                Text(state.origin == .remoteCommand ? "Remote (parent)" : "Local PIN")
            }
            .font(.caption)

            Text("Will revert to \(state.previousMode.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var remainingText: String {
        let remaining = state.remainingSeconds(at: now)
        if remaining <= 0 { return "Expired" }
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}
