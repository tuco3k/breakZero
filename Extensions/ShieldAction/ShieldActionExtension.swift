// UNVERIFIED: written on Linux, never compiled. Build on a Mac first (see PROGRESS.md).
import Core
import Foundation
import ManagedSettings
import Shielding
import UserNotifications

/// Shield buttons. Extensions can't open apps, so (standard pattern, BRIEF §3) we post a local
/// notification that deep-links into breakZero, then close the shield.
/// What breaks it: notification permission denied (onboarding must ask), or iOS suppressing our
/// own notifications — verify in S4. How we'd notice: tapping the button does nothing visible.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let store = SharedStore.appGroup()
        let fingerprint = "app:" + TokenFingerprint.of(application)
        let policy = store.flatMap { try? $0.read(WallPolicy.self, AppGroup.File.policy) }
        let platform = policy?.shieldPlatforms[fingerprint]

        let link: URL
        let body: String
        switch action {
        case .primaryButtonPressed:
            link = platform.map(DeepLink.lite) ?? DeepLink.wall
            body = String(localized: "Tap to open the lite version.")
        case .secondaryButtonPressed:
            link = DeepLink.pass
            body = String(localized: "Tap to request a native pass.")
        @unknown default:
            completionHandler(.close)
            return
        }
        if let store { DiagnosticsLog.append(store, source: "shieldAction", "button \(action == .primaryButtonPressed ? "primary" : "secondary") → \(link.absoluteString)") }

        let content = UNMutableNotificationContent()
        content.title = "breakZero"
        content.body = body
        content.userInfo = [DeepLink.userInfoKey: link.absoluteString]
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "bz.shield.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in
            completionHandler(.close)
        }
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(.close)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(.close)
    }
}
