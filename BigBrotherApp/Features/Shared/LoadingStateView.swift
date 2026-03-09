import SwiftUI

enum ViewLoadingState<T> {
    case idle
    case loading
    case loaded(T)
    case empty(String)
    case error(String)
}

struct LoadingStateView<T, Content: View>: View {
    let state: ViewLoadingState<T>
    let content: (T) -> Content

    init(state: ViewLoadingState<T>, @ViewBuilder content: @escaping (T) -> Content) {
        self.state = state
        self.content = content
    }

    var body: some View {
        switch state {
        case .idle:
            Color.clear
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let data):
            content(data)
        case .empty(let message):
            ContentUnavailableView(
                message,
                systemImage: "tray",
                description: Text("Nothing to show yet.")
            )
        case .error(let message):
            ContentUnavailableView {
                Label("Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }
}
