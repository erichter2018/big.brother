#if DEBUG
import SwiftUI
import FamilyControls
import ManagedSettings

/// Diagnostic view that tests whether shield.applications works.
/// Uses a separate named store ("diagTest") so it doesn't interfere with enforcement.
struct ShieldApplicationsTestView: View {
    @State private var selection = FamilyActivitySelection()
    @State private var log: [String] = []
    @Environment(\.dismiss) private var dismiss

    private let testStore = ManagedSettingsStore(named: .init("diagTest"))

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Pick 2-3 apps, tap Run Test. Check console.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                FamilyActivityPicker(selection: $selection)
                    .frame(maxHeight: 300)

                Button("Run Test") { runTest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.applicationTokens.isEmpty)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(log, id: \.self) { line in
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
                        testStore.clearAllSettings()
                        dismiss()
                    }
                }
            }
        }
    }

    private func runTest() {
        log.removeAll()
        let tokens = selection.applicationTokens
        emit("Selected \(tokens.count) app tokens, \(selection.categoryTokens.count) category tokens")

        // 1. Clear test store.
        testStore.clearAllSettings()
        emit("Cleared test store")

        // 2. Assign shield.applications ONLY (no categories).
        testStore.shield.applications = tokens
        emit("Assigned \(tokens.count) tokens to shield.applications")

        // 3. Read back immediately.
        let readBack = testStore.shield.applications
        let readCount = readBack?.count ?? -1
        emit("Read back shield.applications: \(readCount == -1 ? "nil" : "\(readCount)") tokens")

        if readCount == tokens.count {
            emit("SUCCESS — shield.applications accepted all \(tokens.count) tokens")
        } else if readCount == -1 {
            emit("FAILED — shield.applications returned nil (silently rejected)")
        } else {
            emit("PARTIAL — assigned \(tokens.count) but read back \(readCount)")
        }

        // 4. Also test with applicationCategories to compare.
        testStore.shield.applicationCategories = .all()
        let catRead = testStore.shield.applicationCategories
        emit("Category test: set .all(), read back: \(catRead != nil ? "present" : "nil")")

        // 5. Clean up — clear test store so it doesn't interfere.
        testStore.clearAllSettings()
        emit("Test store cleared. Check if test apps were briefly blocked.")

        // Print all to console.
        for line in log {
            print("[BigBrother] [shield.apps test] \(line)")
        }
    }

    private func emit(_ msg: String) {
        log.append(msg)
    }
}
#endif
