import SwiftUI
import BigBrotherCore

/// Shows online activity (DNS-based) for a child device.
/// Can show top visited domains, flagged domains, or both.
/// Supports time-based scrubbing by 15-minute slots with day navigation.
struct OnlineActivitySection: View {
    let activity: DomainActivitySnapshot?
    /// 7-day merged snapshot (aggregate counts, no slot data).
    var weekActivity: DomainActivitySnapshot?
    /// Per-day snapshots keyed by "yyyy-MM-dd" for timeline day navigation.
    var dailySnapshots: [String: DomainActivitySnapshot] = [:]
    var showFlagged: Bool = true
    var flaggedOnly: Bool = false
    @State private var timeMode: TimeMode = .day
    @State private var selectedSlot: Double = 0
    /// Days offset from today (0 = today, -1 = yesterday, etc.)
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

    /// The date string for the currently selected day in timeline mode.
    private var selectedDateString: String {
        guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else {
            return Self.dateFmt.string(from: Date())
        }
        return Self.dateFmt.string(from: date)
    }

    /// Human-readable label for the selected day.
    private var selectedDayLabel: String {
        if dayOffset == 0 { return "Today" }
        if dayOffset == -1 { return "Yesterday" }
        guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else { return "" }
        return Self.displayDateFmt.string(from: date)
    }

