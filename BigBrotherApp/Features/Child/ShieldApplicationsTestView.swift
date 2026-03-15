#if DEBUG
import SwiftUI
import FamilyControls
import ManagedSettings

/// Diagnostic view that tests shield.applications behavior.
/// Tests single-store, multi-store splitting, and the 50-token limit.
struct ShieldApplicationsTestView: View {
    @State private var selection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var log: [String] = []
    @Environment(\.dismiss) private var dismiss

    private let testStores = (0..<4).map {
        ManagedSettingsStore(named: .init("diagTest\($0)"))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Select apps (try all categories for >50), tap a test.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                FamilyActivityPicker(selection: $selection)
                    .frame(maxHeight: 250)

                HStack(spacing: 8) {
                    Button("Single Store") { runSingleStoreTest() }
                        .buttonStyle(.borderedProminent)
                    Button("Multi Store") { runMultiStoreTest() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    Button("Clear") {
                        clearAllTestStores()
                        emit("All test stores cleared")
                        printLog()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .disabled(selection.applicationTokens.isEmpty)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
            }
            .navigationTitle("shield.applications Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        clearAllTestStores()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Single Store Test

    private func runSingleStoreTest() {
        log.removeAll()
        clearAllTestStores()
        let tokens = selection.applicationTokens
        emit("=== SINGLE STORE TEST ===")
        emit("Total tokens: \(tokens.count)")

        let store = testStores[0]
        store.shield.applications = tokens
        let readBack = store.shield.applications
        let readCount = readBack?.count ?? -1

        emit("Assigned \(tokens.count) → read back \(readCount == -1 ? "nil" : "\(readCount)")")

        if readCount == tokens.count {
            emit("SUCCESS — all \(tokens.count) accepted in one store")
        } else if readCount == -1 {
            emit("FAILED — nil (50-token limit hit with \(tokens.count) tokens)")
        } else {
            emit("PARTIAL — \(readCount)/\(tokens.count)")
        }

        clearAllTestStores()
        printLog()
    }

    // MARK: - Multi Store Test

    private func runMultiStoreTest() {
        log.removeAll()
        clearAllTestStores()
        let allTokens = Array(selection.applicationTokens)
        emit("=== MULTI STORE TEST ===")
        emit("Total tokens: \(allTokens.count), using \(testStores.count) stores (50 each)")

        let chunkSize = 50
        var totalAccepted = 0

        for (i, store) in testStores.enumerated() {
            let start = i * chunkSize
            guard start < allTokens.count else { break }
            let end = min(start + chunkSize, allTokens.count)
            let chunk = Set(allTokens[start..<end])

            store.shield.applications = chunk
            let readBack = store.shield.applications
            let readCount = readBack?.count ?? -1

            emit("Store \(i): assigned \(chunk.count) → read back \(readCount == -1 ? "nil" : "\(readCount)")")
            if readCount > 0 { totalAccepted += readCount }
        }

        emit("")
        if totalAccepted == allTokens.count {
            emit("SUCCESS — all \(allTokens.count) tokens accepted across stores")
        } else {
            emit("RESULT — \(totalAccepted)/\(allTokens.count) tokens accepted")
        }

        emit("Shields ACTIVE — go try opening a selected app, then come back and tap Clear")
        printLog()
    }

    // MARK: - Helpers

    private func clearAllTestStores() {
        for store in testStores {
            store.clearAllSettings()
        }
    }

    private func emit(_ msg: String) {
        log.append(msg)
    }

    private func printLog() {
        for line in log {
            print("[BigBrother] [shield.apps test] \(line)")
        }
    }
}
#endif
