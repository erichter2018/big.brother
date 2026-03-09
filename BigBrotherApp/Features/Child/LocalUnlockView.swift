import SwiftUI
import BigBrotherCore

/// PIN entry for local parent unlock on a child device.
struct LocalUnlockView: View {
    @Bindable var viewModel: LocalParentUnlockViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if viewModel.unlockSuccess {
                    successView
                } else if !viewModel.isPINConfigured {
                    noPINView
                } else if viewModel.isLockedOut {
                    lockoutView
                } else {
                    pinEntryView
                }

                Spacer()
            }
            .navigationTitle("Parent Unlock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var pinEntryView: some View {
        Image(systemName: "lock.open")
            .font(.system(size: 48))
            .foregroundStyle(.blue)

        Text("Enter Parent PIN")
            .font(.title3)
            .fontWeight(.bold)

        Text("A parent can enter their PIN to temporarily unlock this device.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)

        SecureField("PIN", text: $viewModel.pin)
            .textFieldStyle(.roundedBorder)
            .keyboardType(.numberPad)
            .font(.title2.monospaced())
            .multilineTextAlignment(.center)
            .frame(width: 200)

        if let error = viewModel.errorMessage {
            VStack(spacing: 4) {
                Text(error).foregroundStyle(.red)
                if let remaining = viewModel.attemptsRemaining, remaining > 0 {
                    Text("\(remaining) attempts remaining").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }

        Button("Unlock") {
            viewModel.verifyPIN()
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.pin.count < 4)
    }

    @ViewBuilder
    private var successView: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 64))
            .foregroundStyle(.green)

        Text("Device Unlocked")
            .font(.title2)
            .fontWeight(.bold)

        Text("Temporary unlock is now active. The device will re-lock automatically.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

        Button("Done") { dismiss() }
            .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var lockoutView: some View {
        Image(systemName: "clock.badge.xmark")
            .font(.system(size: 48))
            .foregroundStyle(.red)

        Text("Too Many Attempts")
            .font(.title3)
            .fontWeight(.bold)

        if let lockout = viewModel.lockoutDate {
            Text("Try again in \(Int(max(0, lockout.timeIntervalSinceNow / 60)) + 1) minutes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var noPINView: some View {
        Image(systemName: "lock.slash")
            .font(.system(size: 48))
            .foregroundStyle(.secondary)

        Text("PIN Not Configured")
            .font(.title3)
            .fontWeight(.bold)

        Text("The parent needs to set up a PIN on their device first.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
    }
}
