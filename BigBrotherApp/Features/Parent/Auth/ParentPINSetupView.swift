import SwiftUI
import BigBrotherCore

/// PIN setup or change flow.
struct ParentPINSetupView: View {
    let appState: AppState
    var isInitialSetup: Bool = true
    var onComplete: (() -> Void)? = nil

    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var step: Step = .enter
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    enum Step {
        case enter, confirm
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: step == .enter ? "lock.open" : "lock")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)

                Text(step == .enter ? "Create a Parent PIN" : "Confirm PIN")
                    .font(.title3)
                    .fontWeight(.bold)

                Text(step == .enter
                     ? "Choose a 4-8 digit PIN for parent access."
                     : "Enter your PIN again to confirm.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                SecureField("PIN", text: step == .enter ? $pin : $confirmPin)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .font(.title2.monospaced())
                    .multilineTextAlignment(.center)
                    .frame(width: 200)

                if let error = errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                Button(step == .enter ? "Next" : "Set PIN") {
                    if step == .enter {
                        advanceToConfirm()
                    } else {
                        savePIN()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentInput.count < 4)

                Spacer()
            }
            .navigationTitle("PIN Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if let onComplete {
                            onComplete()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var currentInput: String {
        step == .enter ? pin : confirmPin
    }

    private func advanceToConfirm() {
        guard pin.count >= 4 && pin.count <= 8 else {
            errorMessage = "PIN must be 4-8 digits."
            return
        }
        guard pin.allSatisfy(\.isNumber) else {
            errorMessage = "PIN must contain only digits."
            return
        }
        errorMessage = nil
        step = .confirm
    }

    private func savePIN() {
        guard confirmPin == pin else {
            errorMessage = "PINs don't match. Try again."
            confirmPin = ""
            return
        }

        do {
            try appState.auth?.setPIN(pin)
            Task { await appState.syncPINToChildDevices() }
            if let onComplete {
                onComplete()
            } else {
                dismiss()
            }
        } catch {
            errorMessage = "Failed to save PIN: \(error.localizedDescription)"
        }
    }
}
