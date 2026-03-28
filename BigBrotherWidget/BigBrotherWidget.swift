import WidgetKit
import SwiftUI
import BigBrotherCore

// MARK: - Timeline Entry

struct StatusEntry: TimelineEntry {
    let date: Date
    let currentMode: LockMode
    let nextTransition: Date?
    let nextTransitionLabel: String?
    let selfUnlocksUsed: Int
    let selfUnlockBudget: Int
    let scheduleName: String?
    let isPlaceholder: Bool

    static let placeholder = StatusEntry(
        date: Date(),
        currentMode: .dailyMode,
        nextTransition: nil,
        nextTransitionLabel: nil,
        selfUnlocksUsed: 0,
        selfUnlockBudget: 0,
        scheduleName: "Schedule",
        isPlaceholder: true
    )
}

// MARK: - Timeline Provider

struct StatusProvider: TimelineProvider {
    private let storage = AppGroupStorage()

    func placeholder(in context: Context) -> StatusEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(buildEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = buildEntry()

        // Refresh at the next transition or in 15 minutes, whichever is sooner.
        let defaultRefresh = Date().addingTimeInterval(15 * 60)
        let refreshDate: Date
        if let next = entry.nextTransition, next > Date() {
            refreshDate = min(next, defaultRefresh)
        } else {
            refreshDate = defaultRefresh
        }

        let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
        completion(timeline)
    }

    private func buildEntry() -> StatusEntry {
        let now = Date()

        // Read schedule profile for mode and transitions.
        let profile = storage.readActiveScheduleProfile()
        let extState = storage.readExtensionSharedState()
        let snapshot = storage.readPolicySnapshot()

        // Determine current mode: prefer ExtensionSharedState > schedule > snapshot.
        let currentMode: LockMode
        if let ext = extState, ext.writtenAt > (snapshot?.createdAt ?? .distantPast) {
            currentMode = ext.currentMode
        } else if let profile {
            currentMode = profile.resolvedMode(at: now)
        } else {
            currentMode = snapshot?.effectivePolicy.resolvedMode ?? .unlocked
        }

        // Next transition.
        let nextTransition = profile?.nextTransitionTime(from: now)
        let nextTransitionLabel: String? = {
            guard let profile, let next = nextTransition else { return nil }
            let nextMode = profile.resolvedMode(at: next.addingTimeInterval(60))
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            switch currentMode {
            case .unlocked:
                return "Free until \(formatter.string(from: next))"
            case .dailyMode:
                return nextMode == .unlocked
                    ? "Locked until \(formatter.string(from: next))"
                    : "Locked until \(formatter.string(from: next))"
            case .essentialOnly:
                return "Essential until \(formatter.string(from: next))"
            }
        }()

        // Self-unlock state.
        let selfUnlockState = storage.readSelfUnlockState()
        let today = SelfUnlockState.todayDateString()
        let selfUnlocksUsed: Int
        if let state = selfUnlockState, state.date == today {
            selfUnlocksUsed = state.usedCount
        } else {
            selfUnlocksUsed = 0
        }
        let selfUnlockBudget = selfUnlockState?.budget ?? 0

        return StatusEntry(
            date: now,
            currentMode: currentMode,
            nextTransition: nextTransition,
            nextTransitionLabel: nextTransitionLabel,
            selfUnlocksUsed: selfUnlocksUsed,
            selfUnlockBudget: selfUnlockBudget,
            scheduleName: profile?.name,
            isPlaceholder: false
        )
    }
}

// MARK: - Widget View

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        default:
            mediumView
        }
    }

    private var modeColor: Color {
        switch entry.currentMode {
        case .unlocked: .green
        case .dailyMode: .blue
        case .essentialOnly: .purple
        }
    }

    private var modeIcon: String {
        switch entry.currentMode {
        case .unlocked: "lock.open.fill"
        case .dailyMode: "lock.fill"
        case .essentialOnly: "shield.fill"
        }
    }

    private var modeLabel: String {
        switch entry.currentMode {
        case .unlocked: "Free"
        case .dailyMode: "Locked"
        case .essentialOnly: "Essential"
        }
    }

    @ViewBuilder
    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: modeIcon)
                    .font(.title2)
                    .foregroundStyle(modeColor)
                Text(modeLabel)
                    .font(.title3.bold())
                    .foregroundStyle(modeColor)
            }

            if let label = entry.nextTransitionLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if entry.selfUnlockBudget > 0 {
                Text("\(entry.selfUnlocksUsed)/\(entry.selfUnlockBudget) self-unlocks")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    @ViewBuilder
    private var mediumView: some View {
        HStack(spacing: 16) {
            // Mode indicator
            VStack(spacing: 4) {
                Image(systemName: modeIcon)
                    .font(.system(size: 32))
                    .foregroundStyle(modeColor)
                Text(modeLabel)
                    .font(.headline)
                    .foregroundStyle(modeColor)
            }
            .frame(width: 80)

            // Details
            VStack(alignment: .leading, spacing: 4) {
                if let name = entry.scheduleName {
                    Text(name)
                        .font(.subheadline.bold())
                }

                if let label = entry.nextTransitionLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if entry.selfUnlockBudget > 0 {
                    let remaining = max(0, entry.selfUnlockBudget - entry.selfUnlocksUsed)
                    Text("\(remaining) self-unlock\(remaining == 1 ? "" : "s") remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let next = entry.nextTransition, next > entry.date {
                    Text(next, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}

// MARK: - Widget Configuration

struct BigBrotherStatusWidget: Widget {
    let kind: String = "BigBrotherStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Device Status")
        .description("Shows your current lock status and schedule.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Widget Bundle

@main
struct BigBrotherWidgetBundle: WidgetBundle {
    var body: some Widget {
        BigBrotherStatusWidget()
    }
}
