import SwiftUI
import BigBrotherCore

/// Activity feed showing safety events, geofence transitions, and system events.
struct ActivityFeedView: View {
    @Bindable var viewModel: ActivityFeedViewModel

    var body: some View {
        List {
            // Filter section — pinned at top of list, not a separate VStack
            Section {
                filterBar
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color(.systemGroupedBackground))
            }

            if viewModel.selectedFilter == .report {
                // Weekly report view — filter by selected child
                let filteredChildren: [WeeklySummary.ChildWeek] = {
                    guard let summary = viewModel.weeklySummary else { return [] }
                    if let selectedID = viewModel.selectedChildID {
                        let selectedName = viewModel.sortedChildProfiles.first { $0.id == selectedID }?.name
                        return summary.children.filter { $0.name == selectedName }
                    }
                    return summary.children
                }()

                if !filteredChildren.isEmpty {
                    Section {
                        ForEach(filteredChildren, id: \.name) { child in
                            childReportCard(child)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color(.systemGroupedBackground))
                        }
                    } header: {
                        Text(weeklyReportHeader)
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                    }
                } else {
                    Section {
                        ContentUnavailableView {
                            Label("No Data", systemImage: "chart.bar")
                        } description: {
                            Text("Weekly report data will appear after devices have been active.")
                        }
                        .listRowSeparator(.hidden)
                    }
                }
            } else {
                // Event feed
                if viewModel.isLoading && viewModel.events.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading events...")
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                    }
                } else if viewModel.events.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Activity", systemImage: "bell.slash")
                        } description: {
                            Text("Events will appear here as children use their devices.")
                        }
                        .listRowSeparator(.hidden)
                    }
                } else {
                    ForEach(viewModel.groupedByDay, id: \.date) { group in
                        Section {
                            ForEach(group.events) { event in
                                eventRow(event)
                            }
                        } header: {
                            Text(group.label)
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .task {
            await viewModel.loadEvents()
            viewModel.markAsViewed()
        }
        .refreshable {
            await withDeadline(3) { await viewModel.loadEvents() }
        }
    }

    // MARK: - Filter Bar

    @ViewBuilder
    private var filterBar: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    childFilterChip(name: "All", id: nil)
                    ForEach(viewModel.sortedChildProfiles) { profile in
                        childFilterChip(name: profile.name, id: profile.id)
                    }
                }
                .padding(.horizontal, 16)
            }

            Picker("Filter", selection: $viewModel.selectedFilter) {
                ForEach(ActivityFeedViewModel.EventFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .onChange(of: viewModel.selectedFilter) { _, _ in
            Task { await viewModel.loadEvents() }
        }
    }

    @ViewBuilder
    private func childFilterChip(name: String, id: ChildProfileID?) -> some View {
        let selected = viewModel.selectedChildID == id
        Button {
            viewModel.selectedChildID = id
            Task { await viewModel.loadEvents() }
        } label: {
            Text(name)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.blue : Color(.tertiarySystemFill))
                .foregroundStyle(selected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Event Row

    @ViewBuilder
    private func eventRow(_ event: ActivityEvent) -> some View {
        if event.eventType == .tripCompleted, let child = viewModel.resolveChild(deviceID: event.deviceID) {
            NavigationLink {
                LocationMapView(
                    child: child,
                    devices: viewModel.appState.childDevices
                        .filter { $0.childProfileID == child.id }
                        .sorted { lhs, rhs in
                            if lhs.deviceKindSortRank != rhs.deviceKindSortRank {
                                return lhs.deviceKindSortRank < rhs.deviceKindSortRank
                            }
                            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                        },
                    heartbeats: viewModel.appState.latestHeartbeats(for: child.id),
                    cloudKit: viewModel.appState.cloudKit,
                    onLocate: {},
                    focusTripAt: event.timestamp
                )
            } label: {
                eventRowContent(event)
            }
        } else {
            eventRowContent(event)
        }
    }

    @ViewBuilder
    private func eventRowContent(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.icon)
                .font(.system(size: 13))
                .foregroundStyle(event.tintColor)
                .frame(width: 26, height: 26)
                .background(event.tintColor.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                if let detail = event.meaningfulDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(event.timeOnly)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if event.eventType == .tripCompleted {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var weeklyReportHeader: String {
        let cal = Calendar.current
        let today = Date()
        let weekAgo = cal.date(byAdding: .day, value: -6, to: today) ?? today
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "Report: \(fmt.string(from: weekAgo)) – \(fmt.string(from: today))"
    }

    // MARK: - Weekly Report Card

    @ViewBuilder
    private func childReportCard(_ child: WeeklySummary.ChildWeek) -> some View {
        let hasAnyData = child.avgScreenTimeMinutes != nil || child.safetyEvents > 0
            || child.unlockRequests > 0 || child.selfUnlocks > 0
            || child.trips > 0 || !child.newApps.isEmpty
            || !child.topApps.isEmpty || child.sitesVisited > 0

        VStack(alignment: .leading, spacing: 14) {
            // Header
            Text(child.name)
                .font(.title3.weight(.bold))

            if !hasAnyData {
                Text("No activity this week")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                // Screen Time + Device Usage row
                HStack(spacing: 10) {
                    if let avg = child.avgScreenTimeMinutes, avg > 0 {
                        reportTile(icon: "clock.fill", iconColor: .blue,
                                   value: formatMinutes(avg), label: "screen time avg/day")
                    }
                    if let unlocks = child.avgDailyUnlocks, unlocks > 0 {
                        reportTile(icon: "iphone", iconColor: .purple,
                                   value: "\(unlocks)", label: "pickups avg/day")
                    }
                    if let peak = child.peakHour {
                        reportTile(icon: "sun.max.fill", iconColor: .orange,
                                   value: peak, label: "most active")
                    }
                }

                // Top Apps
                if !child.topApps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top Apps")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        let maxMin = child.topApps.first?.minutes ?? 1
                        ForEach(child.topApps, id: \.name) { app in
                            HStack(spacing: 8) {
                                Text(app.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(.indigo.opacity(0.5))
                                        .frame(width: max(6, geo.size.width * CGFloat(app.minutes / maxMin)))
                                }
                                .frame(width: 70, height: 10)
                                Text(AppUsageSection.formatMinutes(app.minutes))
                                    .font(.caption.weight(.medium))
                                    .frame(width: 48, alignment: .trailing)
                            }
                        }
                    }
                }

                // Web Activity
                if child.sitesVisited > 0 || child.flaggedAttempts > 0 {
                    HStack(spacing: 10) {
                        if child.sitesVisited > 0 {
                            reportTile(icon: "globe", iconColor: .cyan,
                                       value: "\(child.sitesVisited)", label: "sites visited")
                        }
                        if child.flaggedAttempts > 0 {
                            reportTile(icon: "exclamationmark.shield.fill", iconColor: .red,
                                       value: "\(child.flaggedAttempts)", label: "flagged sites")
                        }
                    }

                    if !child.flaggedDomains.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                            Text(child.flaggedDomains.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.8))
                                .lineLimit(2)
                        }
                    }
                }

                // Behavior stats
                let behaviorStats = buildBehaviorStats(child)
                if !behaviorStats.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(behaviorStats, id: \.label) { stat in
                            HStack(spacing: 6) {
                                Image(systemName: stat.icon)
                                    .font(.caption)
                                    .foregroundStyle(stat.color)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("\(stat.value)")
                                        .font(.subheadline.weight(.bold))
                                    Text(stat.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(stat.color.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                // New apps
                if !child.newApps.isEmpty {
                    let unique = Array(Set(child.newApps)).sorted()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New App Activity")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(unique, id: \.self) { app in
                                Text(app)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.indigo.opacity(0.12))
                                    .foregroundStyle(.indigo)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
    }

    @ViewBuilder
    private func reportTile(icon: String, iconColor: Color, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(iconColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private struct StatItem {
        let icon: String
        let value: Int
        let label: String
        let color: Color
    }

    private func buildBehaviorStats(_ child: WeeklySummary.ChildWeek) -> [StatItem] {
        var stats: [StatItem] = []
        if child.unlockRequests > 0 {
            stats.append(StatItem(icon: "lock.open", value: child.unlockRequests, label: "unlock requests", color: .blue))
        }
        if child.selfUnlocks > 0 {
            stats.append(StatItem(icon: "lock.rotation", value: child.selfUnlocks, label: "self-unlocks", color: .teal))
        }
        if child.safetyEvents > 0 {
            stats.append(StatItem(icon: "exclamationmark.triangle.fill", value: child.safetyEvents, label: "safety alerts", color: .red))
        }
        if child.trips > 0 {
            stats.append(StatItem(icon: "car.fill", value: child.trips, label: child.trips == 1 ? "trip" : "trips", color: .green))
        }
        return stats
    }

    /// Simple flow layout for tag-style content.
    private struct FlowLayout: Layout {
        var spacing: CGFloat = 6

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let maxWidth = proposal.width ?? .infinity
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            return CGSize(width: maxWidth, height: y + rowHeight)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var x: CGFloat = bounds.minX
            var y: CGFloat = bounds.minY
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > bounds.maxX && x > bounds.minX {
                    x = bounds.minX
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(minutes)m"
    }
}
