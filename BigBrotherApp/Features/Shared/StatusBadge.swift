import SwiftUI

struct StatusBadge: View {
    let label: String
    let color: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    static func online() -> StatusBadge {
        StatusBadge(label: "Online", color: .green, icon: "circle.fill")
    }

    static func offline() -> StatusBadge {
        StatusBadge(label: "Offline", color: .secondary, icon: "circle")
    }

    static func warning(_ text: String) -> StatusBadge {
        StatusBadge(label: text, color: .orange, icon: "exclamationmark.triangle")
    }

    static func error(_ text: String) -> StatusBadge {
        StatusBadge(label: text, color: .red, icon: "xmark.circle")
    }
}
