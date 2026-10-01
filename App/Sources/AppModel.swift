// UNVERIFIED: written on Linux, never compiled. Build on a Mac first (see PROGRESS.md).
import Core
import Foundation
import LiteWeb
import Observation
import Shielding
import SwiftUI
import UIKit

enum AppTab: Hashable {
    case lite(Platform)
    case wall
}

/// App-wide state. One instance, created at launch.
@MainActor
@Observable
final class AppModel {
    let store: SharedStore
    let recipes: [Platform: Recipe]
    private(set) var policy = WallPolicy()
    private(set) var lock = LockState()
    var selectedTab: AppTab = .lite(.instagram)
    var externalURL: IdentifiedURL?
    var showDiagnostics = false
    var lastMessage: String?
    private(set) var controllers: [Platform: LiteWebController] = [:]
    let launchedAt: Date

    struct IdentifiedURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    init(launchedAt: Date) {
        self.launchedAt = launchedAt
        // Without the App Group entitlement (unsigned Simulator builds) fall back to a private
        // directory so the UI still works; extensions can't see it, which is fine there.
        if let shared = SharedStore.appGroup() {
            store = shared
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("breakZero-local", isDirectory: true)
            store = SharedStore(directory: dir)
        }
        var r: [Platform: Recipe] = [:]
        for p in Platform.allCases {
            if let recipe = try? RecipeLibrary.bundled(p) { r[p] = recipe }
        }
        recipes = r
        reload()
        if let first = policy.enabledPlatforms.first { selectedTab = .lite(first) } else { selectedTab = .wall }
    }

    var ratchet: Ratchet { Ratchet(recipes: Array(recipes.values)) }

    func reload() {
        // A missing file means a fresh install (defaults). A file that fails to decode keeps the
        // last good in-memory copy: a corrupt file must never read as "no wall".
        do { policy = try store.read(WallPolicy.self, AppGroup.File.policy) ?? WallPolicy() } catch {
            log("policy unreadable: \(error)")
        }
        do { lock = try store.read(LockState.self, AppGroup.File.lock) ?? LockState() } catch {
            log("lock state unreadable: \(error)")
        }
    }

    func log(_ message: String, source: String = "app") {
        DiagnosticsLog.append(store, source: source, message)
    }

    // MARK: Wall

    /// Launch / foreground / after any change: the same idempotent routine the extensions run.
    func reconcile(source: String) {
        #if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
        WallEnforcer.live(store: store, recipes: Array(recipes.values)).reconcile(source: source)
        #else
        try? store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) in
            try store.update(AppGroup.File.policy, default: WallPolicy()) { (policy: inout WallPolicy) in
                ratchet.applyDue(policy: &policy, lock: &lock, at: SystemClockSource().sample())
            }
        }
        #endif
        let before = policy
        reload()
        if before != policy { rebuildLiteViews() }
    }

    @discardableResult
    func submit(_ changes: [PolicyChange]) -> [SubmitResult] {
        let sample = SystemClockSource().sample()
        let ratchet = self.ratchet
        let results: [SubmitResult] = (try? store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) in
            try store.update(AppGroup.File.policy, default: WallPolicy()) { (policy: inout WallPolicy) in
                ratchet.submit(changes, policy: &policy, lock: &lock, at: sample)
            }
        }) ?? []
        for r in results { log("submit \(r)") }
        reconcile(source: "app.submit")
        return results
    }

    func cancelPending(_ id: UUID) {
        let ratchet = self.ratchet
        try? store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) in
            ratchet.cancel(id, lock: &lock)
        }
        reload()
    }

    // MARK: Lite views

    func activeRecipe(_ p: Platform) -> ActiveRecipe? {
        guard let recipe = recipes[p] else { return nil }
        if let a = try? ActiveRecipe(recipe: recipe, settings: policy.settings(for: p)) { return a }
        // A bad custom rule must never take the platform's filters down: fall back to defaults.
        log("settings for \(p.rawValue) invalid; using recipe defaults")
        return try? ActiveRecipe(recipe: recipe)
    }

    static let strings = LiteStrings(
        needsUpdate: String(localized: "Filter needs an update"),
        report: String(localized: "Report")
    )

    func controller(for p: Platform) -> LiteWebController? {
        if let c = controllers[p] { return c }
        guard let active = activeRecipe(p), let c = try? LiteWebController(platform: p, active: active, strings: Self.strings) else {
            return nil
        }
        c.onOpenExternally = { [weak self] url in self?.externalURL = .init(url: url) }
        c.onEvent = { [weak self] msg in self?.log(msg, source: "lite.\(p.rawValue)") }
        c.onReport = { [weak self] ids in self?.openReport(platform: p, ids: ids) }
        c.onFirstLoad = { [weak self] seconds in
            guard let self else { return }
            let sinceLaunch = Date().timeIntervalSince(self.launchedAt)
            self.log(String(format: "S6 first load %@: %.2fs since controller, %.2fs since launch", p.rawValue, seconds, sinceLaunch))
        }
        controllers[p] = c
        c.loadLanding()
        return c
    }

    func rebuildLiteViews() {
        for (p, c) in controllers {
            guard let active = activeRecipe(p) else { continue }
            try? c.update(active: active)
        }
    }

    func openReport(platform: Platform, ids: [String]) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard let url = LiteScriptBuilder.reportURL(platform: platform.rawValue, recipeVersion: recipes[platform]?.version ?? 0,
                                                    canaryIDs: ids, appVersion: version,
                                                    osVersion: UIDevice.current.systemVersion) else { return }
        // Opens in Safari (the user's choice to send). Not app traffic.
        UIApplication.shared.open(url)
    }

    // MARK: Deep links

    /// breakzero://lite/instagram, breakzero://wall, breakzero://pass, breakzero://diagnostics
    func handle(url: URL) {
        guard url.scheme == "breakzero" else { return }
        switch url.host {
        case "lite":
            let name = url.pathComponents.dropFirst().first ?? ""
            if let p = Platform(rawValue: name), policy.enabledPlatforms.contains(p) { selectedTab = .lite(p) }
        case "wall", "pass":
            selectedTab = .wall
        case "diagnostics":
            selectedTab = .wall
            showDiagnostics = true
        default:
            break
        }
    }
}
