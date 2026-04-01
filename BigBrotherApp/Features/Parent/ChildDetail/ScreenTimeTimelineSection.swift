import SwiftUI
import BigBrotherCore

/// Shows screen time broken down by 15-minute slots throughout the day.
/// Displays a heatmap bar and total per slot, with day-by-day navigation.
struct ScreenTimeTimelineSection: View {
    /// Per-day slot data keyed by "yyyy-MM-dd" (slot index → seconds).
    let slotsByDay: [String: [Int: Int]]
    /// Weekly totals for the bar chart.
    let weeklyScreenTime: [(date: Date, minutes: Int)]
    @State private var dayOffset: Int = 0

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

    private var selectedDaySlots: [Int: Int] {
        slotsByDay[selectedDateString] ?? [:]
    }

    private var selectedDayTotalMinutes: Int {
        let totalSeconds = selectedDaySlots.values.reduce(0, +)
        return totalSeconds / 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Screen Time")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // Day navigation + total
            ZStack {
                HStack {
                    if selectedDayTotalMinutes > 0 {
                        let h = selectedDayTotalMinutes / 60
                        let m = selectedDayTotalMinutes % 60
                        Text(h > 0 ? "\(h)h \(m)m" : "\(m)m")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }

                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            dayOffset = max(dayOffset - 1, -6)
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
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(dayOffset < 0 ? Color.blue : Color.gray.opacity(0.3))
                    }
                    .disabled(dayOffset >= 0)
                }
            }

            let slots = selectedDaySlots
            if slots.isEmpty {
                Text("No screen time data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                // Heatmap bar — each slot colored by intensity
                let maxSlotSecs = max(1, slots.values.max() ?? 1)
                let isToday = dayOffset == 0
                let currentSlot: Int = {
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
                    return DomainHit.slotIndex(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
                }()

                HStack(spacing: 1) {
                    ForEach(0..<96, id: \.self) { s in
                        let secs = slots[s] ?? 0
                        let intensity = secs > 0 ? max(0.2, CGFloat(secs) / CGFloat(maxSlotSecs)) : 0
                        let isFuture = isToday && s > currentSlot

                        RoundedRectangle(cornerRadius: 1)
                            .fill(secs > 0 ? Color.orange.opacity(intensity) : Color.clear)
                            .frame(height: 20)
                            .opacity(isFuture ? 0.2 : 1)
                    }
                }
                .frame(height: 20)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))

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

                // Hourly breakdown: 4 columns (12a-noon + time, noon-midnight + time)
                let hourlyMinutes = hourlyBreakdown(slots)
                if hourlyMinutes.contains(where: { $0 > 0 }) {
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        // AM column (12am - 11am)
                        VStack(spacing: 2) {
                            ForEach(0..<12, id: \.self) { h in
                                hourRow(hour: h, minutes: hourlyMinutes[h])
                            }
                        }
                        // PM column (12pm - 11pm)
                        VStack(spacing: 2) {
                            ForEach(12..<24, id: \.self) { h in
                                hourRow(hour: h, minutes: hourlyMinutes[h])
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
    }

    // MARK: - Helpers

    /// Aggregate 15-min slots into 24 hourly buckets (minutes per hour).
    private func hourlyBreakdown(_ slots: [Int: Int]) -> [Int] {
        var hours = [Int](repeating: 0, count: 24)
        for (slot, secs) in slots {
            let h = min(slot / 4, 23)
            hours[h] += secs
        }
        return hours.map { $0 / 60 } // convert seconds to minutes
    }

    /// Single hour row: "9 AM  12m" with a subtle bar
    @ViewBuilder
    private func hourRow(hour: Int, minutes: Int) -> some View {
        let label: String = {
            if hour == 0 { return "12a" }
            if hour < 12 { return "\(hour)a" }
            if hour == 12 { return "12p" }
            return "\(hour - 12)p"
        }()
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            if minutes > 0 {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange.opacity(min(1, Double(minutes) / 60 * 1.5 + 0.2)))
                    .frame(width: max(4, CGFloat(minutes) / 60 * 60), height: 10)
                Text("\(minutes)m")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 14)
    }
}
