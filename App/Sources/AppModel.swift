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
    /// Today's usage (trusted time) and what the limits say about it right now.
    private(set) var usage = UsageState()
    private(set) var limitStatus = LimitStatus.unlimited
    /// True while the app is in the foreground (scene phase active).
    private(set) var isForeground = false
    private var meterTimer: Timer?
    private var ticks = 0
    private var matchers: [Platform: ShortFormMatcher] = [:]
    /// Old Instagram setup: usernames read from the user's own lists (suggestions only).
    private(set) var friendsScan = FriendsScanState()
    /// While set and in the future, the Instagram page reads usernames on list pages.
    private(set) var scanUntil: Date?
    static let scanDuration: TimeInterval = 30 * 60

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
        for (p, recipe) in r { matchers[p] = ShortFormMatcher(recipe) }
        usage = (try? store.read(UsageState.self, UsageState.file)) ?? UsageState()
        friendsScan = (try? store.read(FriendsScanState.self, FriendsScanState.file)) ?? FriendsScanState()
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
        if before != policy {
            reevaluateLimits()
            rebuildLiteViews()
        }
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
        if let a = try? ActiveRecipe(recipe: recipe, settings: policy.settings(for: p), signedIn: signedIn,
                                     shortForm: limitStatus.shortForm) { return a }
        // A bad custom rule must never take the platform's filters down: fall back to defaults.
        log("settings for \(p.rawValue) invalid; using recipe defaults")
        return try? ActiveRecipe(recipe: recipe)
    }

    static let strings = LiteStrings(
        needsUpdate: String(localized: "Filter needs an update"),
        report: String(localized: "Report"),
        caughtUp: String(localized: "You're all caught up")
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
        c.onViolation = { [weak self] v in self?.handleViolation(p, v) }
        c.onFriendsScan = { [weak self] list, owner, names in self?.mergeScan(list, owner: owner, usernames: names) }
        c.setLimits(LiteLimits(blocked: limitStatus.platformBlock[p]?.rawValue))
        c.setWatchdogRunning(isForeground)
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

    func rebuildLiteViews(reload: Bool = true) {
        for (p, c) in controllers {
            guard let active = activeRecipe(p) else { continue }
            try? c.update(active: active, reload: reload)
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

    // MARK: Old Instagram (friends only)

    var friends: [String] { policy.settings(for: .instagram).friends }

    /// Old Instagram is filtering right now (toggle on and at least one friend).
    var friendsActive: Bool {
        guard let r = recipes[.instagram] else { return false }
        return policy.settings(for: .instagram).friendsActive(in: r)
    }

    var friendSuggestions: [String] { friendsScan.suggestions(excluding: friends) }

    /// Friends waiting for the cooldown (they show as pending, not as friends yet).
    var pendingFriendAdds: [(username: String, due: Date)] {
        lock.pending.compactMap { p in
            if case let .addFriend(.instagram, u) = p.change { return (u, p.estimatedDue) }
            return nil
        }
    }

    var isScanning: Bool { scanUntil.map { $0 > Date() } ?? false }

    /// Arm the read-only collector for 30 minutes and show the Instagram tab (optionally at `path`).
    /// The user opens their own lists and scrolls; nothing is fetched for them.
    func startFriendsScan(open path: String? = nil) {
        guard policy.enabledPlatforms.contains(.instagram), let c = controller(for: .instagram) else { return }
        scanUntil = Date().addingTimeInterval(Self.scanDuration)
        c.setScanning(true)
        log("friends scan started (30 min)")
        selectedTab = .lite(.instagram)
        if let path { c.load(path: path) }
    }

    func stopFriendsScan() {
        guard scanUntil != nil else { return }
        scanUntil = nil
        controllers[.instagram]?.setScanning(false)
        log("friends scan stopped")
    }

    func mergeScan(_ list: FriendsScanList, owner: String?, usernames: [String]) {
        guard isScanning else { return }
        var next = friendsScan
        let added = next.merge(list, owner: owner, usernames: usernames, now: Date())
        guard added > 0 || next != friendsScan else { return }
        friendsScan = next
        try? store.write(next, FriendsScanState.file)
        log("friends scan: +\(added) from \(list.rawValue)")   // counts only, never names
    }

    func clearFriendsScan() {
        friendsScan = FriendsScanState()
        try? store.write(friendsScan, FriendsScanState.file)
    }

    /// Adds go through the ratchet (loosening, except the first friend); returns the results.
    @discardableResult
    func addFriends(_ usernames: [String]) -> [SubmitResult] {
        let names = Array(Set(usernames.compactMap(Friends.normalize))).sorted()
        guard !names.isEmpty else { return [] }
        return submit(names.map { .addFriend(.instagram, username: $0) })
    }

    @discardableResult
    func removeFriend(_ username: String) -> SubmitResult? {
        submit([.removeFriend(.instagram, username: username)]).first
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

    // MARK: Limits (usage meter)

    /// Scene became active/inactive. Starts or stops the 1 s meter; the first sample after
    /// returning is a nil-activity check-in, so time in the background never counts.
    func setForeground(_ active: Bool) {
        if active == isForeground { return }
        if active {
            isForeground = true
            tickUsage(counting: false)
            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickUsage(counting: true) }
            }
            for c in controllers.values { c.setWatchdogRunning(true) }
        } else {
            for c in controllers.values { c.setWatchdogRunning(false) }
            tickUsage(counting: true)
            isForeground = false
            meterTimer?.invalidate()
            meterTimer = nil
            saveUsage()
        }
    }

    /// What's on screen right now, for the meter: a lite tab in the foreground, and whether its
    /// current path is a short-form surface.
    var currentActivity: ScreenActivity? {
        guard isForeground, case let .lite(p) = selectedTab, limitStatus.platformBlock[p] == nil,
              let path = controllers[p]?.currentPath else { return nil }
        return ScreenActivity(platform: p, shortForm: matchers[p]?.matches(path: path) ?? false)
    }

    func tickUsage(counting: Bool) {
        let sample = SystemClockSource().sample()
        if let until = scanUntil, sample.wall >= until { stopFriendsScan() }
        usage.tick(sample, activity: counting ? currentActivity : nil, timeZone: .current)
        ticks += 1
        if ticks % 5 == 0 { saveUsage() }
        if ticks % 30 == 0 {
            // Keep the wall's own ledger fresh too (pass expiry uses it).
            _ = try? store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) in
                lock.ledger.record(sample)
            }
            reload()
        }
        reevaluateLimits()
    }

    func saveUsage() {
        try? store.write(usage, UsageState.file)
    }

    var activePassTokens: Set<String> {
        Set(lock.passes.active(now: Date(), credited: lock.ledger.credited).map(\.appTokenID))
    }

    /// Recompute limits; when the short-form mode or a platform block changes, rebuild the
    /// affected lite views and let the watchdog act.
    func reevaluateLimits() {
        let next = LimitEvaluator.evaluate(policy.limits, usage: usage, activePassTokens: activePassTokens,
                                           platforms: policy.enabledPlatforms)
        let before = limitStatus
        limitStatus = next
        if before.shortForm != next.shortForm {
            log("short-form: \(before.shortForm.rawValue) → \(next.shortForm.rawValue)")
            rebuildLiteViews(reload: false)
        }
        for p in policy.enabledPlatforms where before.platformBlock[p] != next.platformBlock[p] {
            if let reason = next.platformBlock[p] {
                log("\(p.rawValue) blocked: \(reason.rawValue)")
                controllers[p]?.pauseMedia()
            } else {
                log("\(p.rawValue) unblocked")
            }
        }
        limitsChanged(from: before, to: next)
    }

    /// Push each platform's block state to its lite view; the watchdog (page + native) acts on it.
    func limitsChanged(from before: LimitStatus, to next: LimitStatus) {
        for (p, c) in controllers {
            c.setLimits(LiteLimits(blocked: next.platformBlock[p]?.rawValue))
        }
    }

    /// The watchdog moved the user off something: short toast saying why, and a log line.
    func handleViolation(_ p: Platform, _ v: WatchdogViolation) {
        let text = violationText(p, v)
        log("watchdog (\(v.source.rawValue)) \(v.reason)\(v.detail.map { "/" + $0 } ?? "") \(v.ruleID ?? ""): \(text)",
            source: "watchdog.\(p.rawValue)")
        showToast(text, platform: p)
    }

    func violationText(_ p: Platform, _ v: WatchdogViolation) -> String {
        if v.reason == "limit" {
            return v.detail == "schedule" ? String(localized: "\(p.displayName) is off by schedule.")
                : String(localized: "Daily limit reached for \(p.displayName).")
        }
        if v.ruleID == Friends.storyGateID {
            return String(localized: "Only friends' stories here.")
        }
        let isShortFormRule = v.ruleID.flatMap { id in recipes[p]?.routes.first { $0.id == id }?.shortForm } ?? false
        if isShortFormRule, limitStatus.shortForm == .forcedBlocked {
            return limitStatus.shortFormReason == .shortFormSchedule
                ? String(localized: "Reels and Shorts are off by schedule.")
                : String(localized: "Reels/Shorts time is used up for today.")
        }
        switch v.reason {
        case "bounced": return String(localized: "One reel per message. Back to the chat.")
        case "outOfScope": return String(localized: "Reels only open from a message.")
        case "redirected": return String(localized: "Opened the allowed version.")
        case "autoAdvance": return String(localized: "Autoplay is off.")
        default: return String(localized: "That part is behind the wall.")
        }
    }

    // MARK: Extra time (lite passes: same cap, wait and log as native passes)

    func requestLitePass(_ p: Platform, purpose: String) throws -> PassRecord {
        let rules = policy.pass
        let record: PassRecord = try store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) in
            try lock.passes.request(appTokenID: LimitEvaluator.passToken(p), purpose: purpose, rules: rules, now: Date())
        }
        log("pass requested for \(p.rawValue) (wait \(rules.waitSeconds) s)")
        reload()
        return record
    }

    func startLitePass(_ id: UUID) throws {
        let sample = SystemClockSource().sample()
        let rules = policy.pass
        _ = try store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) -> PassRecord in
            lock.ledger.record(sample)
            return try lock.passes.start(id, rules: rules, now: sample.wall, credited: lock.ledger.credited)
        }
        log("pass started (\(rules.durationMinutes) min)")
        reload()
        reevaluateLimits()
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
