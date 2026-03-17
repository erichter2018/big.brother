import SwiftUI
import BigBrotherCore

/// Drag-to-reorder view for child profiles on the dashboard.
struct ChildOrderView: View {
    let appState: AppState
    @State private var orderedChildren: [ChildProfile] = []

    var body: some View {
        List {
            ForEach(orderedChildren) { child in
                HStack {
                    Text(String(child.name.prefix(1)).uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.tint))
                    Text(child.name)
                        .font(.body)
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                }
            }
            .onMove { from, to in
                orderedChildren.move(fromOffsets: from, toOffset: to)
                appState.childOrder = orderedChildren.map(\.id)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Reorder Children")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            orderedChildren = appState.orderedChildProfiles
        }
    }
}
