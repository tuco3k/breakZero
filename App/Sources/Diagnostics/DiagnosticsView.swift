// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
// Phase 0 spikes S1–S7 (BRIEF §6). Each button does one thing and writes to the shared log, which
// the extensions also write to. Results get reported back by the owner (docs/ON_DEVICE_CHECKLIST.md).
// Without the BZ_SCREEN_TIME Swift flag (plain `xcodegen generate`), every Screen Time call is compiled out;
// the web-view spikes still work.
import Core
import FamilyControls
import LiteWeb
import Shielding
import SwiftUI
import UserNotifications
import WebKit

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [DiagnosticsEntry] = []
    @State private var pickerShown = false
    @State private var selection = FamilyActivitySelection()
    @State private var probe: Probe?
    @State private var results = SpikeResults()
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                ForEach(SpikeCatalog.all) { spike in
                    SpikeRow(spike: spike, result: results.result(spike.id)) { status in
                        results.set(spike.id, status, note: String(localized: "Set by hand"), source: .owner)
                        results.save(model.store)
                    }
                }
            } header: { Text("Spike results") } footer: {
                Text("PASS and FAIL come from a check run here or from what you reported. UNKNOWN means not tested yet.")
            }

            #if !BZ_SCREEN_TIME
            Section {
                Text("iOS \(UIDevice.current.systemVersion) · Screen Time is compiled out of this build. S1 shielding, S5 and S7 need a build generated with BZ_SCREEN_TIME=YES.")
                    .font(.footnote)
            } header: { Text("Setup") }
            #else
            Section {
                Text("iOS \(UIDevice.current.systemVersion) · Screen Time: \(FamilyControlsAuthorization().currentStatus().rawValue)")
                    .font(.footnote)
                Button("Request Screen Time authorization (.individual)") {
                    Task {
                        do {
                            try await FamilyControlsAuthorization.request()
                            log("authorization: \(FamilyControlsAuthorization().currentStatus().rawValue)")
                        } catch { log("authorization failed: \(error.localizedDescription)") }
                    }
                }
                Button("Pick apps for spikes (Instagram, YouTube…)") { pickerShown = true }
            } header: { Text("Setup") }
            #endif

            Section {
                #if BZ_SCREEN_TIME
                Button("Shield picked apps (diagnostics store)") { log(DiagnosticsShield.shield(model.store)) }
                #endif
                Button("Load instagram.com in a test web view (shared store)") { probe = .init(url: "https://www.instagram.com/", store: .shared, ua: .webKitDefault) }
                Button("Load youtube.com in a test web view (shared store)") { probe = .init(url: "https://m.youtube.com/", store: .shared, ua: .webKitDefault) }
                Button("Load instagram.com in a test web view (named store)") { probe = .init(url: "https://www.instagram.com/", store: .named, ua: .webKitDefault) }
                Button("Load youtube.com in a test web view (named store)") { probe = .init(url: "https://m.youtube.com/", store: .named, ua: .webKitDefault) }
                Button("Open instagram.com in Safari") { UIApplication.shared.open(URL(string: "https://www.instagram.com/")!) }
                Button("Open youtube.com in Safari") { UIApplication.shared.open(URL(string: "https://www.youtube.com/")!) }
                #if BZ_SCREEN_TIME
                Button("Clear diagnostics shields", role: .destructive) { DiagnosticsShield.clear(); log("diagnostics shields cleared") }
                #endif
            } header: { Text("S1 · Shield bleed") } footer: {
                Text("Pick Instagram + YouTube, shield them, then load each site here and in Safari. The log records load success or the error code.")
            }

            Section {
                Button("YouTube sign-in · WebKit UA") { probe = .init(url: Self.youtubeLogin, store: .platform(.youtube), ua: .webKitDefault) }
                Button("YouTube sign-in · Safari UA") { probe = .init(url: Self.youtubeLogin, store: .platform(.youtube), ua: .safari) }
                Button("Check YouTube session (cookie names only)") { checkSession(.youtube, names: ["SID", "__Secure-3PSID", "LOGIN_INFO", "SAPISID"]) }
            } header: { Text("S2 · YouTube login") } footer: {
                Text("Try both. Note whether Google shows “disallowed_useragent”. Relaunch the app, then check the session. Only cookie names are logged, never values.")
            }

            Section {
                Button("Instagram inbox · WebKit UA") { probe = .init(url: "https://www.instagram.com/direct/inbox/", store: .platform(.instagram), ua: .webKitDefault) }
                Button("Instagram inbox · Safari UA") { probe = .init(url: "https://www.instagram.com/direct/inbox/", store: .platform(.instagram), ua: .safari) }
                Button("Check Instagram session (cookie names only)") { checkSession(.instagram, names: ["sessionid", "ds_user_id", "csrftoken"]) }
            } header: { Text("S3 · Instagram DMs") } footer: {
                Text("Test: open thread, send text and photo, start a new chat, open a reel from a DM, reply. Then relaunch and re-check the session.")
            }

            Section {
                Button("Report what the feed is made of") { Task { await feedReport() } }
                Button("Watch the feed for flashes (30 s)") { Task { await flashWatch() } }
            } header: { Text("F1 · Feed never flashes") } footer: {
                Text("Sign in to Instagram first. The report logs counts and tag shapes only (no names). The watch switches to the Instagram tab: scroll the feed up and down for 30 seconds; every frame it counts posts that were visible before being approved. The result lands in the log and under Spike results.")
            }

            Section {
                Button("Run S9 again · Does ?variant=following stick?") {
                    probe = .init(url: "https://www.instagram.com/?variant=following", store: .platform(.instagram), ua: .webKitDefault,
                                  check: .followingVariant)
                }
                Button("Run S10 again · Can we open Close Friends?") {
                    probe = .init(url: "https://www.instagram.com/accounts/close_friends/", store: .platform(.instagram), ua: .webKitDefault,
                                  check: .closeFriends)
                }
            } header: { Text("S9–S10 · Old Instagram") } footer: {
                Text("Sign in to Instagram in its tab first. Each check runs by itself in an unfiltered web view (about 15 s) and logs one result line: S9 loads the Following feed, taps Home, goes back, and says whether the variant stayed and whether it stayed on mobile web. S10 says whether the Close Friends page opens and how many checked rows it shows (counts only, no names).")
            }

            Section {
                Button("web.snapchat.com · WebKit UA") { probe = .init(url: "https://web.snapchat.com/", store: .platform(.snapchat), ua: .webKitDefault) }
                Button("web.snapchat.com · desktop Safari UA") { probe = .init(url: "https://web.snapchat.com/", store: .platform(.snapchat), ua: .desktopSafari) }
                Button("web.snapchat.com · mobile Safari UA") { probe = .init(url: "https://web.snapchat.com/", store: .platform(.snapchat), ua: .safari) }
                Button("Check Snapchat session (cookie names only)") {
                    Task {
                        let names = await LiteSession.cookieNames(.snapchat).map(\.name).sorted()
                        log("snapchat cookie names: \(names.joined(separator: " "))")
                    }
                }
            } header: { Text("S8 · Snapchat web chat") } footer: {
                Text("Does web.snapchat.com load, let you sign in, and let you open a chat and send a message? Try each user agent. The cookie-name list helps finish the draft recipe's sign-in check.")
            }

            Section {
                Button("Ask for notification permission") {
                    Task {
                        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                        log("notification permission: \(ok)")
                    }
                }
                Button("Post a test local notification in 5 s") { postTestNotification() }
            } header: { Text("S4 · Notifications") } footer: {
                Text("With Instagram shielded, have someone message you: does a notification arrive? Then start an S7 pass and repeat.")
            }

            #if BZ_SCREEN_TIME
            Section {
                Button("Set denyAppRemoval (diagnostics store)") { DiagnosticsShield.setDenyAppRemoval(true); log("denyAppRemoval = true") }
                Button("Clear denyAppRemoval", role: .destructive) { DiagnosticsShield.setDenyAppRemoval(false); log("denyAppRemoval cleared") }
                ForEach(Self.revocationPaths, id: \.self) { path in
                    HStack {
                        Text(path).font(.footnote)
                        Spacer()
                        Button("Held") { log("S5 \(path): HELD (iOS \(UIDevice.current.systemVersion))") }.buttonStyle(.bordered)
                        Button("Bypassed") { log("S5 \(path): BYPASSED (iOS \(UIDevice.current.systemVersion))") }.buttonStyle(.bordered)
                    }
                }
            } header: { Text("S5 · Wall") } footer: {
                Text("Set a Screen Time passcode first. Try each path, then record what happened.")
            }
            #endif

            Section {
                Button("Warm both lite views, log memory in 10 s") {
                    _ = model.controller(for: .instagram)
                    _ = model.controller(for: .youtube)
                    Task {
                        try? await Task.sleep(for: .seconds(10))
                        log("S6 memory footprint: \(Self.memoryMB()) MB with \(model.controllers.count) web views")
                    }
                }
                Button("Log memory now") { log("S6 memory footprint: \(Self.memoryMB()) MB") }
            } header: { Text("S6 · Performance") } footer: {
                Text("Cold start: force-quit, launch, and read the “S6 first load” line. Content-process recovery is logged when it happens.")
            }

            #if BZ_SCREEN_TIME
            Section {
                Button("Start 5-min pass (backdated interval)") { startS7(backdate: true) }
                Button("Start 5-min pass (exact interval — tests the 15-min minimum)") { startS7(backdate: false) }
                Button("Start 16-min pass (exact interval)") { startS7(minutes: 16, backdate: false) }
            } header: { Text("S7 · Pass timing") } footer: {
                Text("Shield picked apps first. Start a pass, force-quit breakZero, and note when the app is shielded again. The monitor extension logs the exact time.")
            }
            #endif

            #if DEBUG
            Section {
                Button("Reset all breakZero data", role: .destructive) { confirmReset = true }
            } header: { Text("Debug build only") } footer: {
                Text("Clears every setting, the Lock, lists, limits, time records and every lite view's web data (you'll be signed out), then closes the app. Not in release builds.")
            }
            #endif

            Section {
                ForEach(entries.reversed()) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(e.at.formatted(date: .omitted, time: .standard)) · \(e.source)").font(.caption2).foregroundStyle(.secondary)
                        Text(e.message).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Log")
                    Spacer()
                    Button("Refresh") { refresh() }
                    ShareLink(item: entries.map { "\($0.at.ISO8601Format()) [\($0.source)] \($0.message)" }.joined(separator: "\n"))
                    Button("Clear", role: .destructive) { DiagnosticsLog.clear(model.store); refresh() }
                }
            }
        }
        .navigationTitle("Diagnostics")
        #if BZ_SCREEN_TIME
        .familyActivityPicker(isPresented: $pickerShown, selection: $selection)
        .onChange(of: selection) { _, new in
            do {
                try DiagnosticsShield.save(new, in: model.store)
                log("picked \(new.applicationTokens.count) apps, \(new.categoryTokens.count) categories, \(new.webDomainTokens.count) domains")
            } catch { log("saving selection failed: \(error)") }
        }
        #endif
        #if DEBUG
        .confirmationDialog("Reset all breakZero data?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset and close the app", role: .destructive) { Task { await model.resetAllDataAndQuit() } }
        }
        #endif
        .sheet(item: $probe) { p in
            NavigationStack {
                ProbeWebView(probe: p, log: log, record: { id, status, note in
                    results.set(id, status, note: note, source: .check)
                    results.save(model.store)
                })
                    .navigationTitle(p.url)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { probe = nil } }
            }
        }
        .onAppear {
            refresh()
            results = SpikeResults.load(model.store)
        }
    }

    static let youtubeLogin = "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fm.youtube.com%2F"

    static let revocationPaths = [
        "Screen Time › Apps with Screen Time Access",
        "Settings › Apps › breakZero",
        "Delete app (home screen)",
        "Delete app (Settings › General › iPhone Storage)",
        "Date & Time: turn off Set Automatically",
        "Change date forward 2 days",
    ]

    private func log(_ m: String) {
        DiagnosticsLog.append(model.store, source: "diag", m)
        refresh()
    }

    private func refresh() { entries = DiagnosticsLog.entries(model.store) }

    private func feedReport() async {
        await model.logFeedReport()
        refresh()
    }

    private func flashWatch() async {
        model.showToast(String(localized: "Scroll the feed for 30 seconds…"), kind: "diag.flash")
        guard let r = await model.runFeedCheck(seconds: 30, openFeed: false) else { return log("flash watch: Instagram isn't enabled") }
        let status: SpikeStatus = r.flashes > 0 ? .fail : (r.frames >= 300 ? .pass : .unknown)
        results.set("F1", status, note: "\(r.flashes) flash frames in \(r.frames)", source: .check)
        results.save(model.store)
        refresh()
        model.showToast(r.flashes == 0 ? String(localized: "No flashes in \(r.frames) frames.") : String(localized: "\(r.flashes) frames showed a post too early."),
                        kind: "diag.flash")
    }

    private func startS7(minutes: Double = 5, backdate: Bool) {
        do { log(try DiagnosticsShield.startPass(minutes: minutes, backdate: backdate, shared: model.store)) } catch {
            log("S7 startMonitoring failed (backdate=\(backdate), \(minutes) min): \(error)")
        }
    }

    private func checkSession(_ p: Platform, names: [String]) {
        let store = WKWebsiteDataStore(forIdentifier: ProbeWebView.platformStoreID(p))
        store.httpCookieStore.getAllCookies { cookies in
            let present = Set(cookies.map(\.name))
            let summary = names.map { "\($0)=\(present.contains($0) ? "present" : "absent")" }.joined(separator: " ")
            Task { @MainActor in log("session \(p.rawValue): \(summary)") }
        }
    }

    private func postTestNotification() {
        let c = UNMutableNotificationContent()
        c.title = "breakZero test"
        c.body = "Tap to open the Instagram lite tab."
        c.userInfo = [DeepLink.userInfoKey: DeepLink.lite(.instagram).absoluteString]
        let req = UNNotificationRequest(identifier: "bz.test", content: c,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        UNUserNotificationCenter.current().add(req) { error in
            Task { @MainActor in log(error.map { "test notification failed: \($0)" } ?? "test notification scheduled") }
        }
    }

    static func memoryMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "?" }
        return String(format: "%.1f", Double(info.phys_footprint) / 1_048_576)
    }
}

