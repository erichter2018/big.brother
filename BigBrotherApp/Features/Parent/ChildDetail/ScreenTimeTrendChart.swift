import SwiftUI
import Charts

/// 7-day screen time bar chart using Swift Charts.
/// Supports week navigation (Sunday start) with up to 16 weeks of history.
struct ScreenTimeTrendChart: View {
    let dailyMinutes: [(date: Date, minutes: Int)]
    @State private var weekOffset: Int = 0

    private var weekData: [(date: Date, minutes: Int)] {
        let cal = Calendar.current
        // Find the Sunday of the current offset week
        let today = Date()
        guard let targetWeekStart = cal.date(byAdding: .weekOfYear, value: weekOffset, to: today) else {
            return dailyMinutes
        }
        // Find the Sunday of that week
        let weekday = cal.component(.weekday, from: targetWeekStart) // 1=Sun
        guard let sunday = cal.date(byAdding: .day, value: -(weekday - 1), to: targetWeekStart) else {
            return dailyMinutes
        }
        guard let saturday = cal.date(byAdding: .day, value: 6, to: sunday) else {
            return dailyMinutes
        }

        let sundayStart = cal.startOfDay(for: sunday)
        let saturdayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: saturday))!

        return dailyMinutes.filter { $0.date >= sundayStart && $0.date < saturdayEnd }
            .sorted { $0.date < $1.date }
    }

    private var weekLabel: String {
        if weekOffset == 0 { return "This Week" }
        if weekOffset == -1 { return "Last Week" }
        let cal = Calendar.current
        guard let date = cal.date(byAdding: .weekOfYear, value: weekOffset, to: Date()) else { return "" }
        let weekday = cal.component(.weekday, from: date)
        guard let sunday = cal.date(byAdding: .day, value: -(weekday - 1), to: date) else { return "" }
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
        return "Week of \(fmt.string(from: sunday))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header with daily average
            let daysWithData = weekData.filter { $0.minutes > 0 }
            let avg = daysWithData.isEmpty ? 0 : daysWithData.map(\.minutes).reduce(0, +) / daysWithData.count

            HStack {
                Text("Daily Screen Time")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if avg > 0 {
                    Text("avg \(Self.formatMinutes(avg))/day")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            // Week navigation
            ZStack {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            weekOffset = max(weekOffset - 1, -15)
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(weekOffset > -15 ? Color.blue : Color.gray.opacity(0.3))
                    }
                    .disabled(weekOffset <= -15)

                    Text(weekLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(width: 120)

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            weekOffset = min(weekOffset + 1, 0)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(weekOffset < 0 ? Color.blue : Color.gray.opacity(0.3))
                    }
                    .disabled(weekOffset >= 0)
                }
            }

            let data = weekData
            let hasData = data.contains { $0.minutes > 0 }
            if data.isEmpty || !hasData {
                Text("No screen time data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 60)
                    .frame(maxWidth: .infinity)
            } else {
                let maxMins = data.map(\.minutes).max() ?? 0

                Chart {
                    ForEach(data, id: \.date) { entry in
                        BarMark(
                            x: .value("Day", entry.date, unit: .day),
                            y: .value("Minutes", entry.minutes)
                        )
                        .foregroundStyle(Calendar.current.isDateInToday(entry.date) ? Color.orange : Color.orange.opacity(0.35))
                        .cornerRadius(4)
                        .annotation(position: .top, spacing: 2) {
                            if entry.minutes > 0 {
                                Text(Self.formatMinutes(entry.minutes))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if avg > 0 {
                        RuleMark(y: .value("Average", avg))
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .annotation(position: avg < maxMins / 2 ? .top : .bottom, alignment: .leading) {
                                Text("avg \(Self.formatMinutes(avg))")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(Self.weekdayLabel(date))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Calendar.current.isDateInToday(date) ? .primary : .secondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                            .foregroundStyle(.secondary.opacity(0.3))
                        AxisValueLabel {
                            if let mins = value.as(Int.self) {
                                Text(Self.formatMinutes(mins))
                                    .font(.system(size: 10))
                            }
                        }
                    }
                }
                .frame(height: 140)
            }
        }
        .padding(12)
        .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
    }

    static func weekdayLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.isDateInToday(date) ? "'Today'" : "EEE"
        return fmt.string(from: date)
    }

    static func formatMinutes(_ mins: Int) -> String {
        let h = mins / 60, m = mins % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}
