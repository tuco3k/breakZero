// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
import Core
import SwiftUI

/// Settings, lock, pending queue. Every change goes through the ratchet: tightening applies now,
/// less-strict changes wait for the cooldown.
struct WallView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut: Platform?
    /// Turning on something cooldown-protected asks first (press and hold).
    @State private var confirm: LockConfirmation?
    @State private var pickingHardLock = false
    @State private var showExplainer = false
    @Environment(\.openURL) private var openURL
    /// The explainer opens by itself once, the first time the Wall tab is shown.
    @AppStorage("bz.seenWallExplainer") private var seenExplainer = false

    var body: some View {
        @Bindable var model = model
        List {
            graceBanner
            Section {
                Button { showExplainer = true } label: {
                    Label(String(localized: "What is the Wall?"), systemImage: "questionmark.circle")
                }
            }
            lockSection
            if !model.lock.pending.isEmpty { pendingSection }
            accountsSection
            LimitsSection(submit: { submit($0) })
            platformsSection
            ForEach(model.policy.enabledPlatforms) { p in platformSection(p) }
            passSection
            Section {
                Button { sendFeedback() } label: {
                    Label(String(localized: "Send feedback"), systemImage: "envelope")
                }
            } footer: {
                Text("Opens an email with the app version, iOS version and phone model. Nothing else is attached.")
            }
            Section {
                Text(BetaInfo.versionLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    // Hidden entry to Diagnostics (Phase 0 spikes): tap the version five times.
                    .onTapGesture(count: 5) { model.showDiagnostics = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Tap five times to open diagnostics"))
            }
        }
        .navigationTitle(String(localized: "Wall"))
        .task { await model.refreshSessions() }
        .onAppear {
            if !seenExplainer {
                seenExplainer = true
                showExplainer = true
            }
        }
        .sheet(isPresented: $showExplainer) { WallExplainerView() }
        .confirmationDialog(
            confirmSignOut.map { String(localized: "Sign out of \($0.displayName)?") } ?? "",
            isPresented: Binding(get: { confirmSignOut != nil }, set: { if !$0 { confirmSignOut = nil } }),
            titleVisibility: .visible,
            presenting: confirmSignOut
        ) { p in
            Button(String(localized: "Sign out"), role: .destructive) {
                Task { await model.signOut(p) }
            }
        } message: { p in
            Text("This deletes \(p.displayName)'s cookies in breakZero only. Your other accounts stay signed in.")
        }
        .navigationDestination(isPresented: $model.showDiagnostics) { DiagnosticsView() }
        .sheet(item: $confirm) { c in
            ConfirmLockSheet(confirmation: c, facts: WallExplainer.Facts(model: model)) {
                switch c {
                case .lock: submit(.setLockEnabled(true))
                case .denyRemoval: submit(.setDenyAppRemoval(true))
                case let .hardLock(until): submit(.setHardLock(until: until))
                }
            }
        }
        .sheet(isPresented: $pickingHardLock) {
            HardLockPicker { until in
                pickingHardLock = false
                confirm = .hardLock(until)
            }
        }
    }

    /// Right after the Lock goes on: a countdown with Undo (QUESTIONS #53). Only in the list while
    /// the window is open (a TimelineView in a List always takes a row, even when empty).
    @ViewBuilder private var graceBanner: some View {
        if model.graceRemaining() != nil {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("The Lock is on").font(.headline)
                            if let left = model.graceRemaining() {
                                Text("You can undo it for \(Duration.seconds(left.rounded(.up)).formatted(.time(pattern: .minuteSecond)))")
                                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            } else {
                                Text("The undo window has ended.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if model.graceRemaining() != nil {
                            Button(String(localized: "Undo")) { submit(.setLockEnabled(false)) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private var lockSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.policy.lockEnabled },
                                 set: { on in if on { confirm = .lock } else { submit(.setLockEnabled(false)) } })) {
                Self.row(String(localized: "Lock"),
                         String(localized: "Locks your settings: stricter changes apply now, less strict ones wait \(Self.format(model.policy.cooldown))."))
            }
            Picker(selection: Binding(get: { model.policy.cooldown }, set: { submit(.setCooldown($0)) })) {
                ForEach(Self.cooldownOptions, id: \.self) { Text(Self.format($0)).tag($0) }
            } label: {
                Self.row(String(localized: "Cooldown"), String(localized: "How long a less-strict change waits before it applies."))
            }
            Picker(selection: Binding(get: { model.policy.lockGraceSeconds }, set: { submit(.setLockGrace(seconds: $0)) })) {
                Text("Off").tag(TimeInterval(0))
                Text("1 min").tag(TimeInterval(60))
                Text("5 min").tag(TimeInterval(300))
                Text("10 min").tag(TimeInterval(600))
            } label: {
                Self.row(String(localized: "Undo time"), String(localized: "How long you can undo turning the Lock on. It can only be made shorter."))
            }
            Toggle(isOn: Binding(get: { model.policy.denyAppRemoval },
                                 set: { on in if on { confirm = .denyRemoval } else { submit(.setDenyAppRemoval(false)) } })) {
                #if BZ_SCREEN_TIME
                Self.row(String(localized: "Block deleting breakZero"), String(localized: "While locked, breakZero can't be deleted from this iPhone."))
                #else
                Self.row(String(localized: "Block deleting breakZero"), String(localized: "Needs Apple's Screen Time permission, which this version doesn't have, so it does nothing here yet."))
                #endif
            }
            if let h = model.policy.hardLock, h.until > Date() {
                LabeledContent {
                    Text(h.until.formatted(date: .abbreviated, time: .shortened))
                } label: {
                    Self.row(String(localized: "Hard Lock"), String(localized: "Until then, nothing can be made less strict."))
                }
            } else {
                Button { pickingHardLock = true } label: {
                    Self.row(String(localized: "Hard Lock…"), String(localized: "Pick a date. Until then, nothing can be made less strict at all."))
                }
            }
        } header: {
            Text("The Wall")
        } footer: {
            Text("Stricter changes apply right away. Less strict ones (turning a block off, raising a limit, more or longer passes, a shorter cooldown, turning the Lock off) wait for the cooldown. You can cancel a waiting change anytime.")
        }
    }

    /// A setting's name with a one-line plain description underneath.
    static func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.primary)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One row per platform: signed in or out (from cookie names), and a sign-out that clears
    /// only that platform's cookies.
    private var accountsSection: some View {
        Section {
            ForEach(model.policy.enabledPlatforms) { p in
                HStack {
                    Label(p.displayName, systemImage: p.symbolName)
                    Spacer()
                    switch model.sessions[p] {
                    case .some(true):
                        Text("Signed in").foregroundStyle(.secondary)
                        Button(String(localized: "Sign out")) { confirmSignOut = p }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Sign out of \(p.displayName)"))
                    case .some(false):
                        Text("Signed out").foregroundStyle(.secondary)
                    case .none:
                        ProgressView().accessibilityLabel(Text("Checking"))
                    }
                }
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Sign in inside each tab. Signing out deletes only that site's cookies in breakZero.")
        }
    }

    /// Which lite tabs exist. Neutral (instant both ways): a tab is a view, not a restriction.
    private var platformsSection: some View {
        Section {
            ForEach(Platform.allCases) { p in
                Toggle(isOn: Binding(get: { model.policy.enabledPlatforms.contains(p) },
                                     set: { submit(.setPlatformEnabled(p, $0)) })) {
                    VStack(alignment: .leading) {
                        Text(p.displayName)
                        if p == .snapchat {
                            Text("Draft: web chat may not work on iPhone yet.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Platforms")
        }
    }

    private var pendingSection: some View {
        Section {
            ForEach(model.lock.pending) { p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(Self.describe(p.change, policy: model.policy))
                        Text("About \(p.estimatedDue.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { model.cancelPending(p.id) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Cancel pending change: \(Self.describe(p.change, policy: model.policy))"))
                }
            }
        } header: {
            Text("Waiting to apply")
        } footer: {
            Text("Changes that make breakZero less strict wait here until their time. Cancel any of them anytime.")
        }
    }

    private func platformSection(_ p: Platform) -> some View {
        Section(p.displayName) {
            if let recipe = model.recipes[p] {
                if recipe.landing.options.count > 1 {
                    Picker(selection: Binding(get: { model.policy.settings(for: p).landing ?? recipe.landing.default },
                                              set: { submit(.setLanding(p, key: $0)) })) {
                        ForEach(recipe.landing.options.keys.sorted(), id: \.self) { key in
                            Text(ToggleTitles.landing(key)).tag(key)
                        }
                    } label: {
                        Self.row(String(localized: "Opens on"), String(localized: "The first page you see in this tab."))
                    }
                }
                if recipe.friendsFilter != nil {
                    NavigationLink {
                        FeedRulesView()
                    } label: {
                        LabeledContent {
                            Text(model.feedRulesOn ? model.feedRuleName : String(localized: "Off"))
                        } label: {
                            Self.row(String(localized: "Feed rules"), String(localized: "Whose posts and stories your home feed shows."))
                        }
                    }
                }
                if recipe.search != nil {
                    Picker(selection: Binding(get: { model.policy.settings(for: p).search }, set: { submit(.setSearchMode(p, $0)) })) {
                        Text("Normal").tag(SearchMode.normal)
                        Text("Only accounts that match my feed rules").tag(SearchMode.matching)
                        Text("Off").tag(SearchMode.off)
                    } label: {
                        Self.row(String(localized: "Search"), String(localized: "What search shows. The Explore grid stays hidden either way."))
                    }
                }
                // Old Instagram's own switches live on its screen.
                ForEach(recipe.toggles.filter { $0.id != recipe.friendsFilter?.toggle && $0.id != recipe.friendsFilter?.forceFollowingToggle },
                        id: \.id) { t in
                    Toggle(isOn: Binding(
                        get: { model.policy.settings(for: p).isOn(t.id, in: recipe) },
                        set: { submit(.setToggle(p, id: t.id, on: $0)) })) {
                        Self.row(ToggleTitles.title(t.id), ToggleTitles.detail(t.id))
                    }
                }
            }
        }
    }

    private var passSection: some View {
        Section {
            Stepper(value: Binding(get: { model.policy.pass.durationMinutes }, set: { submit(.setPassDuration(minutes: $0)) }),
                    in: 1...60) {
                Self.row(String(localized: "Pass length: \(model.policy.pass.durationMinutes) min"), String(localized: "How long one pass lasts."))
            }
            Stepper(value: Binding(get: { model.policy.pass.waitSeconds }, set: { submit(.setPassWait(seconds: $0)) }),
                    in: 0...600, step: 10) {
                Self.row(String(localized: "Wait before a pass: \(model.policy.pass.waitSeconds) s"), String(localized: "How long you wait after asking, before it starts."))
            }
            Stepper(value: Binding(get: { model.policy.pass.dailyCap }, set: { submit(.setPassCap($0)) }),
                    in: 0...20) {
                Self.row(String(localized: "Passes per day: \(model.policy.pass.dailyCap)"), String(localized: "How many passes you can use in a day."))
            }
        } header: {
            Text("Passes")
        } footer: {
            #if BZ_SCREEN_TIME
            Text("A pass opens a blocked app for a few minutes, for things the web can't do (music on stories, close friends). Every pass is saved on this phone with the reason you gave.")
            #else
            Text("In this version a pass adds a few minutes in breakZero after a time limit or schedule stopped you. Every pass is saved on this phone with the reason you gave.")
            #endif
        }
    }

    private func submit(_ change: PolicyChange) {
        let results = model.submit([change])
        switch results.first {
        case .queued(let p):
            model.showToast(String(localized: "That makes breakZero less strict, so it applies \(p.estimatedDue.formatted(date: .abbreviated, time: .shortened)). You can cancel it until then."),
                            kind: "wall.queued")
        case .rejectedHardLock(let until):
            model.showToast(String(localized: "Hard Lock is on until \(until.formatted(date: .abbreviated, time: .shortened)). Nothing can be made less strict before then."),
                            kind: "wall.hardlock")
        case .rejectedInvalid(let why):
            model.showToast(why, kind: "wall.invalid")
        default:
            break
        }
    }

    private func sendFeedback() {
        guard let url = BetaInfo.feedbackURL(version: BetaInfo.version, build: BetaInfo.build,
                                             os: UIDevice.current.systemVersion, device: BetaInfo.deviceModel) else { return }
        openURL(url) { accepted in
            if !accepted { model.showToast(String(localized: "No mail app. Write to \(BetaInfo.feedbackEmail)"), kind: "feedback") }
        }
    }

    static func searchName(_ m: SearchMode) -> String {
        switch m {
        case .normal: String(localized: "Normal")
        case .matching: String(localized: "only accounts that match my feed rules")
        case .off: String(localized: "off")
        }
    }

    static let cooldownOptions: [TimeInterval] = [3600, 6 * 3600, 12 * 3600, 86400, 2 * 86400, 3 * 86400, 7 * 86400]

    static func format(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 86400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: t) ?? "\(Int(t))s"
    }

    /// - policy: used to name a schedule being removed (it stays in the policy until the change applies).
    static func describe(_ c: PolicyChange, policy: WallPolicy) -> String {
        switch c {
        case let .setToggle(p, id, on): "\(p.displayName): \(ToggleTitles.title(id)) \(on ? "on" : "off")"
        case let .removeCustomBlock(p, pattern): "\(p.displayName): remove block \(pattern)"
        case let .removeCustomHide(p, s): "\(p.displayName): remove hide \(s)"
        case .setShields: String(localized: "Change shielded apps")
        case let .setPassDuration(m): String(localized: "Pass length \(m) min")
        case let .setPassWait(s): String(localized: "Pass wait \(s) s")
        case let .setPassCap(n): String(localized: "\(n) passes per day")
        case let .setCooldown(t): String(localized: "Cooldown \(format(t))")
        case let .setLockEnabled(on): on ? String(localized: "Lock on") : String(localized: "Lock off")
        case let .setDenyAppRemoval(on): on ? String(localized: "Block deleting breakZero") : String(localized: "Allow deleting breakZero")
        case .setHardLock: String(localized: "Change Hard Lock")
        case let .setDailyLimit(p, m?): String(localized: "\(p.displayName): \(m) min a day")
        case let .setDailyLimit(p, nil): String(localized: "\(p.displayName): no daily limit")
        case let .setShortFormBudget(m): m == 0 ? String(localized: "Reels/Shorts budget off") : String(localized: "Reels/Shorts: \(m) min a day")
        case let .addFriend(p, u): String(localized: "\(p.displayName): add @\(u) to My list")
        case let .removeFriend(p, u): String(localized: "\(p.displayName): remove @\(u) from My list")
        case let .addPerson(p, l, u): String(localized: "\(p.displayName): add @\(u) to \(AppModel.listName(l))")
        case let .removePerson(p, l, u): String(localized: "\(p.displayName): remove @\(u) from \(AppModel.listName(l))")
        case let .setAudience(p, surface, a):
            String(localized: "\(p.displayName): \(surface == .feed ? String(localized: "feed") : String(localized: "stories")) shows \(AppModel.audienceName(a))")
        case let .setProfileStories(p, on): on ? String(localized: "\(p.displayName): play stories from profiles")
            : String(localized: "\(p.displayName): no stories from profiles")
        case let .setLockGrace(t): String(localized: "Undo time \(Int(t / 60)) min")
        case let .setSearchMode(p, m): String(localized: "\(p.displayName) search: \(Self.searchName(m))")
        case let .setDailyTotal(m?): String(localized: "All apps: \(m) min a day")
        case .setDailyTotal(nil): String(localized: "All apps: no daily limit")
        case let .setPlatformShortFormBudget(p, m?): String(localized: "\(p.displayName) short videos: \(m) min a day")
        case let .setPlatformShortFormBudget(p, nil): String(localized: "\(p.displayName) short videos: own budget off")
        case let .removeSchedule(id):
            String(localized: "Remove schedule: ")
                + (policy.limits.schedules.first { $0.id == id }.map { LimitsSection.targetName($0.target) + ", " + LimitsSection.window($0) } ?? "?")
        default: String(describing: c)
        }
    }

}

/// User-facing names for recipe toggles. Recipes stay language-independent; titles live here.
enum ToggleTitles {
    static func title(_ id: String) -> String {
        switch id {
        case "ig.blockReels": String(localized: "Block the Reels feed")
        case "ig.blockExplore": String(localized: "Block Explore")
        case "ig.blockShop": String(localized: "Block Shop")
        case "ig.hideReelsEntryPoints": String(localized: "Hide Reels buttons and links")
        case "ig.hideSuggested": String(localized: "Hide suggested accounts")
        case "ig.hideSponsored": String(localized: "Hide sponsored posts")
        case "ig.hideFeed": String(localized: "Hide the home feed entirely")
        case "ig.friendsOnly": String(localized: "Friends only (Old Instagram)")
        case "ig.forceFollowing": String(localized: "Always open the Following feed")
        case "yt.landOnSubscriptions": String(localized: "Open on Subscriptions")
        case "yt.shortsAsVideos": String(localized: "Play Shorts as normal videos")
        case "yt.hideShorts": String(localized: "Hide Shorts shelves and tabs")
        case "yt.hideRecommendations": String(localized: "Hide home recommendations")
        case "yt.hideRelated": String(localized: "Hide related videos")
        case "yt.hideEndScreen": String(localized: "Hide end-screen cards")
        case "yt.autoplayOff": String(localized: "Autoplay off")
        case "yt.hideComments": String(localized: "Hide comments")
        case "sc.blockSpotlight": String(localized: "Block Spotlight")
        case "sc.blockDiscover": String(localized: "Block Discover and Stories browsing")
        case "sc.hideDiscoveryLinks": String(localized: "Hide Spotlight and Discover links")
        default: id
        }
    }

    /// One plain line under each switch.
    static func detail(_ id: String) -> String {
        switch id {
        case "ig.blockReels": String(localized: "The endless Reels feed is closed. A reel someone sends you still plays.")
        case "ig.blockExplore": String(localized: "The Explore page of suggested posts is closed.")
        case "ig.blockShop": String(localized: "The Shop pages are closed.")
        case "ig.hideReelsEntryPoints": String(localized: "Removes the Reels button and Reels links.")
        case "ig.hideSuggested": String(localized: "Removes \"Suggested for you\" accounts.")
        case "ig.hideSponsored": String(localized: "Removes ads in the feed.")
        case "ig.hideFeed": String(localized: "No home feed at all: stories and messages only.")
        case "ig.friendsOnly": String(localized: "Your home feed shows only the people your feed rules allow.")
        case "ig.forceFollowing": String(localized: "The home feed opens on posts from people you follow, newest first.")
        case "yt.landOnSubscriptions": String(localized: "Starts on your subscriptions instead of recommendations.")
        case "yt.shortsAsVideos": String(localized: "A Short opens as a normal video, without the swipe feed.")
        case "yt.hideShorts": String(localized: "Removes Shorts rows and the Shorts tab.")
        case "yt.hideRecommendations": String(localized: "Removes recommended videos on the home page.")
        case "yt.hideRelated": String(localized: "Removes the list of related videos next to a video.")
        case "yt.hideEndScreen": String(localized: "Removes the video suggestions at the end of a video.")
        case "yt.autoplayOff": String(localized: "A finished video doesn't start the next one.")
        case "yt.hideComments": String(localized: "Removes comments under videos.")
        case "sc.blockSpotlight": String(localized: "The Spotlight video feed is closed.")
        case "sc.blockDiscover": String(localized: "Discover and browsing other people's stories are closed.")
        case "sc.hideDiscoveryLinks": String(localized: "Removes Spotlight and Discover buttons and links.")
        default: ""
        }
    }

    static func landing(_ key: String) -> String {
        switch key {
        case "inbox": String(localized: "Messages")
        case "following": String(localized: "Following feed")
        case "subscriptions": String(localized: "Subscriptions")
        case "library": String(localized: "Library")
        case "search": String(localized: "Search")
        case "chat": String(localized: "Chats")
        default: key
        }
    }
}

/// What a press-and-hold confirmation is for.
enum LockConfirmation: Identifiable, Equatable {
    case lock, denyRemoval, hardLock(Date)
    var id: String {
        switch self {
        case .lock: "lock"
        case .denyRemoval: "deny"
        case let .hardLock(d): "hard-\(d.timeIntervalSince1970)"
        }
    }
}

/// Plain words on what is about to be locked, confirmed by pressing and holding (QUESTIONS #53).
struct ConfirmLockSheet: View {
    @Environment(\.dismiss) private var dismiss
    let confirmation: LockConfirmation
    let facts: WallExplainer.Facts
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(lines, id: \.self) { Text($0) }
                    HoldToConfirmButton(title: String(localized: "Hold to turn on")) {
                        onConfirm()
                        dismiss()
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var wait: String { WallExplainer.duration(facts.cooldown) }

    private var title: String {
        switch confirmation {
        case .lock: String(localized: "Turn on the Lock?")
        case .denyRemoval: String(localized: "Block deleting breakZero?")
        case .hardLock: String(localized: "Turn on Hard Lock?")
        }
    }

    /// The short version of "What is the Wall?" for what's about to be turned on.
    private var lines: [String] {
        switch confirmation {
        case .lock:
            return WallExplainer.confirmation(facts)
        case .denyRemoval:
            return [
                String(localized: "breakZero can't be deleted from the home screen or Settings while this is on."),
                String(localized: "Turning it off again waits \(wait)."),
            ]
        case let .hardLock(until):
            return [
                String(localized: "Until \(until.formatted(date: .abbreviated, time: .shortened)), nothing can be made less strict at all, not even after waiting."),
                String(localized: "Changing the phone's clock doesn't end it early."),
            ]
        }
    }
}

/// A deliberate action instead of a single tap: press and hold for 1.5 s. VoiceOver users get an
/// explicit "Confirm" action instead of a hold.
struct HoldToConfirmButton: View {
    let title: String
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var holding = false

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(alignment: .leading) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.accentColor.opacity(0.45))
                        Capsule().fill(Color.accentColor).frame(width: g.size.width * progress)
                    }
                }
            }
            .clipShape(Capsule())
            .onLongPressGesture(minimumDuration: 1.5, maximumDistance: 40) {
                action()
            } onPressingChanged: { pressing in
                holding = pressing
                withAnimation(pressing ? .linear(duration: 1.5) : .easeOut(duration: 0.2)) { progress = pressing ? 1 : 0 }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(title))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Confirm")) { action() }
    }
}

struct HardLockPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var until = Date().addingTimeInterval(7 * 86400)
    let onPick: (Date) -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(String(localized: "Locked until"), selection: $until, in: Date().addingTimeInterval(3600)...,
                           displayedComponents: [.date, .hourAndMinute])
            }
            .navigationTitle(String(localized: "Hard Lock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Next")) { onPick(until) } }
            }
        }
    }
}
