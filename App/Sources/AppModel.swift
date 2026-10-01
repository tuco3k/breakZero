// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
import Core
import Foundation
import LiteWeb
import Observation
import Photos
import Shielding
import SwiftUI
import UIKit
import WebKit

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
    /// The one toast on screen (coalesced, ~2 s, never blocking; QUESTIONS #56).
    private(set) var toasts = ToastCenter()
    /// Today's usage (trusted time) and what the limits say about it right now.
    private(set) var usage = UsageState()
    private(set) var limitStatus = LimitStatus.unlimited
    /// True while the app is in the foreground (scene phase active).
    private(set) var isForeground = false
    private var meterTimer: Timer?
    private var ticks = 0
    private var matchers: [Platform: ShortFormMatcher] = [:]
    /// Feed rules data: who follows the user and whom they follow (on-device; refreshing is data).
    private(set) var people = PeopleData()
    /// Auto-scroll sync of the user's own lists (persisted so the next session continues).
    private(set) var sync: SyncSession?
    /// Manual scrolling (last resort): while set and in the future, list pages are read.
    private(set) var scanUntil: Date?
    static let scanDuration: TimeInterval = 30 * 60
    /// Accounts the feed rules hid during this app run (status pill), newest first.
    private(set) var recentlyHidden: [String] = []
    private(set) var hiddenCount = 0
    /// The person whose story is on screen in the Instagram tab (for "Hide @user"), if any.
    private(set) var instagramStoryUser: String?
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
        people = Self.loadPeople(store)
        sync = try? store.read(SyncSession.self, SyncSession.file)
        if var s = sync, s.running { s.stop(.userStopped); sync = s }   // never resume scrolling by itself
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
                                     shortForm: limitStatus.shortFormMode(p), people: p == .instagram ? people : nil) { return a }
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
        c.onFriendsScan = { [weak self] list, owner, names in self?.handleScan(list, owner: owner, usernames: names) }
        c.onFriendsHidden = { [weak self] names in self?.noteHidden(names) }
        c.onHideAccount = { [weak self] name in self?.hideAccount(name) }
        c.onSyncEvent = { [weak self] list, event in self?.handleSyncEvent(list, event) }
        c.onRouteChange = { [weak self] url in self?.routeChanged(p, url) }
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

    // MARK: Feed rules (ARCHITECTURE.md §4c rev. 2)

    var igSettings: PlatformSettings { policy.settings(for: .instagram) }

    /// Feed rules' switch is on (they filter once there's something to filter).
    var feedRulesOn: Bool {
        guard let r = recipes[.instagram] else { return false }
        return igSettings.feedRulesOn(in: r)
    }

    /// Something is being filtered right now.
    var feedRulesActive: Bool { activeRecipe(.instagram)?.friends != nil }

    /// Pill text: "Mutuals only", "Everyone I follow"… (the feed's rule).
    var feedRuleName: String { Self.audienceName(igSettings.audience(.feed)) }

    static func audienceName(_ a: Audience) -> String {
        switch a {
        case .everyone: String(localized: "Everyone I follow")
        case .mutuals: String(localized: "Mutuals only")
        case .myList: String(localized: "My list")
        case .closeFriends: String(localized: "Close Friends")
        }
    }

    /// A rule needs data that isn't there yet (mutuals before any import).
    func needsData(_ surface: FeedSurface) -> Bool {
        let a = igSettings.audience(surface)
        switch a {
        case .mutuals: return !people.hasMutualsData
        case .closeFriends: return people.closeFriends.isEmpty
        case .everyone: return people.following.isEmpty
        case .myList: return false
        }
    }

    /// People changes waiting for the cooldown, per list.
    func pendingPeople(_ list: PeopleList) -> [(username: String, adding: Bool, due: Date)] {
        lock.pending.compactMap { p in
            switch p.change {
            case let .addPerson(.instagram, l, u) where l == list: (u, true, p.estimatedDue)
            case let .removePerson(.instagram, l, u) where l == list: (u, false, p.estimatedDue)
            case let .addFriend(.instagram, u) where list == .myList: (u, true, p.estimatedDue)
            default: nil
            }
        }
    }

    func savePeople() {
        try? store.write(people, PeopleData.file)
    }

    /// New data (import, sync, scan): rebuild the Instagram view's rules without a cooldown.
    func peopleChanged() {
        savePeople()
        if let c = controllers[.instagram], let active = activeRecipe(.instagram) {
            try? c.update(active: active, reload: false)
        }
    }

    // Import (recommended setup)

    struct ImportSummary: Equatable {
        var mutuals: Int
        var following: Int
        var followers: Int
        var closeFriends: Int?
    }

    /// Instagram's data export: the .zip or the JSON files from it. Read and parsed off the main
    /// thread; replaces followers/following (removed people disappear at once). Data, not a rule
    /// change, so no cooldown.
    func importExport(_ urls: [URL]) async throws -> ImportSummary {
        let files: [(name: String, data: Data)] = try await Task.detached(priority: .userInitiated) {
            try urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= ExportImporter.maxArchiveBytes else { throw ExportImporter.Failure.tooLarge }
                return (url.lastPathComponent, try Data(contentsOf: url, options: .mappedIfSafe))
            }
        }.value
        let imported = try await Task.detached(priority: .userInitiated) { try ExportImporter.importFiles(files) }.value
        var next = people
        try next.replace(followers: imported.followers, following: imported.following, closeFriends: imported.closeFriends,
                         owner: imported.owner, now: Date())
        people = next
        peopleChanged()
        log("people imported from export: \(imported.mutuals.count) mutuals, \(imported.following.count) following, \(imported.followers.count) followers")
        return ImportSummary(mutuals: imported.mutuals.count, following: imported.following.count,
                             followers: imported.followers.count, closeFriends: imported.closeFriends?.count)
    }

    // Auto-scroll sync (optional)

    var syncRunning: Bool { sync?.running ?? false }

    /// Start or resume on the user's tap: open their own Followers (or where the last session
    /// stopped) in the Instagram tab and scroll it visibly.
    func startSync(owner raw: String) {
        guard let owner = Friends.normalize(raw), policy.enabledPlatforms.contains(.instagram),
              let c = controller(for: .instagram) else { return }
        stopManualScan()
        var s = (sync?.owner == owner ? sync : nil) ?? SyncSession(owner: owner)
        s.begin(people: people)
        sync = s
        saveSync()
        guard let list = s.currentList else { return }
        log("sync started (\(list.rawValue))")
        selectedTab = .lite(.instagram)
        c.load(path: "/\(owner)/\(list.rawValue)/")
        c.setSync(LiteSync(list: list, owner: owner))
    }

    func stopSync(_ reason: SyncStopReason = .userStopped) {
        guard var s = sync, s.running else { return }
        s.stop(reason)
        sync = s
        saveSync()
        controllers[.instagram]?.setSync(nil)
        log("sync stopped: \(reason.rawValue)")
        if reason.isWarning {
            showToast(String(localized: "Instagram showed a warning. Sync stopped; try again later."), kind: "sync")
        }
    }

    private func saveSync() {
        if let sync { try? store.write(sync, SyncSession.file) }
    }

    private func handleSyncNames(_ list: FriendsScanList, _ names: [String]) {
        guard var s = sync, s.running else { return }
        var p = people
        let step = s.record(list, names, people: &p, now: Date())
        sync = s
        if p != people { people = p; peopleChanged() }
        saveSync()
        if case .stop = step {
            controllers[.instagram]?.setSync(nil)
            showToast(String(localized: "Read \(s.cap) new names. Tap Continue later to read more."), kind: "sync")
        }
    }

    private func handleSyncEvent(_ list: FriendsScanList, _ event: SyncPageEvent) {
        guard var s = sync, s.running else { return }
        switch event {
        case .end:
            var p = people
            let step = s.reachedEnd(list, people: &p, now: Date())
            sync = s
            if p != people { people = p; peopleChanged() }
            saveSync()
            switch step {
            case let .nextList(next):
                controllers[.instagram]?.load(path: "/\(s.owner)/\(next.rawValue)/")
                controllers[.instagram]?.setSync(LiteSync(list: next, owner: s.owner))
            case .finished:
                controllers[.instagram]?.setSync(nil)
                log("sync finished: \(people.mutuals.count) mutuals")
                showToast(String(localized: "Sync done: \(people.mutuals.count) mutuals."), kind: "sync")
            default:
                break
            }
        case .stalled: stopSync(.stalled)
        case .challenge: stopSync(.challenge)
        case .login: stopSync(.login)
        case .warning: stopSync(.warning)
        case .leftPage: stopSync(.leftPage)
        }
    }

    // Manual scrolling (last resort)

    var isScanning: Bool { scanUntil.map { $0 > Date() } ?? false }

    /// Arm the read-only collector for 30 minutes and show the Instagram tab (optionally at `path`).
    /// The user opens their own lists and scrolls; nothing is fetched for them. Adds only.
    func startManualScan(open path: String? = nil) {
        guard policy.enabledPlatforms.contains(.instagram), let c = controller(for: .instagram) else { return }
        stopSync()
        scanUntil = Date().addingTimeInterval(Self.scanDuration)
        c.setScanning(true)
        log("manual scan started (30 min)")
        selectedTab = .lite(.instagram)
        if let path { c.load(path: path) }
    }

    func stopManualScan() {
        guard scanUntil != nil else { return }
        scanUntil = nil
        controllers[.instagram]?.setScanning(false)
        log("manual scan stopped")
    }

    private func handleScan(_ list: FriendsScanList, owner: String?, usernames: [String]) {
        if syncRunning, sync?.currentList == list { handleSyncNames(list, usernames); return }
        guard isScanning else { return }
        var p = people
        if list != .closeFriends, let owner { p.owner = p.owner ?? owner }
        let added = p.add(list, usernames, source: .manual, now: Date())
        guard added > 0 else { return }
        people = p
        peopleChanged()
        log("manual scan: +\(added) from \(list.rawValue)")   // counts only, never names
    }

    // Lists (rules go through the ratchet)

    @discardableResult
    func changePeople(_ list: PeopleList, add: Bool, _ usernames: [String]) -> [SubmitResult] {
        let names = Array(Set(usernames.compactMap(Friends.normalize))).sorted()
        guard !names.isEmpty else { return [] }
        let results = submit(names.map { add ? .addPerson(.instagram, list, username: $0) : .removePerson(.instagram, list, username: $0) })
        reportPeopleResults(results, list: list, add: add)
        return results
    }

    /// One coalesced toast for a bulk change: "Added 5 people to Never show", "3 wait for the cooldown".
    func reportPeopleResults(_ results: [SubmitResult], list: PeopleList, add: Bool) {
        let applied = results.filter { if case .applied = $0 { return true }; return false }.count
        let queued = results.compactMap { r -> PendingChange? in if case let .queued(p) = r { return p }; return nil }
        if let first = queued.first {
            showToast(String(localized: "\(queued.count) waiting for the cooldown (about \(first.estimatedDue.formatted(date: .abbreviated, time: .shortened)))."),
                      kind: "people.queued")
        }
        if applied > 0 {
            let where_ = Self.listName(list)
            showToast(add ? String(localized: "Added \(applied) to \(where_)") : String(localized: "Removed \(applied) from \(where_)"),
                      kind: "people.\(list.rawValue).\(add)")
        }
        if let why = results.lazy.compactMap({ r -> String? in if case let .rejectedInvalid(w) = r { return w }; return nil }).first {
            showToast(why, kind: "people.invalid")
        }
        if let until = results.lazy.compactMap({ r -> Date? in if case let .rejectedHardLock(d) = r { return d }; return nil }).first {
            showToast(String(localized: "Hard Lock until \(until.formatted(date: .abbreviated, time: .shortened))."), kind: "hardlock")
        }
    }

    static func listName(_ l: PeopleList) -> String {
        switch l {
        case .myList: String(localized: "My list")
        case .always: String(localized: "Always show")
        case .never: String(localized: "Never show")
        }
    }

    /// The one-tap hide (post button, story strip button, hidden-recently sheet): narrowing, instant.
    func hideAccount(_ username: String) {
        guard let u = Friends.normalize(username) else { return }
        let results = submit([.addPerson(.instagram, .never, username: u)])
        if case .applied = results.first {
            showToast(String(localized: "Hidden @\(u)"), kind: "hidden") { n in String(localized: "Hidden \(n) accounts") }
        }
    }

    /// Who the rules hid recently (this app run, newest first, on device only; never logged).
    private func noteHidden(_ names: [String]) {
        for n in names {
            recentlyHidden.removeAll { $0 == n }
            recentlyHidden.insert(n, at: 0)
        }
        if recentlyHidden.count > 200 { recentlyHidden.removeLast(recentlyHidden.count - 200) }
        hiddenCount = recentlyHidden.count
    }

    /// rev. 1 kept suggestions in `ig-friends-scan.json`; fold them in once (adds only).
    static func loadPeople(_ store: SharedStore) -> PeopleData {
        if let p = try? store.read(PeopleData.self, PeopleData.file) { return p }
        struct LegacyScan: Decodable { var owner: String?; var followers: Set<String>?; var following: Set<String>?; var closeFriends: Set<String>? }
        guard let old = try? store.read(LegacyScan.self, PeopleData.legacyFile) else { return PeopleData() }
        return PeopleData(owner: old.owner, followers: old.followers ?? [], following: old.following ?? [],
                          closeFriends: old.closeFriends ?? [], updatedAt: Date(), source: .manual)
    }

    private func routeChanged(_ p: Platform, _ url: URL) {
        guard p == .instagram, let r = recipes[.instagram]?.friendsFilter, let re = try? PathRegex(r.storyRoute) else { return }
        let user = re.firstMatch(RuleEngine.path(url))?["user"]?.lowercased()
        instagramStoryUser = user.flatMap { r.storyExempt.contains($0) ? nil : $0 }
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
        if let until = scanUntil, sample.wall >= until { stopManualScan() }
        _ = toasts.expire(at: sample.wall)
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
        showToast(text, kind: "violation.\(p.rawValue).\(v.ruleID ?? v.reason)")
    }

    func violationText(_ p: Platform, _ v: WatchdogViolation) -> String {
        if v.reason == "limit" {
            return v.detail == "schedule" ? String(localized: "\(p.displayName) is off by schedule.")
                : String(localized: "Daily limit reached for \(p.displayName).")
        }
        if v.ruleID == Friends.storyGateID {
            if v.reason == "bounced" {
                return igSettings.profileStories
                    ? String(localized: "Their stories only. You're back on their profile.")
                    : String(localized: "Stories from outside your rules are off. Their profile still works.")
            }
            return String(localized: "Skipped a story outside your rules.")
        }
        let isShortFormRule = v.ruleID.flatMap { id in recipes[p]?.routes.first { $0.id == id }?.shortForm } ?? false
        if isShortFormRule, limitStatus.shortFormMode(p) == .forcedBlocked {
            return limitStatus.shortFormReason(p) == .shortFormSchedule
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

    /// Show one toast. The same `kind` within 2 s merges into the toast on screen; `merged`
    /// words the count ("Hidden 3 accounts"). Gone ~2 s after its last update.
    func showToast(_ text: String, kind: String, merged: ((Int) -> String)? = nil) {
        let now = Date()
        toasts.post(kind: kind, at: now) { n in n == 1 ? text : (merged?(n) ?? text) }
        let id = toasts.current?.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ToastCenter.displayFor))
            guard let self, self.toasts.current?.id == id else { return }
            self.toasts.expire(at: Date())
        }
    }

    // MARK: Lock grace period

    /// Seconds left to undo the Lock, or nil.
    func graceRemaining(now: ClockSample = SystemClockSource().sample()) -> TimeInterval? {
        guard policy.lockEnabled else { return nil }
        return lock.grace?.remaining(at: now)
    }

    #if DEBUG
    // MARK: Debug reset (compiled out of Release; scripts/check-release-no-debug-reset.sh)

    static let debugResetMarker = "BZ_DEBUG_RESET_MARKER"

    /// Wipe everything breakZero stored, including each lite view's web data, then close the app.
    func resetAllDataAndQuit() async {
        log(Self.debugResetMarker)
        for c in controllers.values { c.webView.stopLoading() }
        controllers = [:]
        try? FileManager.default.removeItem(at: store.directory)
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        for p in Platform.allCases {
            try? await WKWebsiteDataStore.remove(forIdentifier: LiteWebController.dataStoreID(p))
        }
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        exit(0)
    }
    #endif

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
