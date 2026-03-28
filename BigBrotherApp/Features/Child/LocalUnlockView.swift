import SwiftUI
import BigBrotherCore

/// PIN entry for local parent unlock on a child device.
struct LocalUnlockView: View {
    @Bindable var viewModel: LocalParentUnlockViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isResetMode = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if viewModel.unlockSuccess && isResetMode {
                    resetConfirmView
                } else if viewModel.unlockSuccess {
                    successView
                } else if !viewModel.isPINConfigured {
                    noPINView
                } else if viewModel.isLockedOut {
                    lockoutView
                } else if viewModel.selectedDuration == nil {
                    durationPickerView
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
    private var durationPickerView: some View {
        Image(systemName: "clock")
            .font(.system(size: 48))
            .foregroundStyle(.blue)

        Text("Select Duration")
            .font(.title3)
            .fontWeight(.bold)

        Text("How long should the device be unlocked?")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)

        VStack(spacing: 8) {
            ForEach(Array(LocalParentUnlockViewModel.durationOptions.enumerated()), id: \.offset) { _, option in
                Button {
                    viewModel.selectedDuration = option.seconds ?? LocalParentUnlockViewModel.secondsUntilMidnight
                } label: {
                    Label(option.label, systemImage: option.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.bordered)
            }

            Divider().padding(.vertical, 4)

            Button {
                isResetMode = true
                viewModel.selectedDuration = 0 // triggers PIN entry
            } label: {
                Label("Reset Device", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .frame(maxWidth: 260)
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

        let durationLabel = LocalParentUnlockViewModel.durationOptions
            .first { $0.seconds == viewModel.selectedDuration }?.label
            ?? "\(viewModel.selectedDuration.map { "\($0 / 60) minutes" } ?? "")"
        Text("Unlocked for \(durationLabel). The device will re-lock automatically.")
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
            let mins = Int(ceil(max(0, lockout.timeIntervalSinceNow) / 60))
            Text("Try again in \(max(1, mins)) minute\(mins == 1 ? "" : "s").")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var resetConfirmView: some View {
        Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 48))
            .foregroundStyle(.red)

        Text("Reset Device?")
            .font(.title3)
            .fontWeight(.bold)

        Text("This clears enrollment, restrictions, and all settings. You'll need to re-enroll with a new code.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

        HStack(spacing: 16) {
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
            Button("Reset") {
                resetDevice()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func resetDevice() {
        let appState = viewModel.appState

        // Clear Keychain (enrollment, role, PIN, familyID).
        let keychain = appState.keychain
        try? keychain.delete(forKey: StorageKeys.enrollmentState)
        try? keychain.delete(forKey: StorageKeys.deviceRole)
        try? keychain.delete(forKey: StorageKeys.familyID)
        try? keychain.delete(forKey: StorageKeys.parentPINHash)
        try? keychain.delete(forKey: StorageKeys.lastShieldedAppKeychain)

        // Clear enforcement (shields + restrictions).
        try? appState.enforcement?.clearAllRestrictions()

        // Clear App Group storage using appState's storage instance.
        let storage = appState.storage
        try? storage.writeDeviceRestrictions(DeviceRestrictions())
        try? storage.clearTemporaryUnlockState()
        try? storage.clearUnlockPickerPending()

        // Reset app state to unconfigured.
        try? appState.setRole(.unconfigured)

        dismiss()
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
