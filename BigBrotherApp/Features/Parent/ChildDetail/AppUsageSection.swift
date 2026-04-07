import SwiftUI
import BigBrotherCore

/// Standalone section showing estimated per-app usage time
/// derived from DNS query proportional allocation across 15-minute slots.
/// Supports timeline scrubbing with day navigation (same pattern as OnlineActivitySection).
struct AppUsageSection: View {

    let activity: DomainActivitySnapshot?
    let weekActivity: DomainActivitySnapshot?
    let dailySnapshots: [String: DomainActivitySnapshot]

    @State private var timeMode: TimeMode = .day
    @State private var selectedSlot: Double = 0
    @State private var dayOffset: Int = 0

    enum TimeMode: String, CaseIterable {
        case day = "Today"
        case week = "7 days"
        case scrub = "Timeline"
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    private var selectedDateString: String {
        guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else {
            return Self.dateFmt.string(from: Date())
        }
        return Self.dateFmt.string(from: date)
    }

    private var selectedDayLabel: String {
        if dayOffset == 0 { return "Today" }
        if dayOffset == -1 { return "Yesterday" }
        guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else { return "" }
        return Self.displayDateFmt.string(from: date)
    }

    private var selectedDaySnapshot: DomainActivitySnapshot? {
        dailySnapshots[selectedDateString] ?? (dayOffset == 0 ? activity : nil)
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
                .frame(width: 200)
                .onChange(of: timeMode) { _, newMode in
                    if newMode == .scrub {
                        dayOffset = 0
                        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
                        selectedSlot = Double(DomainHit.slotIndex(hour: comps.hour ?? 0, minute: comps.minute ?? 0))
                    }
                }
            }

            switch timeMode {
            case .day:
                appList(activity?.estimatedAppUsage() ?? [])
            case .week:
                appList(weeklyAppUsage)
            case .scrub:
                if let snap = selectedDaySnapshot {
                    timelineScrubber(snap)
                } else {
                    dayNavigationRow(slot: 0)
                    Text("No activity recorded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(12)
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
    }

    // MARK: - App List

    @ViewBuilder
    private func appList(_ usage: [(appName: String, minutes: Double)]) -> some View {
        if !usage.isEmpty {
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
        } else {
            Text("No recognized app activity")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Timeline Scrubber

    @ViewBuilder
    private func timelineScrubber(_ snap: DomainActivitySnapshot) -> some View {
        let slot = Int(selectedSlot)
        let isToday = dayOffset == 0
        let currentSlot: Int = {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
            return DomainHit.slotIndex(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
        }()

        VStack(spacing: 8) {
            dayNavigationRow(slot: slot)

            // Per-slot app usage bar chart — height proportional to app count in slot
            HStack(spacing: 1) {
                ForEach(0..<96, id: \.self) { s in
                    let apps = snap.estimatedAppUsage(forSlot: s)
                    let appCount = apps.count
                    let maxApps = (0..<96).map { snap.estimatedAppUsage(forSlot: $0).count }.max() ?? 1
                    let height: CGFloat = appCount > 0 ? max(3, 20 * CGFloat(appCount) / CGFloat(max(1, maxApps))) : 0
                    let isSelected = s == slot
                    let isFuture = isToday && s > currentSlot

                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected ? Color.indigo : (appCount > 0 ? Color.indigo.opacity(0.4) : Color.clear))
                        .frame(height: height)
                        .frame(maxHeight: 20, alignment: .bottom)
                        .opacity(isFuture ? 0.2 : 1)
                }
            }
            .frame(height: 20)

            Slider(value: $selectedSlot, in: 0...95, step: 1)
                .tint(.indigo)

            // Hour labels
            HStack {
                Text("12 AM"); Spacer(); Text("6 AM"); Spacer()
                Text("12 PM"); Spacer(); Text("6 PM"); Spacer(); Text("12 AM")
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)

            Divider()

            // Apps for selected slot
            let slotApps = snap.estimatedAppUsage(forSlot: slot)
            if slotApps.isEmpty {
                Text("No app activity")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                let maxMinutes = slotApps.first?.minutes ?? 1
                VStack(spacing: 4) {
                    ForEach(slotApps, id: \.appName) { item in
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
        }
    }

    // MARK: - Day Navigation

    @ViewBuilder
    private func dayNavigationRow(slot: Int) -> some View {
        ZStack {
            HStack {
                Text(DomainHit.slotRangeLabel(slot))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.indigo)
                    .lineLimit(1)
                Spacer()
            }

            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        dayOffset = max(dayOffset - 1, -6)
                        selectedSlot = 0
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(dayOffset > -6 ? Color.indigo : Color.gray.opacity(0.3))
                }
                .disabled(dayOffset <= -6)

                Text(selectedDayLabel)
                    .font(.caption)
                    .fontWeight(.medium)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        dayOffset = min(dayOffset + 1, 0)
                        if dayOffset == 0 {
                            let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
                            selectedSlot = Double(DomainHit.slotIndex(hour: comps.hour ?? 0, minute: comps.minute ?? 0))
                        } else {
                            selectedSlot = 95
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(dayOffset < 0 ? Color.indigo : Color.gray.opacity(0.3))
                }
                .disabled(dayOffset >= 0)
            }

            HStack {
                Spacer()
            }
        }
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
