import SwiftUI
import BigBrotherCore

/// Activity feed showing safety events, geofence transitions, and system events.
struct ActivityFeedView: View {
    @Bindable var viewModel: ActivityFeedViewModel

    var body: some View {
        List {
            // Filter section — pinned at top of list, not a separate VStack
            Section {
                filterBar
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color(.systemGroupedBackground))
            }

            // Events grouped by day
            if viewModel.isLoading && viewModel.events.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading events...")
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
            } else if viewModel.events.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Activity", systemImage: "bell.slash")
                    } description: {
                        Text("Events will appear here as children use their devices.")
                    }
                    .listRowSeparator(.hidden)
                }
            } else {
                ForEach(viewModel.groupedByDay, id: \.date) { group in
                    Section {
                        ForEach(group.events) { event in
                            eventRow(event)
                        }
                    } header: {
                        Text(group.label)
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .task {
            await viewModel.loadEvents()
            viewModel.markAsViewed()
        }
        .refreshable {
            await viewModel.loadEvents()
        }
    }

    // MARK: - Filter Bar

    @ViewBuilder
    private var filterBar: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    childFilterChip(name: "All", id: nil)
                    ForEach(viewModel.sortedChildProfiles) { profile in
                        childFilterChip(name: profile.name, id: profile.id)
                    }
                }
                .padding(.horizontal, 16)
            }

            Picker("Filter", selection: $viewModel.selectedFilter) {
                ForEach(ActivityFeedViewModel.EventFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .onChange(of: viewModel.selectedFilter) { _, _ in
            Task { await viewModel.loadEvents() }
        }
    }

    @ViewBuilder
    private func childFilterChip(name: String, id: ChildProfileID?) -> some View {
        let selected = viewModel.selectedChildID == id
        Button {
            viewModel.selectedChildID = id
            Task { await viewModel.loadEvents() }
        } label: {
            Text(name)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.blue : Color(.tertiarySystemFill))
                .foregroundStyle(selected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Event Row

    @ViewBuilder
    private func eventRow(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.icon)
                .font(.system(size: 13))
                .foregroundStyle(event.tintColor)
                .frame(width: 26, height: 26)
                .background(event.tintColor.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                if let detail = event.meaningfulDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Text(event.timeOnly)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