struct Probe: Identifiable {
    enum Store { case shared, named, platform(Platform) }
    /// A scripted spike that runs by itself after the first load and logs one result line.
    enum Check { case followingVariant, closeFriends }
    let url: String
    let store: Store
    let ua: UserAgentMode
    var check: Check? = nil
    let id = UUID()
}

/// A bare, unfiltered web view for spikes: logs every load outcome. Not a lite view.
struct ProbeWebView: UIViewRepresentable {
    let probe: Probe
    let log: (String) -> Void
    /// A scripted check's verdict for the Spike results section.
    var record: (String, SpikeStatus, String) -> Void = { _, _, _ in }

    static func platformStoreID(_ p: Platform) -> UUID { LiteWebController.dataStoreID(p) }

    func makeCoordinator() -> Coordinator { Coordinator(log: log, label: probe.url, check: probe.check, record: record) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        switch probe.store {
        case .shared: config.websiteDataStore = .default()
        case .named: config.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F1D7A52-3C0B-4C55-9E7A-1B0A6E1D00FF")!)
        case let .platform(p): config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.platformStoreID(p))
        }
        config.allowsInlineMediaPlayback = true
        // Before creating the view: WKWebView copies its configuration.
        if probe.ua == .desktopSafari { config.defaultWebpagePreferences.preferredContentMode = .desktop }
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = probe.ua.userAgentString
        wv.navigationDelegate = context.coordinator
        context.coordinator.started = Date()
        log("probe load \(probe.url) store=\(probe.store) ua=\(probe.ua.rawValue)")
        wv.load(URLRequest(url: URL(string: probe.url)!))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let log: (String) -> Void
        let label: String
        let check: Probe.Check?
        let record: (String, SpikeStatus, String) -> Void
        var started = Date()
        private var checkStarted = false

