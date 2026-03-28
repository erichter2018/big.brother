import SwiftUI
import BigBrotherCore

/// First-launch screen. Feature tour followed by role selection.
struct OnboardingView: View {
    let appState: AppState

    @State private var showParentSetup = false
    @State private var showParentJoin = false
    @State private var showChildEnrollment = false
    @State private var currentPage = 0

    private let featurePages: [(icon: String, title: String, subtitle: String)] = [
        ("figure.2.and.child.holdinghands", "Welcome to Big Brother", "Screen time management built for real families."),
        ("calendar.badge.clock", "Smart Schedules", "Set daily routines with free time windows, locked periods, and essential-only mode — per child."),
        ("lock.shield", "Instant Control", "Lock or unlock any device in seconds. Kids can request more time right from the blocked screen."),
        ("bell.badge", "Real-Time Dashboard", "See every device at a glance — battery, status, and what mode they're in, all in one place."),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Feature tour pages
                TabView(selection: $currentPage) {
                    ForEach(featurePages.indices, id: \.self) { index in
                        featurePage(featurePages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: currentPage)

                // Page dots
                HStack(spacing: 8) {
                    ForEach(featurePages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Color.blue : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.bottom, 24)

                // Role selection (always visible below the tour)
                VStack(spacing: 12) {
                    Button {
                        showParentSetup = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.badge.shield.checkmark")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Set Up as Parent")
                                    .fontWeight(.semibold)
                                Text("Create a new family")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Set up as parent. Create a new family.")

                    Button {
                        showParentJoin = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.2.badge.key")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Join as Parent")
                                    .fontWeight(.semibold)
                                Text("Enter code from existing parent")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Join as parent. Enter code from existing parent.")

                    Button {
                        showChildEnrollment = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "iphone")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Set Up Child's Device")
                                    .fontWeight(.semibold)
                                Text("Enter the code shown on the parent's device")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Set up child's device. Enter the code shown on the parent's device.")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationDestination(isPresented: $showParentSetup) {
                ParentSetupView(appState: appState)
            }
            .navigationDestination(isPresented: $showParentJoin) {
                ParentJoinView(appState: appState)
            }
            .navigationDestination(isPresented: $showChildEnrollment) {
                EnrollmentCodeEntryView(appState: appState)
            }
        }
    }

    @ViewBuilder
    private func featurePage(_ page: (icon: String, title: String, subtitle: String)) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: page.icon)
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            Text(page.title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text(page.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(page.title). \(page.subtitle)")
    }
}
