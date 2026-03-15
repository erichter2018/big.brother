import SwiftUI
import DeviceActivity
import ManagedSettings
import BigBrotherCore
import os.log

private let logger = Logger(subsystem: "fr.bigbrother.app.activity-report", category: "NameResolver")

@main
struct BigBrotherActivityReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        TokenProbeReportScene { configuration in
            TokenProbeContentView(configuration: configuration)
        }
        NameResolverScene { configuration in
            NameResolverContentView(configuration: configuration)
        }
    }
}

struct TokenProbeReportConfiguration: Equatable {
    let lines: [String]
}

struct TokenProbeReportScene: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .init("fr.bigbrother.activity-report.token-probe")
    let content: (TokenProbeReportConfiguration) -> TokenProbeContentView
    private let storage = AppGroupStorage()

    func makeConfiguration(
        representing data: DeviceActivityResults<DeviceActivityData>
    ) async -> TokenProbeReportConfiguration {
        var lines: [String] = []
        var seenFingerprints = Set<String>()

        for await activityData in data {
            for await segment in activityData.activitySegments {
                for await category in segment.categories {
                    for await application in category.applications {
                        guard let token = application.application.token else { continue }
                        let fingerprint = Self.tokenFingerprint(for: token)
                        guard seenFingerprints.insert(fingerprint).inserted else { continue }

                        let resolvedName = Self.resolvedName(
                            localizedName: application.application.localizedDisplayName,
                            bundleIdentifier: application.application.bundleIdentifier,
                            fallbackData: (try? JSONEncoder().encode(token)) ?? Data()
                        )
                        lines.append(
                            "resolved token=\(fingerprint) name=\(resolvedName) total=\(Int(application.totalActivityDuration))s"
                        )
                    }
                }
            }
        }

        if lines.isEmpty {
            lines.append("report produced no application activity")
        }

        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .activityReport,
            message: "name resolver report rendered \(seenFingerprints.count) unique app(s)"
        ))
        logger.info("activity report rendered \(seenFingerprints.count) unique app(s)")

        return TokenProbeReportConfiguration(lines: lines)
    }

    static func tokenFingerprint(for token: ApplicationToken) -> String {
        guard let data = try? JSONEncoder().encode(token) else {
            return "encode-failed"
        }
        return tokenFingerprint(for: data)
    }

    static func tokenFingerprint(for data: Data) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    static func resolvedName(
        localizedName: String?,
        bundleIdentifier: String?,
        fallbackData: Data
    ) -> String {
        if let localizedName {
            let trimmed = localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsefulAppName(trimmed) {
                return trimmed
            }
        }
        if let component = bundleIdentifier?.split(separator: ".").last {
            let candidate = String(component)
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .capitalized
            if isUsefulAppName(candidate) {
                return candidate
            }
        }
        return "Blocked App \(tokenFingerprint(for: fallbackData).prefix(8))"
    }

    static func isUsefulAppName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !normalized.isEmpty &&
            normalized != "app" &&
            normalized != "an app" &&
            normalized != "unknown" &&
            normalized != "unknown app" &&
            !normalized.contains("token(") &&
            !normalized.contains("data:") &&
            !normalized.contains("bytes)")
    }
}

struct ResolvedApp: Equatable, Hashable {
    let fingerprint: String
    let name: String
}

struct NameResolverConfiguration: Equatable {
    let resolvedCount: Int
    let usefulCount: Int
    let apps: [ResolvedApp]
}

struct NameResolverScene: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .init("fr.bigbrother.name-resolver")
    let content: (NameResolverConfiguration) -> NameResolverContentView
    private let storage = AppGroupStorage()

    func makeConfiguration(
        representing data: DeviceActivityResults<DeviceActivityData>
    ) async -> NameResolverConfiguration {
        var resolvedCount = 0
        var usefulCount = 0
        var seenNames = Set<String>()
        var apps: [ResolvedApp] = []

        for await activityData in data {
            for await segment in activityData.activitySegments {
                for await category in segment.categories {
                    for await application in category.applications {
                        guard let token = application.application.token,
                              let tokenData = try? JSONEncoder().encode(token) else { continue }

                        let resolvedName = TokenProbeReportScene.resolvedName(
                            localizedName: application.application.localizedDisplayName,
                            bundleIdentifier: application.application.bundleIdentifier,
                            fallbackData: tokenData
                        )
                        if TokenProbeReportScene.isUsefulAppName(resolvedName),
                           seenNames.insert(resolvedName).inserted {
                            apps.append(ResolvedApp(
                                fingerprint: String(TokenProbeReportScene.tokenFingerprint(for: tokenData).prefix(8)),
                                name: resolvedName
                            ))
                            usefulCount += 1
                        }
                        resolvedCount += 1
                    }
                }
            }
        }

        apps.sort { $0.name < $1.name }
        try? storage.appendDiagnosticEntry(DiagnosticEntry(
            category: .activityReport,
            message: "display-only report resolved \(usefulCount)/\(resolvedCount) app names"
        ))
        logger.info("display-only report resolved \(usefulCount)/\(resolvedCount) app names")

        return NameResolverConfiguration(
            resolvedCount: resolvedCount,
            usefulCount: usefulCount,
            apps: apps
        )
    }
}

struct NameResolverContentView: View {
    let configuration: NameResolverConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(.blue)
                Text("Your App Activity")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(configuration.usefulCount) identified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if configuration.apps.isEmpty {
                Text("Activity data populates as apps are used.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(configuration.apps, id: \.fingerprint) { app in
                        Text(app.name)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding()
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}

struct TokenProbeContentView: View {
    let configuration: TokenProbeReportConfiguration

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(configuration.lines.indices), id: \.self) { index in
                    Text(configuration.lines[index])
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }
}