        init(log: @escaping (String) -> Void, label: String, check: Probe.Check?, record: @escaping (String, SpikeStatus, String) -> Void) {
            self.log = log
            self.label = label
            self.check = check
            self.record = record
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log(String(format: "probe finished %@ in %.2fs (now at %@)", label, Date().timeIntervalSince(started), webView.url?.host ?? "?"))
            guard let check, !checkStarted else { return }
            checkStarted = true
            Task { @MainActor [weak webView] in
                guard let webView else { return }
                switch check {
                case .followingVariant: await self.runS9(webView)
                case .closeFriends: await self.runS10(webView)
                }
            }
        }

        /// Host and kind of page only: never log a path that could contain a username.
        static func describe(_ url: URL?) -> String {
            guard let url else { return "none" }
            let path = url.path.isEmpty ? "/" : url.path
            let kind: String
            if path == "/" { kind = "feed" }
            else if path.hasPrefix("/accounts/login") { kind = "login" }
            else if path.hasPrefix("/accounts/close_friends") { kind = "close friends" }
            else if path.hasPrefix("/accounts/") { kind = "accounts page" }
            else if path.hasPrefix("/challenge") { kind = "checkpoint" }
            else { kind = "other page" }
            return "\(url.host ?? "?") \(kind)\(hasVariant(url) ? " +variant" : "")"
        }

