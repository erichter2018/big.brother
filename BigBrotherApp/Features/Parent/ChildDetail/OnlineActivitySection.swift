import SwiftUI
import BigBrotherCore

/// Shows online activity (DNS-based) for a child device.
/// Displays top visited domains and flagged inappropriate domains.
struct OnlineActivitySection: View {
    let activity: DomainActivitySnapshot?
    @State private var timeWindow: TimeWindow = .today

    enum TimeWindow: String, CaseIterable {
        case today = "24h"
        case week = "7 days"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Online Activity")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Picker("", selection: $timeWindow) {
                    ForEach(TimeWindow.allCases, id: \.self) { w in
                        Text(w.rawValue).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            if let activity, !activity.domains.isEmpty {
                // Flagged domains section
                let flagged = activity.flaggedDomains
                if !flagged.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Flagged Activity", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.red)

                        ForEach(flagged.prefix(5), id: \.domain) { hit in
                            HStack(spacing: 8) {
                                Image(systemName: categoryIcon(hit.category))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red)
                                    .frame(width: 14)

                                Text(hit.domain)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.red)

                                if let cat = hit.category {
                                    Text(cat)
                                        .font(.caption2)
                                        .foregroundStyle(.red.opacity(0.7))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.red.opacity(0.1))
                                        .clipShape(Capsule())
                                }

                                Spacer()

                                Text("\(hit.count)x")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(.red.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Divider()
                }

                // Top domains
                VStack(alignment: .leading, spacing: 6) {
                    Text("Most Visited")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let top = activity.topDomains(10).filter { !$0.flagged }
                    if top.isEmpty {
                        Text("No activity recorded")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(top, id: \.domain) { hit in
                            HStack(spacing: 8) {
                                Text(hit.domain)
                                    .font(.caption)
                                    .lineLimit(1)

                                Spacer()

                                // Simple bar visualization
                                let maxCount = top.first?.count ?? 1
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(.blue.opacity(0.3))
                                        .frame(width: max(4, geo.size.width * CGFloat(hit.count) / CGFloat(maxCount)))
                                }
                                .frame(width: 60, height: 8)

                                Text("\(hit.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                }

                // Summary
                HStack {
                    Spacer()
                    Text("\(activity.totalQueries) total lookups · \(activity.domains.count) sites")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No online activity recorded yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .padding(12)
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
    }

    private func categoryIcon(_ category: String?) -> String {
        switch category {
        case "adult": return "eye.slash"
        case "gambling": return "dice"
        case "drugs": return "leaf"
        case "violence": return "bolt.slash"
        case "proxy/vpn": return "shield.slash"
        case "dating": return "heart.slash"
        default: return "exclamationmark.triangle"
        }
    }
}
