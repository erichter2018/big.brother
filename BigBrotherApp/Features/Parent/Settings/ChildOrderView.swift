import SwiftUI
import BigBrotherCore

/// Drag-to-reorder view for child profiles on the dashboard.
struct ChildOrderView: View {
    let appState: AppState
    @State private var orderedChildren: [ChildProfile] = []
    @State private var editMode: EditMode = .active

    var body: some View {
        List {
            Section {
                ForEach(orderedChildren) { child in
                    HStack(spacing: 12) {
                        Text(String(child.name.prefix(1)).uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
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
            } footer: {
                Text("Drag to reorder how children appear on the dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to Default") {
                    appState.childOrder = []
                    orderedChildren = appState.orderedChildProfiles
                }
                .foregroundStyle(.red)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .navigationTitle("Reorder Children")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            orderedChildren = appState.orderedChildProfiles
        }
    }
}
