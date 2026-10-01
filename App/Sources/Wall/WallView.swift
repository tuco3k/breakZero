// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
import Core
import SwiftUI

/// Settings, lock, pending queue. Every change goes through the ratchet: tightening applies now,
/// loosening waits for the cooldown.
struct WallView: View {
    @Environment(AppModel.self) private var model
    @State private var resultText: String?
    @State private var confirmSignOut: Platform?
    @State private var showExplainer = false
    /// The explainer opens by itself once, the first time the Wall tab is shown.
    @AppStorage("bz.seenWallExplainer") private var seenExplainer = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                Button { showExplainer = true } label: {
                    Label(String(localized: "What is the wall?"), systemImage: "questionmark.circle")
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
                Text(versionString)
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
        .alert(resultText ?? "", isPresented: Binding(get: { resultText != nil }, set: { if !$0 { resultText = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var lockSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.policy.lockEnabled }, set: { submit(.setLockEnabled($0)) })) {
                VStack(alignment: .leading) {
                    Text("Lock")
                    Text("Loosening waits \(Self.format(model.policy.cooldown))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Cooldown", selection: Binding(get: { model.policy.cooldown }, set: { submit(.setCooldown($0)) })) {
                ForEach(Self.cooldownOptions, id: \.self) { Text(Self.format($0)).tag($0) }
            }
            Toggle("Block deleting breakZero", isOn: Binding(get: { model.policy.denyAppRemoval },
                                                             set: { submit(.setDenyAppRemoval($0)) }))
        } header: {
            Text("The wall")
        } footer: {
            Text("Tightening applies now. Loosening — turning a rule off, longer or more passes, a shorter cooldown, unlocking — applies only after the cooldown. You can cancel a pending change any time.")
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
        Section("Waiting to apply") {
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
        }
    }

    private func platformSection(_ p: Platform) -> some View {
        Section(p.displayName) {
            if let recipe = model.recipes[p] {
                if recipe.landing.options.count > 1 {
                    Picker("Opens on", selection: Binding(get: { model.policy.settings(for: p).landing ?? recipe.landing.default },
                                                          set: { submit(.setLanding(p, key: $0)) })) {
                        ForEach(recipe.landing.options.keys.sorted(), id: \.self) { key in
                            Text(ToggleTitles.landing(key)).tag(key)
                        }
                    }
                }
                if recipe.friendsFilter != nil {
                    NavigationLink {
                        FriendsView()
                    } label: {
                        LabeledContent(String(localized: "Old Instagram (friends only)"),
                                       value: model.friendsActive ? String(localized: "On") : String(localized: "Off"))
                    }
                }
                // Old Instagram's own switches live on its screen.
                ForEach(recipe.toggles.filter { $0.id != recipe.friendsFilter?.toggle && $0.id != recipe.friendsFilter?.forceFollowingToggle },
                        id: \.id) { t in
                    Toggle(ToggleTitles.title(t.id), isOn: Binding(
                        get: { model.policy.settings(for: p).isOn(t.id, in: recipe) },
                        set: { submit(.setToggle(p, id: t.id, on: $0)) }))
                }
            }
        }
    }

    private var passSection: some View {
        Section {
            Stepper("Pass length: \(model.policy.pass.durationMinutes) min",
                    value: Binding(get: { model.policy.pass.durationMinutes }, set: { submit(.setPassDuration(minutes: $0)) }),
                    in: 1...60)
            Stepper("Wait before a pass: \(model.policy.pass.waitSeconds) s",
                    value: Binding(get: { model.policy.pass.waitSeconds }, set: { submit(.setPassWait(seconds: $0)) }),
                    in: 0...600, step: 10)
            Stepper("Passes per day: \(model.policy.pass.dailyCap)",
                    value: Binding(get: { model.policy.pass.dailyCap }, set: { submit(.setPassCap($0)) }),
                    in: 0...20)
        } header: {
            Text("Native passes")
        } footer: {
            Text("A pass opens one shielded app for a few minutes, for things the web can't do (music on stories, close friends). Every pass is logged on this phone only.")
        }
    }

    private func submit(_ change: PolicyChange) {
        let results = model.submit([change])
        switch results.first {
        case .queued(let p):
            resultText = String(localized: "That loosens the wall, so it applies \(p.estimatedDue.formatted(date: .abbreviated, time: .shortened)). You can cancel it until then.")
        case .rejectedHardLock(let until):
            resultText = String(localized: "Hard Lock is on until \(until.formatted(date: .abbreviated, time: .shortened)). Nothing can be loosened before then.")
        case .rejectedInvalid(let why):
            resultText = why
        default:
            break
        }
    }

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "breakZero \(v) (\(b))"
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
        case let .addFriend(p, u): String(localized: "\(p.displayName): add friend @\(u)")
        case let .removeFriend(p, u): String(localized: "\(p.displayName): remove friend @\(u)")
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
