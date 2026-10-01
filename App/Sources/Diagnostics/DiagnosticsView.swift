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

    var body: some View {
        List {
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
        .sheet(item: $probe) { p in
            NavigationStack {
                ProbeWebView(probe: p, log: log)
                    .navigationTitle(p.url)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { probe = nil } }
            }
        }
        .onAppear(perform: refresh)
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
    let url: String
    let store: Store
    let ua: UserAgentMode
    let id = UUID()
}

/// A bare, unfiltered web view for spikes: logs every load outcome. Not a lite view.
struct ProbeWebView: UIViewRepresentable {
    let probe: Probe
    let log: (String) -> Void

    static func platformStoreID(_ p: Platform) -> UUID { LiteWebController.dataStoreID(p) }

    func makeCoordinator() -> Coordinator { Coordinator(log: log, label: probe.url) }

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
        var started = Date()

        init(log: @escaping (String) -> Void, label: String) {
            self.log = log
            self.label = label
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log(String(format: "probe finished %@ in %.2fs (now at %@)", label, Date().timeIntervalSince(started), webView.url?.host ?? "?"))
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
