import ManagedSettingsUI
import ManagedSettings
import BigBrotherCore

/// ShieldConfiguration extension.
///
/// Provides the custom UI shown when a user taps a shielded (blocked) app.
/// Called by the system — not by the main app.
///
/// Responsibilities:
/// - Read ShieldConfig from App Group storage
/// - Return a ShieldConfiguration with appropriate title, message, and styling
///
/// Constraints:
/// - Cannot make network calls
/// - Cannot present custom SwiftUI views (only ShieldConfiguration properties)
/// - Very limited resources
/// - Must read all state from App Group shared storage
class BigBrotherShieldExtension: ShieldConfigurationDataSource {

    private let storage = AppGroupStorage()

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        // Read from ExtensionSharedState first for faster decode, fall back to ShieldConfig.
        let config: ShieldConfig
        if let extState = storage.readExtensionSharedState() {
            config = extState.shieldConfig
        } else {
            config = storage.readShieldConfiguration() ?? ShieldConfig()
        }

        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(
                text: config.title,
                color: .white
            ),
            subtitle: ShieldConfiguration.Label(
                text: config.message,
                color: .init(white: 0.8, alpha: 1.0)
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "OK",
                color: .white
            ),
            primaryButtonBackgroundColor: .systemBlue
        )
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        // Same configuration for category-level shielding.
        configuration(shielding: application)
    }

    override func configuration(
        shielding webDomain: WebDomain
    ) -> ShieldConfiguration {
        let config = storage.readShieldConfiguration() ?? ShieldConfig()

        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            title: ShieldConfiguration.Label(
                text: "Website Restricted",
                color: .white
            ),
            subtitle: ShieldConfiguration.Label(
                text: config.message,
                color: .init(white: 0.8, alpha: 1.0)
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "OK",
                color: .white
            ),
            primaryButtonBackgroundColor: .systemBlue
        )
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        configuration(shielding: webDomain)
    }
}
