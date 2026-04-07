import SwiftUI
import BigBrotherCore

/// Modal for customizing dashboard element visibility and child order.
struct DashboardLayoutView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var orderedChildren: [ChildProfile] = []
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orderedChildren) { child in
                        HStack(spacing: 12) {
                            Text(String(child.name.prefix(1)).uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(.tint))
                            Text(child.name)
                                .font(.body)
                            Spacer()
                        }
                    }
                    .onMove { from, to in
                        orderedChildren.move(fromOffsets: from, toOffset: to)
                        appState.childOrder = orderedChildren.map(\.id)
                    }
                } header: {
                    Text("Child Order")
                } footer: {
                    Text("Drag to reorder how children appear on the dashboard.")
                }

                Section("Visibility") {
                    Toggle(isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "familyPauseEnabled") },
                        set: { UserDefaults.standard.set($0, forKey: "familyPauseEnabled") }
                    )) {
                        Label("Pause All Button", systemImage: "pause.circle")
                    }
                }

                Section {
                    Button("Reset Order to Default") {
                        appState.childOrder = []
                        orderedChildren = appState.orderedChildProfiles
                    }
                    .foregroundStyle(.red)
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .navigationTitle("Dashboard Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                orderedChildren = appState.orderedChildProfiles
            }
        }
    }
}
