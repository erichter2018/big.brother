import SwiftUI
import BigBrotherCore

/// PIN entry for parent authentication.
struct ParentPINEntryView: View {
    let appState: AppState
    let onComplete: (Bool) -> Void

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var attemptsRemaining: Int?
    @State private var lockoutDate: Date?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)

                Text("Enter Parent PIN")
                    .font(.title3)
                    .fontWeight(.bold)

                if let lockout = lockoutDate, lockout > Date() {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.xmark")
                            .font(.title2)
                            .foregroundStyle(.red)
                        Text("Too many failed attempts")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Try again in \(Int(lockout.timeIntervalSinceNow / 60) + 1) minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SecureField("PIN", text: $pin)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .font(.title2.monospaced())
                        .multilineTextAlignment(.center)
                        .frame(width: 200)

                    if let error = errorMessage {
                        VStack(spacing: 4) {
                            Text(error)
                                .foregroundStyle(.red)
                            if let remaining = attemptsRemaining, remaining > 0 {
                                Text("\(remaining) attempts remaining")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                    }

                    Button("Verify") {
                        verifyPIN()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pin.count < 4)
                }

                Spacer()
            }
            .navigationTitle("PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onComplete(false)
                    }
                }
            }
        }
    }

    private func verifyPIN() {
        guard let auth = appState.auth else { return }

        let result = auth.validatePIN(pin)
        switch result {
        case .success:
            onComplete(true)

        case .failure(let remaining):
            pin = ""
            attemptsRemaining = remaining
            errorMessage = "Incorrect PIN"

        case .lockedOut(let until):
            pin = ""
            lockoutDate = until
            errorMessage = nil
        }
    }
}