    /// The snapshot for the currently selected day in timeline mode.
    private var selectedDaySnapshot: DomainActivitySnapshot? {
        dailySnapshots[selectedDateString] ?? (dayOffset == 0 ? activity : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label(flaggedOnly ? "FLAGGED ACTIVITY" : "ONLINE ACTIVITY",
                      systemImage: flaggedOnly ? "exclamationmark.triangle.fill" : "globe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(flaggedOnly ? .red : .secondary)
                    .onTapGesture {
                        guard let snapshot = effectiveSnapshot else { return }
                        let visible = snapshot.domains
                            .filter { !$0.flagged && !DomainCategorizer.isNoise($0.domain) }
                            .sorted { $0.count > $1.count }
                            .map { "\($0.domain) \($0.count)" }
                            .joined(separator: "\n")
                        UIPasteboard.general.string = visible
                    }

                Spacer()

                if !flaggedOnly {
                    Picker("", selection: $timeMode) {
                        ForEach(TimeMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
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
            }

            if let effectiveActivity = effectiveSnapshot, !effectiveActivity.domains.isEmpty {
                if flaggedOnly {
                    flaggedSection(effectiveActivity.flaggedDomains)
                } else if timeMode == .scrub {
                    if let snap = selectedDaySnapshot, !snap.domains.isEmpty {
                        timeScrubberView(snap)
                    } else {
                        dayNavigationRow(slot: 0, lookups: 0)
                        Text("No activity recorded")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                } else {
                    // Hero stats + sparkline + domain list
                    heroStatsRow(effectiveActivity)

                    if let daySnap = activity, timeMode == .day {
                        miniSparkline(daySnap)
                    }

                    if showFlagged {
                        let flagged = effectiveActivity.flaggedDomains
                        if !flagged.isEmpty {
                            flaggedSection(flagged)
                            Divider()
                        }
                    }

                    topDomainsSection(effectiveActivity)
                }
            } else {
                Text(flaggedOnly ? "No flagged activity" : "No online activity recorded yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .padding(12)
        .if_iOS26GlassEffect(
            fallbackMaterial: .ultraThinMaterial,
            borderColor: flaggedOnly ? .red : .secondary
        )
    }

    /// Returns the right snapshot based on the selected time mode.
    private var effectiveSnapshot: DomainActivitySnapshot? {
        switch timeMode {
        case .day:
            return activity
        case .scrub:
            return selectedDaySnapshot ?? weekActivity ?? activity
        case .week:
            return weekActivity ?? activity
        }
    }

    // MARK: - Hero Stats

    @ViewBuilder
    private func heroStatsRow(_ activity: DomainActivitySnapshot) -> some View {
        let visibleDomains = activity.domains.filter { !DomainCategorizer.isNoise($0.domain) }
        let siteCount = visibleDomains.count
        let activeSlotCount = activity.activeSlots.count
        let activeHours = Double(activeSlotCount) / 4.0

        HStack(spacing: 0) {
            heroStat(value: "\(siteCount)", label: "sites")
            Spacer()
            heroStat(value: "\(activity.totalQueries)", label: "lookups")
            Spacer()
            heroStat(value: String(format: "%.1f", activeHours), label: "hrs active")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func heroStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Mini Sparkline

    @ViewBuilder
    private func miniSparkline(_ activity: DomainActivitySnapshot) -> some View {
        VStack(spacing: 2) {
            let currentSlot: Int = {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
                return DomainHit.slotIndex(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
            }()
            let maxCount = max(1, (0..<96).map { activity.totalQueries(forSlot: $0) }.max() ?? 1)

            HStack(spacing: 0.5) {
                ForEach(0..<96, id: \.self) { s in
                    let count = activity.totalQueries(forSlot: s)
                    let height: CGFloat = count > 0 ? max(2, 16 * CGFloat(count) / CGFloat(maxCount)) : 0
                    let isFuture = s > currentSlot

                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(count > 0 ? Color.blue.opacity(0.5) : Color.clear)
                        .frame(height: height)
                        .frame(maxHeight: 16, alignment: .bottom)
                        .opacity(isFuture ? 0.15 : 1)
                }
            }
            .frame(height: 16)

            HStack {
                Text("12a").font(.system(size: 7)).foregroundStyle(.tertiary)
                Spacer()
                Text("6a").font(.system(size: 7)).foregroundStyle(.tertiary)
                Spacer()
                Text("12p").font(.system(size: 7)).foregroundStyle(.tertiary)
                Spacer()
                Text("6p").font(.system(size: 7)).foregroundStyle(.tertiary)
                Spacer()
                Text("12a").font(.system(size: 7)).foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Day Navigation + Time Label (combined row)

    @ViewBuilder
    private func dayNavigationRow(slot: Int, lookups: Int) -> some View {
        ZStack {
            // Left: time range
            HStack {
                Text(DomainHit.slotRangeLabel(slot))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                Spacer()
            }

            // Center: day navigation (fixed layout — always same elements)
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        dayOffset = max(dayOffset - 1, -6)
                        selectedSlot = 0
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(dayOffset > -6 ? Color.blue : Color.gray.opacity(0.3))
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
                        .foregroundStyle(dayOffset < 0 ? Color.blue : Color.gray.opacity(0.3))
                }
                .disabled(dayOffset >= 0)
            }

            // Right: lookups count
            HStack {
                Spacer()
                Text(lookups > 0 ? "\(lookups) lookups" : "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Time Scrubber

    @ViewBuilder
    private func timeScrubberView(_ activity: DomainActivitySnapshot) -> some View {
        let slot = Int(selectedSlot)
        let isToday = dayOffset == 0
        let currentSlot: Int = {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
            return DomainHit.slotIndex(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
        }()

        VStack(spacing: 8) {
            dayNavigationRow(slot: slot, lookups: activity.totalQueries(forSlot: slot))

            // Activity bar chart (mini heatmap)
            HStack(spacing: 1) {
                ForEach(0..<96, id: \.self) { s in
                    let count = activity.totalQueries(forSlot: s)
                    let maxSlotCount = (0..<96).map { activity.totalQueries(forSlot: $0) }.max() ?? 1
                    let height: CGFloat = count > 0 ? max(3, 20 * CGFloat(count) / CGFloat(max(1, maxSlotCount))) : 0
                    let isSelected = s == slot
                    let isFuture = isToday && s > currentSlot

                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected ? Color.blue : (count > 0 ? Color.blue.opacity(0.4) : Color.clear))
                        .frame(height: height)
                        .frame(maxHeight: 20, alignment: .bottom)
                        .opacity(isFuture ? 0.2 : 1)
                }
            }
            .frame(height: 20)

            // Slider
            Slider(value: $selectedSlot, in: 0...95, step: 1)
                .tint(.blue)

            // Hour labels
            HStack {
                Text("12 AM")
                Spacer()
                Text("6 AM")
                Spacer()
                Text("12 PM")
                Spacer()
                Text("6 PM")
                Spacer()
                Text("12 AM")
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)

            Divider()

            // Domains for selected slot — fixed height to prevent bouncing
            let slotDomains = activity.domains(forSlot: slot)
                .filter { !DomainCategorizer.isNoise($0.domain) }
            VStack(spacing: 0) {
                if slotDomains.isEmpty {
                    Text("No activity")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(slotDomains.prefix(15), id: \.domain) { hit in
                                let slotCount = hit.count(forSlot: slot)
                                HStack(spacing: 8) {
                                    if hit.flagged {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.red)
                                    }
                                    Text(hit.domain)
                                        .font(.caption)
                                        .foregroundStyle(hit.flagged ? .red : .primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(slotCount)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .frame(height: 200)
        }
    }

    // MARK: - Flagged Section

    @ViewBuilder
    private func flaggedSection(_ flagged: [DomainHit]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !flaggedOnly {
                Label("Flagged", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
            }

            ForEach(flagged.prefix(10), id: \.domain) { hit in
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
        .padding(flaggedOnly ? 0 : 8)
        .background(flaggedOnly ? .clear : .red.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Top Domains (Day/Week)

    @ViewBuilder
    private func topDomainsSection(_ activity: DomainActivitySnapshot) -> some View {
        let top = activity.domains
            .sorted { $0.count > $1.count }
            .filter { !$0.flagged && !DomainCategorizer.isNoise($0.domain) }

        VStack(alignment: .leading, spacing: 6) {
            Text("Most Visited")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if top.isEmpty {
                Text("No activity recorded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                let maxCount = top.first?.count ?? 1
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(top, id: \.domain) { hit in
                            HStack(spacing: 8) {
                                // App name badge if recognized
                                let root = DomainCategorizer.rootDomain(hit.domain)
                                let appName = DomainCategorizer.appName(for: root)

                                VStack(alignment: .leading, spacing: 1) {
                                    if let appName {
                                        Text(appName)
                                            .font(.subheadline.weight(.medium))
                                        Text(hit.domain)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(hit.domain)
                                            .font(.subheadline)
                                    }
                                }
                                .lineLimit(1)

                                Spacer()

                                // Bar
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(appName != nil ? Color.indigo.opacity(0.6) : Color.blue.opacity(0.4))
                                        .frame(width: max(6, geo.size.width * CGFloat(hit.count) / CGFloat(maxCount)))
                                }
                                .frame(width: 80, height: 12)

                                Text("\(hit.count)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }

        HStack {
            Spacer()
            let visibleSites = top.count
            Text("\(visibleSites) sites visited")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
