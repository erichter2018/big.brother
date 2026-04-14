import SwiftUI
import BigBrotherCore

/// Parent-facing section showing apps the child selected that need review.
/// Each app can be: allowed always, given a time limit, or kept blocked.
///
/// Names cannot be resolved automatically — ShieldConfiguration (the only process
/// that can read app names) cannot write to ANY persistent storage. The child sees
/// the name on the shield and tells the parent, who names them here.
struct PendingAppReviewSection: View {
    @Bindable var viewModel: ChildDetailViewModel
    @State private var showBulkNaming = false

    private var unnamedCount: Int {
        viewModel.pendingAppReviews.filter { !$0.nameResolved }.count
    }

    @ViewBuilder
    private func highlightBackground(for id: UUID) -> some View {
        if viewModel.appState.highlightedReviewID == id {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.25))
                .transition(.opacity)
        }
    }

    var body: some View {
        if !viewModel.pendingAppReviews.isEmpty {
            Section {
                ScrollViewReader { proxy in
                    ForEach(viewModel.pendingAppReviews) { review in
                        reviewRow(review)
                            .id(review.id)
                            .background(
                                highlightBackground(for: review.id)
                            )
                    }
                    .onChange(of: viewModel.appState.highlightedReviewID) { _, newID in
                        guard let id = newID else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                        // Auto-clear the highlight after a short flash.
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            await MainActor.run {
                                if viewModel.appState.highlightedReviewID == id {
                                    viewModel.appState.highlightedReviewID = nil
                                }
                            }
                        }
                    }
                    .onAppear {
                        if let id = viewModel.appState.highlightedReviewID {
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            } header: {
                HStack {
                    Label("Pending App Review", systemImage: "hand.raised")
                    Spacer()
                    if unnamedCount > 0 {
                        Button {
                            showBulkNaming = true
                        } label: {
                            Text("Name Apps")
                                .font(.caption2)
                        }
                    }
                    Button {
                        Task { await viewModel.clearAllPendingReviews() }
                    } label: {
                        Text("Clear")
                            .font(.caption2)
                    }
                    Text("\(viewModel.pendingAppReviews.count)")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.blue)
                        .clipShape(Capsule())
                }
            } footer: {
                Text("Ask the child what each app is — they see the real name on their screen.")
                    .font(.caption2)
            }
            .sheet(isPresented: $showBulkNaming) {
                BulkAppNamingSheet(viewModel: viewModel)
            }
        }
    }

    @ViewBuilder
    private func reviewRow(_ review: PendingAppReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(review.appName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(review.nameResolved ? .primary : .secondary)
                if !review.nameResolved {
                    Text("unnamed")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if viewModel.isPreviouslyBlocked(review) {
                    Text("previously blocked")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Spacer()
            }

            // Quick actions — only show for named apps
            if review.nameResolved {
                HStack(spacing: 6) {
                    Button {
                        Task { await viewModel.reviewApp(review, disposition: .allowAlways) }
                    } label: {
                        Text("Allow")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.green.opacity(0.15)))
                    }
                    .buttonStyle(.plain)

                    Menu {
                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { mins in
                            Button("\(mins) min/day") {
                                Task { await viewModel.reviewApp(review, disposition: .timeLimit, minutes: mins) }
                            }
                        }
                    } label: {
                        Text("Limit")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.blue.opacity(0.15)))
                    }

                    Button {
                        Task { await viewModel.reviewApp(review, disposition: .keepBlocked) }
                    } label: {
                        Text("Block")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.red.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Bulk naming sheet — parent types all app names at once.
/// The child sees real names on their shield screen and tells the parent.
struct BulkAppNamingSheet: View {
    @Bindable var viewModel: ChildDetailViewModel
    @State private var names: [UUID: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private var unnamed: [PendingAppReview] {
        viewModel.pendingAppReviews.filter { !$0.nameResolved }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Ask your child what each app is — they see the real name when they tap a blocked app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Apps to Name") {
                    ForEach(Array(unnamed.enumerated()), id: \.element.id) { index, review in
                        HStack {
                            Text(review.appName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .leading)
                            TextField("App name", text: binding(for: review.id))
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .submitLabel(index < unnamed.count - 1 ? .next : .done)
                        }
                    }
                }
            }
            .navigationTitle("Name Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            for review in unnamed {
                                if let name = names[review.id], !name.trimmingCharacters(in: .whitespaces).isEmpty {
                                    await viewModel.renameReview(review, newName: name.trimmingCharacters(in: .whitespaces))
                                }
                            }
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { names[id] ?? "" },
            set: { names[id] = $0 }
        )
    }
}
