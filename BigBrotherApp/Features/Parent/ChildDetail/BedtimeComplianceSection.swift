import SwiftUI
import BigBrotherCore

/// Shows bedtime compliance for the last 7 days — did the child use their device after bedtime?
struct BedtimeComplianceSection: View {
    let compliance: [String: BedtimeComplianceResult]
    let weeklyScreenTime: [(date: Date, minutes: Int)]

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    var body: some View {
        guard !compliance.isEmpty else { return AnyView(EmptyView()) }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Last 7 days, most recent first
        let days: [(dateStr: String, date: Date)] = (0..<7).compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (Self.dateFmt.string(from: date), date)
        }

        // Only show if we have at least one day with compliance data
        let daysWithData = days.filter { compliance[$0.dateStr] != nil }
        guard !daysWithData.isEmpty else { return AnyView(EmptyView()) }

        let violations = daysWithData.filter { !(compliance[$0.dateStr]?.isCompliant ?? true) }

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text("Bedtime Compliance")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if violations.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 14))
                        Text("No screen activity after bedtime")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(violations, id: \.dateStr) { day in
                        if let result = compliance[day.dateStr], !result.isCompliant {
                            HStack(spacing: 6) {
                                Image(systemName: "moon.fill")
                                    .foregroundStyle(.orange)
                                    .font(.system(size: 10))

                                let dayLabel = cal.isDateInToday(day.date) ? "Today" :
                                    cal.isDateInYesterday(day.date) ? "Yesterday" :
                                    Self.displayFmt.string(from: day.date)

                                Text(dayLabel)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .frame(width: 65, alignment: .leading)

                                Text("\(result.minutesAfterBedtime)m after \(result.bedtimeLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)

                                Spacer()
                            }
                        }
                    }
                }

                // 7-day dot summary
                HStack(spacing: 4) {
                    ForEach(days.reversed(), id: \.dateStr) { day in
                        let result = compliance[day.dateStr]
                        let hasData = result != nil
                        let compliant = result?.isCompliant ?? true

                        VStack(spacing: 2) {
                            Circle()
                                .fill(hasData ? (compliant ? Color.green : Color.orange) : Color.secondary.opacity(0.2))
                                .frame(width: 8, height: 8)
                            Text(Self.displayFmt.string(from: day.date).prefix(1))
                                .font(.system(size: 7))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            .padding(12)
            .if_iOS26GlassEffect(fallbackMaterial: .ultraThinMaterial, borderColor: .secondary)
        )
    }
}
