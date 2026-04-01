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
        case day = "Today"
        case week = "7 days"
    }

    /// For the 7-day view, aggregate per-day app usage (each day has slot data
    /// for accurate Meta disambiguation) instead of running on the slotless aggregate.
    private var weeklyAppUsage: [(appName: String, minutes: Double)] {
        var totals: [String: Double] = [:]
        for (_, snapshot) in dailySnapshots {
            for entry in snapshot.estimatedAppUsage() {
                totals[entry.appName, default: 0] += entry.minutes
            }
        }
        return totals
            .map { (appName: $0.key, minutes: $0.value) }
            .filter { $0.minutes >= 1.0 }
            .sorted { $0.minutes > $1.minutes }
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

            let usage: [(appName: String, minutes: Double)] = {
                switch timeMode {
                case .day: return activity?.estimatedAppUsage() ?? []
                case .week: return weeklyAppUsage
                }
            }()

            if !usage.isEmpty || (timeMode == .day && activity != nil) || (timeMode == .week && weekActivity != nil) {
                if usage.isEmpty {
                    Text("No recognized app activity")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    let maxMinutes = usage.first?.minutes ?? 1
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(usage, id: \.appName) { item in
                                HStack(spacing: 8) {
                                    Text(item.appName)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)

                                    Spacer()

                                    GeometryReader { geo in
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(.indigo.opacity(0.6))
                                            .frame(width: max(6, geo.size.width * CGFloat(item.minutes / maxMinutes)))
                                    }
                                    .frame(width: 80, height: 12)

                                    Text(Self.formatMinutes(item.minutes))
                                        .font(.caption.weight(.medium))
                                        .frame(width: 48, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 320)

                    HStack {
                        Spacer()
                        Text("Estimated from DNS activity while screen is on")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
