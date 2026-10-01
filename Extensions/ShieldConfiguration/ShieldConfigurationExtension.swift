// UNVERIFIED: written on Linux, never compiled. Build on a Mac first (see PROGRESS.md).
// Shield screens only appear on a real device (not the Simulator).
import ManagedSettings
import ManagedSettingsUI
import UIKit

/// The screen iOS shows when a shielded app is opened. Primary button → lite version (via
/// ShieldAction + local notification); secondary → request a native pass.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        appShield(name: application.localizedDisplayName)
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        appShield(name: application.localizedDisplayName)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        webShield(domain: webDomain.domain)
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        webShield(domain: webDomain.domain)
    }

    private func appShield(name: String?) -> ShieldConfiguration {
        let title = name.map { String(localized: "\($0) is behind the wall") } ?? String(localized: "This app is behind the wall")
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            icon: UIImage(systemName: "shield.lefthalf.filled"),
            title: .init(text: title, color: .label),
            subtitle: .init(text: String(localized: "Use the lite version in breakZero. You'll get a notification that opens it."),
                            color: .secondaryLabel),
            primaryButtonLabel: .init(text: String(localized: "Open lite version"), color: .white),
            primaryButtonBackgroundColor: .systemBlue,
            secondaryButtonLabel: .init(text: String(localized: "Request a native pass"), color: .systemBlue)
        )
    }

    private func webShield(domain: String?) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            icon: UIImage(systemName: "shield.lefthalf.filled"),
            title: .init(text: String(localized: "\(domain ?? "This site") is behind the wall"), color: .label),
            subtitle: .init(text: String(localized: "Open breakZero to use the lite version."), color: .secondaryLabel),
            primaryButtonLabel: .init(text: String(localized: "OK"), color: .white),
            primaryButtonBackgroundColor: .systemBlue
        )
    }
}
