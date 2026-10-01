// UNVERIFIED: written on Linux, never compiled. Build on a Mac first (see PROGRESS.md).
// Runs even when breakZero is force-quit. ~6 MB memory limit: keep it lean.
import Core
import DeviceActivity
import Foundation
import Shielding

/// Woken by DeviceActivity schedules: pass ends (re-shield), pending loosenings coming due,
/// and the S7 diagnostics pass. Every callback runs the same idempotent reconcile.
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        handle(activity, "intervalDidStart")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        handle(activity, "intervalDidEnd")
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        handle(activity, "eventDidReachThreshold.\(event.rawValue)")
    }

    private func handle(_ activity: DeviceActivityName, _ what: String) {
        guard let store = SharedStore.appGroup() else { return }
        if activity.rawValue == DiagnosticsShield.s7Activity {
            var line = "S7 \(what) at \(Date().ISO8601Format())"
            if what == "intervalDidEnd" {
                line += " · " + DiagnosticsShield.shield(store)
                if let expected = try? store.read(Date.self, "diagnostics-s7-expected-end.json") {
                    line += String(format: " · %.0fs after expected", Date().timeIntervalSince(expected))
                }
            }
            DiagnosticsLog.append(store, source: "monitor", line)
            return
        }
        let recipes = Platform.allCases.compactMap { try? RecipeLibrary.bundled($0) }
        WallEnforcer.live(store: store, recipes: recipes).reconcile(source: "monitor.\(what).\(activity.rawValue)")
    }
}
