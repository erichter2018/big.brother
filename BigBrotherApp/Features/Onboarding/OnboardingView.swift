import SwiftUI
import BigBrotherCore

/// First-launch screen. The user chooses to set up as a parent or enroll as a child.
struct OnboardingView: View {
    let appState: AppState

    @State private var showParentSetup = false
    @State private var showChildEnrollment = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "figure.2.and.child.holdinghands")
                        .font(.system(size: 64))
                        .foregroundStyle(.blue)

                    Text("Big Brother")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Family screen time management")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(spacing: 16) {
                    Button {
                        showParentSetup = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "person.badge.shield.checkmark")
                                .font(.title2)
                            Text("Set Up as Parent")
                                .fontWeight(.semibold)
                            Text("Manage children's devices")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showChildEnrollment = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "iphone")
                                .font(.title2)
                            Text("Enroll as Child Device")
                                .fontWeight(.semibold)
                            Text("Enter code from parent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 32)

                Spacer()
            }
            .navigationDestination(isPresented: $showParentSetup) {
                ParentSetupView(appState: appState)
            }
            .navigationDestination(isPresented: $showChildEnrollment) {
                EnrollmentCodeEntryView(appState: appState)
            }
        }
    }
}
