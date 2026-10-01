// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
import Core
import Foundation
import LiteWeb
import Observation
import Photos
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
    /// The user saw the "wall is down" screen and chose to carry on (this session only).
    var acknowledgedWallDown = false
    var lastMessage: String?
    private(set) var controllers: [Platform: LiteWebController] = [:]
    /// Unread counts parsed from page titles (tab badges).
    private(set) var unread: [Platform: Int] = [:]
    /// Our bottom tab bar is hidden by default so the sites get the full screen; the button in the
    /// lite header strip toggles it. Remembered on this device.
    var tabBarVisible: Bool = UserDefaults.standard.bool(forKey: AppModel.tabBarKey) {
        didSet { UserDefaults.standard.set(tabBarVisible, forKey: AppModel.tabBarKey) }
    }
    static let tabBarKey = "bz.tabBarVisible"
    /// Signed in/out per platform (nil = not checked yet). Cookie names only.
    private(set) var sessions: [Platform: Bool] = [:]
    /// Short message shown in the lite header strip (e.g. why the watchdog moved you).
    private(set) var toast: Toast?

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let platform: Platform?
        let text: String
    }
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
        #if BZ_SCREEN_TIME && canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
        WallEnforcer.live(store: store, recipes: Array(recipes.values)).reconcile(source: source)
        #else
        _ = try? store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) in
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
        // Unknown session (not checked yet) counts as signed in; the check runs before first load.
        let signedIn = sessions[p] ?? true
        if let a = try? ActiveRecipe(recipe: recipe, settings: policy.settings(for: p), signedIn: signedIn) { return a }
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
        c.onUnreadCount = { [weak self] n in self?.unread[p] = n }
        c.onDownloaded = { [weak self] url in self?.saveToPhotos(url) }
        c.onCookiesChanged = { [weak self] in Task { await self?.updateSession(p, thenLoadLanding: false) } }
        controllers[p] = c
        // Check the session first so a signed-out YouTube lands on Search, not empty Subscriptions.
        Task { await updateSession(p, thenLoadLanding: true) }
        return c
    }

    /// Downloads from a lite view (a photo/video the user chose to save) go to Photos, add-only.
    func saveToPhotos(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let isVideo = ["mp4", "mov", "m4v"].contains(ext)
        let isImage = ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext)
        guard isVideo || isImage else {
            log("download kept out of Photos (type .\(ext))")
            try? FileManager.default.removeItem(at: url)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }, completionHandler: { _, _ in try? FileManager.default.removeItem(at: url) })
        }
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

    // MARK: Accounts

    func refreshSessions() async {
        for p in policy.enabledPlatforms { await updateSession(p, thenLoadLanding: false) }
    }

    /// Re-read signed in/out from cookie names; if it changed, rebuild that lite view's rules
    /// (the landing differs) without reloading the page.
    func updateSession(_ p: Platform, thenLoadLanding: Bool) async {
        guard let recipe = recipes[p] else { return }
        let signedIn = await LiteSession.isSignedIn(p, recipe: recipe)
        let changed = sessions[p] != signedIn
        sessions[p] = signedIn
        if changed, let c = controllers[p], let active = activeRecipe(p) {
            try? c.update(active: active, reload: false)
            log("\(p.rawValue) session: \(signedIn ? "signed in" : "signed out")")
        }
        if thenLoadLanding { controllers[p]?.loadLanding() }
    }

    /// Clears only this platform's cookies, then reloads its lite view at the landing page.
    func signOut(_ p: Platform) async {
        await LiteSession.signOut(p)
        log("signed out of \(p.rawValue) (cookies cleared)")
        controllers[p]?.loadLanding()
        await refreshSessions()
    }

    // MARK: Login-free YouTube (RSS + Takeout CSV)

    var youtubeSubscriptions: SubscriptionsState {
        (try? store.read(SubscriptionsState.self, SubscriptionsState.file)) ?? SubscriptionsState()
    }

    /// Import Google Takeout's subscriptions.csv (picked with the Files sheet).
    func importTakeoutCSV(from url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        let channels = TakeoutCSV.parseSubscriptions(text)
        try store.update(SubscriptionsState.file, default: SubscriptionsState()) { (s: inout SubscriptionsState) in
            s.importChannels(channels)
        }
        log("imported \(channels.count) YouTube channels from Takeout CSV")
        return channels.count
    }

    /// Fetch each channel's public feed through NetworkPolicy (no cookies, no account).
    func refreshYouTubeSubscriptions(force: Bool) async {
        let enabled = policy.enabledPlatforms.compactMap { recipes[$0] }
        let network = NetworkPolicy(recipes: enabled, recipeUpdatesEnabled: policy.recipeUpdatesEnabled)
        let current = youtubeSubscriptions
        let next = await SubscriptionsRefresher.refresh(current, now: Date(), force: force) { channel in
            try await network.fetchYouTubeFeed(channel)
        }
        guard next != current else { return }
        try? store.write(next, SubscriptionsState.file)
        if !next.failedChannels.isEmpty { log("YouTube feeds: \(next.failedChannels.count) channels failed to load") }
    }

    /// Open a video from the native list in the YouTube lite view.
    func openYouTube(path: String) {
        guard policy.enabledPlatforms.contains(.youtube) else { return }
        selectedTab = .lite(.youtube)
        controller(for: .youtube)?.load(path: path)
    }

    /// Shorts appear in the list only when the user has turned "Hide Shorts" off.
    var youtubeListIncludesShorts: Bool {
        guard let r = recipes[.youtube] else { return false }
        return !policy.settings(for: .youtube).isOn("yt.hideShorts", in: r)
    }

    // MARK: Toast

    func showToast(_ text: String, platform: Platform? = nil) {
        let t = Toast(platform: platform, text: text)
        toast = t
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.toast?.id == t.id { self?.toast = nil }
        }
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