        static func hasVariant(_ url: URL?) -> Bool {
            (url?.query ?? "").split(separator: "&").contains("variant=following")
        }

        /// S9: does the Following variant survive the load, a Home/logo tap and Back? Mobile web?
        func runS9(_ webView: WKWebView) async {
            try? await Task.sleep(for: .seconds(4))
            let loaded = webView.url
            let ua = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String ?? ""
            let tapJS = "(function(){var a=document.querySelector('a[href=\"/\"],a[href^=\"/?variant\"]');if(!a)return 'no home link';a.click();return 'tapped';})()"
            let tap = (try? await webView.evaluateJavaScript(tapJS)) as? String ?? "script failed"
            try? await Task.sleep(for: .seconds(4))
            let afterTap = webView.url
            _ = try? await webView.evaluateJavaScript("history.back(); 0")
            try? await Task.sleep(for: .seconds(4))
            let afterBack = webView.url
            func verdict(_ u: URL?) -> String { Self.hasVariant(u) ? "KEPT" : "DROPPED" }
            let mobile = loaded?.host == "www.instagram.com" && ua.contains("Mobile")
            log("S9 ?variant=following: load \(verdict(loaded)) (\(Self.describe(loaded))); home \(tap) → \(verdict(afterTap)) (\(Self.describe(afterTap))); back → \(verdict(afterBack)) (\(Self.describe(afterBack))); mobile web: \(mobile ? "yes" : "no")")
            let status: SpikeStatus = tap != "tapped" ? .unknown
                : (Self.hasVariant(loaded) && Self.hasVariant(afterTap) && mobile ? .pass : .fail)
            record("S9", status, "load \(verdict(loaded)), home \(verdict(afterTap)), back \(verdict(afterBack))")
        }

