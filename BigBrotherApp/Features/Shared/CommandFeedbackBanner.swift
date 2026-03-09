import SwiftUI

/// Displays command success/error feedback. Auto-dismisses success after a delay.
struct CommandFeedbackBanner: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
            Text(message)
                .font(.subheadline)
        }
        .foregroundStyle(isError ? .red : .green)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.red : Color.green).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
