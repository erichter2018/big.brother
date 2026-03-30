import SwiftUI
import BigBrotherCore

/// Standalone section showing estimated per-app usage time
/// derived from DNS query proportional allocation across 15-minute slots.
struct AppUsageSection: View {

    let activity: DomainActivitySnapshot?
    let weekActivity: DomainActivitySnapshot?
    let dailySnapshots: [String: DomainActivitySnapshot]

    @State private var timeMode: TimeMode = .day

    enum TimeMode: String, CaseIterable {
        case day = "24h"
        case week = "7 days"
    }

    private var effectiveSnapshot: DomainActivitySnapshot? {
        switch timeMode {
        case .day: return activity
        case .week: return weekActivity ?? activity
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Label("APP USAGE", systemImage: "app.badge.checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $timeMode) {
                    ForEach(TimeMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            if let snapshot = effectiveSnapshot {
                let usage = snapshot.estimatedAppUsage()
                if usage.isEmpty {
                    Text("No recognized app activity")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    let maxMinutes = usage.first?.minutes ?? 1
                    VStack(spacing: 4) {
                        ForEach(usage, id: \.appName) { item in
                            HStack(spacing: 8) {
                                Text(item.appName)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)

                                Spacer()

                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(.indigo.opacity(0.4))
                                        .frame(width: max(4, geo.size.width * CGFloat(item.minutes / maxMinutes)))
                                }
                                .frame(width: 60, height: 8)

                                Text(Self.formatMinutes(item.minutes))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Text("Estimated from DNS activity while screen is on")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("No activity data available")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .padding(12)
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
    }

    static func formatMinutes(_ minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        if rounded >= 60 {
            let h = rounded / 60
            let m = rounded % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(rounded)m"
    }
}