        /// S10: does /accounts/close_friends/ open, and does it show checked rows? Counts only.
        func runS10(_ webView: WKWebView) async {
            try? await Task.sleep(for: .seconds(6))
            let js = """
                (function(){
                  var re=/^\\/[A-Za-z0-9._]{1,30}\\/?$/;
                  var links=[].filter.call(document.querySelectorAll('a[href]'),function(a){return re.test(a.getAttribute('href'));}).length;
                  var boxes=document.querySelectorAll('input[type=checkbox],[role=checkbox]').length;
                  var checked=document.querySelectorAll('input[type=checkbox]:checked,[role=checkbox][aria-checked=true]').length;
                  return JSON.stringify({links:links,boxes:boxes,checked:checked});
                })()
                """
            let raw = (try? await webView.evaluateJavaScript(js)) as? String ?? "{}"
            let counts = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Int] ?? [:]
            let stayed = webView.url?.path.hasPrefix("/accounts/close_friends") ?? false
            let boxes = counts["boxes"] ?? 0, checked = counts["checked"] ?? 0
            let verdict = !stayed ? "NOT AVAILABLE (redirected)" : boxes == 0 ? "OPENS, NO CHECKBOXES" : checked == 0 ? "OPENS, NOTHING CHECKED" : "WORKS"
            log("S10 close friends: \(verdict) · now at \(Self.describe(webView.url)) · profile links \(counts["links"] ?? 0), checkboxes \(boxes), checked \(checked)")
            record("S10", !stayed ? .fail : (boxes > 0 && checked > 0 ? .pass : .unknown), verdict)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let e = error as NSError
            log("probe FAILED \(label): \(e.domain) \(e.code) \(e.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let e = error as NSError
            log("probe failed after commit \(label): \(e.domain) \(e.code)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            log("probe content process terminated \(label)")
        }
    }
}

