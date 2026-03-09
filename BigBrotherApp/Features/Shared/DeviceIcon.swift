import SwiftUI
import BigBrotherCore

/// Consistent device icon based on model identifier.
struct DeviceIcon: View {
    let modelIdentifier: String
    var size: Font = .subheadline

    var body: some View {
        Image(systemName: systemName)
            .font(size)
            .foregroundStyle(.secondary)
    }

    var systemName: String {
        modelIdentifier.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone"
    }

    /// Large variant for device detail headers.
    static func large(for model: String) -> DeviceIcon {
        DeviceIcon(modelIdentifier: model, size: .system(size: 44))
    }
}
