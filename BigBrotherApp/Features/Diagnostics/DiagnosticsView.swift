import SwiftUI
import BigBrotherCore

struct DiagnosticsView: View {
    @Bindable var viewModel: DiagnosticsViewModel

    var body: some View {
        List {
            // Snapshot summary
            snapshotSection

            // Authorization health
            authorizationSection

            // Heartbeat status
            heartbeatSection

            // Extension shared state
            extensionStateSection

            // Snapshot history
            snapshotHistorySection

            // Diagnostic log entries
            diagnosticLogSection
        }
        .navigationTitle("Diagnostics")
        .onAppear { viewModel.load() }
        .refreshable { viewModel.load() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var snapshotSection: some View {
        Section("Current Snapshot") {
            if let snap = viewModel.currentSnapshot {
                infoRow("Snapshot ID", snap.snapshotID.uuidString.prefix(8))
                infoRow("Generation", "\(snap.generation)")
                infoRow("Mode", snap.effectivePolicy.resolvedMode.displayName)
                infoRow("Policy Version", "\(snap.effectivePolicy.policyVersion)")
                infoRow("Source", snap.source.rawValue)
                infoRow("Created", snap.createdAt.formatted(.dateTime))
                if let applied = snap.appliedAt {
                    infoRow("Applied", applied.formatted(.dateTime))
                }
                infoRow("Temp Unlock", snap.effectivePolicy.isTemporaryUnlock ? "Yes" : "No")
                infoRow("Fingerprint", snap.policyFingerprint)
                if !snap.effectivePolicy.warnings.isEmpty {
                    infoRow("Warnings", snap.effectivePolicy.warnings.map(\.rawValue).joined(separator: ", "))
                }
            } else {
                Text("No snapshot available")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var authorizationSection: some View {
        Section("Authorization Health") {
            if let auth = viewModel.authorizationHealth {
                infoRow("State", auth.currentState.rawValue)
                infoRow("Authorized", auth.isAuthorized ? "Yes" : "No")
                infoRow("Last Transition", auth.lastTransitionAt.formatted(.dateTime))
                if let prev = auth.previousState {
                    infoRow("Previous State", prev.rawValue)
                }
                infoRow("Degraded", auth.enforcementDegraded ? "Yes" : "No")
            } else {
                Text("No authorization health data")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var heartbeatSection: some View {
        Section("Heartbeat Status") {
            if let hb = viewModel.heartbeatStatus {
                infoRow("Healthy", hb.isHealthy ? "Yes" : "No")
                if let last = hb.lastSuccessAt {
                    infoRow("Last Success", last.formatted(.dateTime))
                }
                if let attempt = hb.lastAttemptAt {
                    infoRow("Last Attempt", attempt.formatted(.dateTime))
                }
                infoRow("Consecutive Failures", "\(hb.consecutiveFailures)")
                if let reason = hb.lastFailureReason {
                    infoRow("Last Failure", reason)
                }
            } else {
                Text("No heartbeat status data")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var extensionStateSection: some View {
        Section("Extension Shared State") {
            if let ext = viewModel.extensionSharedState {
                infoRow("Mode", ext.currentMode.displayName)
                infoRow("Temp Unlock", ext.isTemporaryUnlock ? "Yes" : "No")
                infoRow("Auth Available", ext.authorizationAvailable ? "Yes" : "No")
                infoRow("Degraded", ext.enforcementDegraded ? "Yes" : "No")
                infoRow("Policy Version", "\(ext.policyVersion)")
                infoRow("Written", ext.writtenAt.formatted(.dateTime))
            } else {
                Text("No extension state data")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var snapshotHistorySection: some View {
        Section("Snapshot History (\(viewModel.snapshotHistory.count))") {
            if viewModel.snapshotHistory.isEmpty {
                Text("No transitions recorded")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.snapshotHistory.reversed()) { transition in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Gen \(transition.fromGeneration) → \(transition.toGeneration)")
                                .font(.caption.monospaced())
                            Spacer()
                            Text(transition.source.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if transition.fromMode != transition.toMode {
                            Text("\(transition.fromMode.displayName) → \(transition.toMode.displayName)")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        ForEach(transition.changes, id: \.self) { change in
                            Text(change)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(transition.timestamp.formatted(.dateTime))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticLogSection: some View {
        Section {
            Picker("Category", selection: $viewModel.selectedCategory) {
                Text("All").tag(nil as DiagnosticCategory?)
                ForEach(DiagnosticCategory.allCases, id: \.self) { cat in
                    Text(cat.rawValue.capitalized).tag(cat as DiagnosticCategory?)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: viewModel.selectedCategory) { _, newValue in
                viewModel.filterByCategory(newValue)
            }
        } header: {
            Text("Diagnostic Log (\(viewModel.diagnosticEntries.count))")
        }

        Section {
            if viewModel.diagnosticEntries.isEmpty {
                Text("No entries")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.diagnosticEntries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.category.rawValue)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.blue)
                            Spacer()
                            Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .font(.caption)
                        if let details = entry.details {
                            Text(details)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - Helper

    @ViewBuilder
    private func infoRow(_ label: String, _ value: some StringProtocol) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}