// MARK: Spike results (plain words)

enum SpikeStatus: String, Codable { case pass, fail, unknown }

struct SpikeInfo: Identifiable {
    let id: String
    let title: String
    /// One sentence: what it tests.
    let tests: String
    let ifPass: String
    let ifFail: String
}

enum SpikeCatalog {
    static let all: [SpikeInfo] = [
        .init(id: "S1", title: "Shield bleed",
              tests: "Does shielding the Instagram/YouTube apps also block our own web views?",
              ifPass: "Lite views keep working while the native apps are shielded.",
              ifFail: "Shields block our web views too; we need the named-store workaround."),
        .init(id: "S2", title: "YouTube sign-in",
              tests: "Can you sign in to YouTube inside breakZero?",
              ifPass: "Signed-in YouTube works (Google may still warn).",
              ifFail: "Use YouTube signed out, with the RSS subscriptions list."),
        .init(id: "S3", title: "Instagram DMs",
              tests: "Do messages, photos and new chats work in the Instagram tab?",
              ifPass: "DMs are safe to rely on.",
              ifFail: "Something in DMs breaks; report what."),
        .init(id: "S4", title: "Notifications",
              tests: "Do message notifications still arrive with Instagram shielded?",
              ifPass: "You won't miss messages.",
              ifFail: "Shielding silences notifications; open breakZero to check."),
        .init(id: "S5", title: "Wall holds",
              tests: "Can breakZero's Screen Time access be turned off in Settings without the Screen Time passcode?",
              ifPass: "Blocking holds on this iOS version.",
              ifFail: "There's a way around it on this iOS version; see the security notes."),
        .init(id: "S6", title: "Speed",
              tests: "How fast does a lite view open, and how much memory does it use?",
              ifPass: "Fast enough (under 2 s to a usable inbox).",
              ifFail: "Too slow; we need to tune loading."),
        .init(id: "S7", title: "Pass timing",
              tests: "Does a native pass end on time even if breakZero is closed?",
              ifPass: "Passes can't be stretched.",
              ifFail: "Passes run long; we need another timer."),
        .init(id: "S8", title: "Snapchat web chat",
              tests: "Does web.snapchat.com chat work inside breakZero?",
              ifPass: "A Snapchat lite tab is possible.",
              ifFail: "Spotlight can only be blocked by shielding the app (paid build)."),
        .init(id: "F1", title: "Feed never flashes",
              tests: "Is any post you shouldn't see ever on screen, even for one frame, while the feed loads and scrolls?",
              ifPass: "Posts outside your rules never appear.",
              ifFail: "Some posts appeared before being hidden; the log says what the feed is made of so the filter can be fixed."),
        .init(id: "S9", title: "Following feed sticks",
              tests: "Does ?variant=following stay after tapping the Instagram logo and going back?",
              ifPass: "The Following feed stays put; the forced redirect rarely has to act.",
              ifFail: "Instagram drops it; breakZero redirects (at most 3 times in 30 s), and feed rules still apply."),
        .init(id: "S10", title: "Close Friends page",
              tests: "Does instagram.com/accounts/close_friends/ open and show who's checked?",
              ifPass: "Import Close Friends works.",
              ifFail: "Close Friends can only come from the data export."),
    ]
}

