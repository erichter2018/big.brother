import SwiftUI
import Charts

/// 7-day screen time bar chart using Swift Charts.
struct ScreenTimeTrendChart: View {
    let dailyMinutes: [(date: Date, minutes: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen Time")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            let hasData = dailyMinutes.contains { $0.minutes > 0 }
            if dailyMinutes.isEmpty || !hasData {
                Text("No screen time data yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 60)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(dailyMinutes, id: \.date) { entry in
                        BarMark(
                            x: .value("Day", entry.date, unit: .day),
                            y: .value("Minutes", entry.minutes)
                        )
                        .foregroundStyle(Calendar.current.isDateInToday(entry.date) ? Color.orange : Color.orange.opacity(0.4))
                        .cornerRadius(3)
                    }
                    if !dailyMinutes.isEmpty {
                        let avg = dailyMinutes.map(\.minutes).reduce(0, +) / max(1, dailyMinutes.count)
                        RuleMark(y: .value("Average", avg))
                            .foregroundStyle(.orange.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("avg \(Self.formatMinutes(avg))")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(Self.weekdayLabel(date))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let mins = value.as(Int.self) {
                                Text(Self.formatMinutes(mins))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .frame(height: 120)
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
        if h > 0 && m > 0 { return "\(h)h\(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}