struct SpikeResult: Codable, Equatable {
    enum Source: String, Codable { case owner, check }
    var status: SpikeStatus
    var note: String
    var date: Date
    var source: Source
}

struct SpikeResults: Codable, Equatable {
    static let file = "spike-results.json"
    var results: [String: SpikeResult] = [:]

    /// Reported by the owner from the iPhone, 2026-10-01.
    static let reported: [String: SpikeResult] = [
        "S9": .init(status: .pass, note: "Tapping the Instagram logo keeps the Following feed (owner, on iPhone)",
                    date: Date(timeIntervalSince1970: 1_790_870_400), source: .owner),
        "S10": .init(status: .pass, note: "The Close Friends page opens (owner, on iPhone)",
                     date: Date(timeIntervalSince1970: 1_790_870_400), source: .owner),
    ]

    func result(_ id: String) -> SpikeResult? { results[id] ?? Self.reported[id] }

    mutating func set(_ id: String, _ status: SpikeStatus, note: String, source: SpikeResult.Source) {
        results[id] = .init(status: status, note: note, date: Date(), source: source)
    }

    static func load(_ store: SharedStore) -> SpikeResults {
        (try? store.read(SpikeResults.self, file)) ?? SpikeResults()
    }

    func save(_ store: SharedStore) { try? store.write(self, Self.file) }
}

struct SpikeRow: View {
    let spike: SpikeInfo
    let result: SpikeResult?
    let set: (SpikeStatus) -> Void

    private var status: SpikeStatus { result?.status ?? .unknown }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(spike.id) · \(spike.title)").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button("PASS") { set(.pass) }
                    Button("FAIL") { set(.fail) }
                    Button("UNKNOWN") { set(.unknown) }
                } label: {
                    Text(status.rawValue.uppercased())
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.18)))
                        .foregroundStyle(color)
                }
                .accessibilityLabel(Text("\(spike.id) result: \(status.rawValue). Change"))
            }
            Text(spike.tests).font(.footnote)
            switch status {
            case .pass: Text(spike.ifPass).font(.footnote).foregroundStyle(.secondary)
            case .fail: Text(spike.ifFail).font(.footnote).foregroundStyle(.secondary)
            case .unknown: Text("Not tested yet.").font(.footnote).foregroundStyle(.secondary)
            }
            if let r = result, r.status != .unknown {
                Text("\(r.note) · \(r.date.formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        switch status {
        case .pass: .green
        case .fail: .red
        case .unknown: .secondary
        }
    }
}
