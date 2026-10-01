// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
#if canImport(WebKit) && canImport(UIKit)
import Core
import UIKit
import WebKit

public enum UserAgentMode: String, Codable, Sendable, CaseIterable {
    /// WebKit's own UA (says "Mobile/…" without "Version/… Safari/…").
    case webKitDefault
    /// The device's real mobile-Safari UA. Spike S2/S3 decide whether we need this.
    case safari
    /// Desktop Safari on macOS (Snapchat's web chat only serves desktop browsers; spike S8).
    case desktopSafari

    /// Mobile Safari UA for this device's iOS version.
    @MainActor
    static func safariUserAgent() -> String {
        let v = UIDevice.current.systemVersion
        let underscored = v.replacingOccurrences(of: ".", with: "_")
        let major = v.split(separator: ".").first.map(String.init) ?? v
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    /// Desktop Safari UA (same WebKit major as the device).
    @MainActor
    static func desktopSafariUserAgent() -> String {
        let major = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "18"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Safari/605.1.15"
    }

    /// The UA a recipe asks for (nil = WebKit default).
    public init(recipeValue: String?) {
        self = recipeValue.flatMap(UserAgentMode.init(rawValue:)) ?? .webKitDefault
    }

    @MainActor
    public var userAgentString: String? {
        switch self {
        case .webKitDefault: nil
        case .safari: Self.safariUserAgent()
        case .desktopSafari: Self.desktopSafariUserAgent()
        }
    }
}

/// One persistent, warm WKWebView per platform ("Lite view") with all five filter layers.
@MainActor
public final class LiteWebController: NSObject {
    public let platform: Platform
    public let webView: WKWebView
    public private(set) var engine: RuleEngine
    public private(set) var state = NavigationState()

    /// Not one of this platform's hosts: open in SFSafariViewController.
    public var onOpenExternally: ((URL) -> Void)?
    /// User tapped "Report" on a canary overlay (ids only).
    public var onReport: (([String]) -> Void)?
    /// Diagnostics log line (no page content, no URLs beyond the path for our own log).
    public var onEvent: ((String) -> Void)?
    /// Seconds from controller creation to the first finished landing load (Spike S6).
    public var onFirstLoad: ((TimeInterval) -> Void)?
    /// Unread count parsed from the page title, for the tab badge.
    public var onUnreadCount: ((Int?) -> Void)?
    /// A file the site offered as a download (saved to a temporary URL); the app saves it to Photos.
    public var onDownloaded: ((URL) -> Void)?
    /// Cookies changed (debounced ~1 s): the app re-checks signed in/out (landing, Accounts).
    public var onCookiesChanged: (() -> Void)?
    /// The watchdog (page or native) moved the user off something that was showing.
    public var onViolation: ((WatchdogViolation) -> Void)?
    /// Old Instagram setup: usernames the page read from one of the user's lists.
    public var onFriendsScan: ((FriendsScanList, String?, [String]) -> Void)?
    /// Old Instagram: read usernames on list pages (setup). Off unless the user started a scan.
    public private(set) var scanning = false
    /// What the limits say about this platform right now (pushed into the page too).
    public private(set) var limits = LiteLimits.none
    private var watchdogTimer: Timer?
    private var lastViolationAt = Date.distantPast
    /// URL seen at the previous native watchdog tick; we act only on a URL that has been showing
    /// for a whole tick, so we never race the page's own route messages.
    private var watchdogLastURL: URL?
    private var cookieDebounce: Task<Void, Never>?

    private let filterSource: String
    private let strings: LiteStrings
    private var lastJSReportedHref: String?
    private var urlObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    /// Back/forward list + scroll state, captured after each load, restored after a
    /// web-content-process crash so the user lands where they were.
    private var savedInteractionState: Any?
    private var ruleList: WKContentRuleList?
    private let createdAt = Date()
    private var reportedFirstLoad = false
    private var lastCommittedURL: URL?
    private var mediaReports = 0
    fileprivate var pendingDownloads: [ObjectIdentifier: URL] = [:]

    /// Stable per-platform data store identifiers (iOS 17+): sessions persist across launches and
    /// each platform's cookies stay separate (also a candidate workaround for Spike S1).
    public nonisolated static func dataStoreID(_ p: Platform) -> UUID {
        switch p {
        case .instagram: UUID(uuidString: "6F1D7A52-3C0B-4C55-9E7A-1B0A6E1D0001")!
        case .youtube: UUID(uuidString: "6F1D7A52-3C0B-4C55-9E7A-1B0A6E1D0002")!
        case .snapchat: UUID(uuidString: "6F1D7A52-3C0B-4C55-9E7A-1B0A6E1D0003")!
        }
    }

    /// - userAgent: nil = what the recipe asks for (`Recipe.userAgent`), else WebKit's default.
    public init(platform: Platform, active: ActiveRecipe, strings: LiteStrings,
                userAgent: UserAgentMode? = nil, dataStore: WKWebsiteDataStore? = nil) throws {
        let ua = userAgent ?? UserAgentMode(recipeValue: active.recipe.userAgent)
        self.platform = platform
        self.engine = try RuleEngine(active: active)
        self.filterSource = try LiteScriptBuilder.filterSource()
        self.strings = strings

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore ?? WKWebsiteDataStore(forIdentifier: Self.dataStoreID(platform))
        config.allowsInlineMediaPlayback = true
        // The video you open plays; chains to the next one are blocked by the autoplay guard
        // instead (QUESTIONS #27). See PlaybackPolicy.
        config.mediaTypesRequiringUserActionForPlayback = PlaybackPolicy.requiresUserGesture(platform) ? .all : []
        config.defaultWebpagePreferences.preferredContentMode = ua == .desktopSafari ? .desktop : .mobile
        config.limitsNavigationsToAppBoundDomains = false
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.customUserAgent = ua.userAgentString
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
        config.userContentController.add(WeakMessageHandler(self), contentWorld: .page, name: "bz")

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        // Backstop for SPA navigation if the injected guard is broken: pushState changes `url`
        // without a navigation action. If the script didn't report this URL, decide natively.
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.urlDidChange() }
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.onUnreadCount?(UnreadBadge.count(fromTitle: self?.webView.title)) }
        }
        config.websiteDataStore.httpCookieStore.add(self)
        installUserScript(previousHref: nil)
        compileContentRules()
    }

    /// Path of the page on screen (for the usage meter and the native watchdog).
    public var currentPath: String? {
        webView.url.map(RuleEngine.path)
    }

    /// Pause every `<video>`/`<audio>` (used when a limit or schedule blocks this platform).
    public func pauseMedia() {
        webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}});", in: nil, in: .page) { _ in }
        webView.pauseAllMediaPlayback()
    }

    // MARK: Loading

    public func loadLanding() {
        load(path: engine.active.landingPath)
    }

    public func load(path: String) {
        guard let host = engine.recipe.landing.host
                ?? engine.recipe.hosts.first(where: { !$0.hasPrefix("*.") && $0.hasPrefix("www.") }) ?? engine.recipe.hosts.first,
              let url = URL(string: "https://\(host)\(path)") else { return }
        webView.load(URLRequest(url: url))
    }

    /// New settings (ratchet applied them, or the session changed): rebuild every layer.
    /// `reload: false` keeps the current page (used when only the landing path changed).
    public func update(active: ActiveRecipe, reload: Bool = true) throws {
        engine = try RuleEngine(active: active)
        installUserScript(previousHref: webView.url?.absoluteString)
        compileContentRules()
        if reload { webView.reload() } else { pushConfigToPage() }
    }

    // MARK: Watchdog (ARCHITECTURE.md §4b)

    /// New limits for this platform (daily limit / schedule). Takes effect in the live page now.
    public func setLimits(_ new: LiteLimits) {
        guard new != limits else { return }
        limits = new
        installUserScript(previousHref: webView.url?.absoluteString)
        pushConfigToPage()
        if new.blocked != nil { watchdogTick(force: true) }
    }

    /// Start/stop reading usernames on the user's Followers/Following/Close Friends pages.
    public func setScanning(_ on: Bool) {
        guard on != scanning else { return }
        scanning = on
        installUserScript(previousHref: webView.url?.absoluteString)
        pushConfigToPage()
    }

    private func pushConfigToPage() {
        guard let js = try? LiteScriptBuilder.updateScript(active: engine.active, limits: limits, scan: scanning) else { return }
        webView.evaluateJavaScript(js, in: nil, in: .page) { _ in }
    }

    /// Run the native watchdog (1 s timer) — independent of the page's own checks.
    public func setWatchdogRunning(_ on: Bool) {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        watchdogLastURL = nil
        guard on else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick(force: false) }
        }
    }

    func watchdogTick(force: Bool) {
        guard let url = webView.url, engine.isFilteredHost(url.host) else { watchdogLastURL = nil; return }
        defer { watchdogLastURL = url }
        guard force || url == watchdogLastURL else { return }
        guard Date().timeIntervalSince(lastViolationAt) >= 2 else { return }
        let here = RuleEngine.pathAndQuery(url)
        if let blocked = limits.blocked {
            if here == engine.active.landingPath {
                pauseMedia()
            } else {
                violate(.init(reason: "limit", detail: blocked, ruleID: nil, source: .native), to: engine.active.landingPath)
            }
            return
        }
        if case let .redirect(to, reason) = engine.check(url: url, state: state) {
            violate(.from(reason), to: to)
        }
    }

    private func violate(_ v: WatchdogViolation, to path: String) {
        lastViolationAt = Date()
        webView.stopLoading()
        pauseMedia()
        load(path: path)
        onViolation?(v)
    }

    fileprivate func cookiesChanged() {
        cookieDebounce?.cancel()
        cookieDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onCookiesChanged?()
        }
    }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        webView.reload()
        sender.endRefreshing()
    }

    // MARK: Layers 1 and 2b/3/4/5 installation

    private func installUserScript(previousHref: String?) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        do {
            let source = try LiteScriptBuilder.userScript(filterSource: filterSource, active: engine.active, state: state,
                                                          strings: strings, previousHref: previousHref, limits: limits,
                                                          scan: scanning)
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        } catch {
            onEvent?("userScript build failed: \(error)")
        }
    }

    private func compileContentRules() {
        let json: String
        do { json = try ContentRuleListBuilder.json(for: engine.active) } catch {
            onEvent?("content rules build failed: \(error)")
            return
        }
        // Identifier includes a hash of the JSON so a changed recipe recompiles, an unchanged one is reused.
        let id = "bz.\(platform.rawValue).\(engine.recipe.version).\(LiteScriptBuilder.stableHash(json))"
        let ucc = webView.configuration.userContentController
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { [weak self] list, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.onEvent?("content rules compile failed: \(error.localizedDescription)"); return }
                if let old = self.ruleList { ucc.remove(old) }
                if let list { ucc.add(list); self.ruleList = list }
            }
        }
    }

    // MARK: Decisions

    fileprivate func handle(_ message: LiteMessage) {
        switch message {
        case let .route(href, newState):
            lastJSReportedHref = href
            if let newState { state = newState }
        case let .redirect(reason, ruleID):
            lastJSReportedHref = nil
            onEvent?("guard redirect \(reason) \(ruleID ?? "")")
        case let .refuse(reason):
            onEvent?("guard refused \(reason)")
        case let .canary(ids):
            onEvent?("canary failed: \(ids.joined(separator: ","))")
        case let .report(ids):
            onReport?(ids)
        case let .filterError(id):
            onEvent?("filter error: \(id)")
        case let .violation(v):
            lastViolationAt = Date()
            onViolation?(v)
        case let .media(event, kind, code, source):
            // Cap per page load so a looping error can't flood the log.
            guard mediaReports < 20 else { return }
            mediaReports += 1
            onEvent?(MediaDiagnostics.describe(event: event, kind: kind, code: code, source: source))
        case let .friendsScan(list, owner, usernames):
            // Only while the user asked for a scan; otherwise a page can't feed suggestions at all.
            guard scanning, !usernames.isEmpty else { return }
            onFriendsScan?(list, owner, usernames)
        case let .friends(event):
            onEvent?("friends: \(event)")
        }
    }

    private func urlDidChange() {
        guard let url = webView.url else { return }
        // Give the in-page guard a moment to report; act only if it stayed silent.
        let href = url.absoluteString
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.webView.url?.absoluteString == href, self.lastJSReportedHref != href,
                      href != self.lastCommittedURL?.absoluteString else { return }
                var s = self.state
                let decision = self.engine.decide(url: url, from: self.lastCommittedURL, state: &s)
                self.state = s
                self.lastCommittedURL = url
                if case let .redirect(to, reason) = decision {
                    self.onEvent?("native backstop redirect \(reason)")
                    self.load(path: to)
                }
            }
        }
    }

    private func redirectURL(_ path: String, like url: URL) -> URL? {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        c?.percentEncodedPath = parts.first ?? "/"
        c?.percentEncodedQuery = parts.count > 1 ? parts[1] : nil
        c?.fragment = nil
        return c?.url
    }
}

extension LiteWebController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        // Subframes (players, login widgets) are the site's own business; only top-level is ours.
        if let frame = navigationAction.targetFrame, !frame.isMainFrame { return .allow }

        var s = state
        let decision = engine.decide(url: url, from: webView.url, state: &s)
        switch decision {
        case .allow:
            state = s
            installUserScript(previousHref: webView.url?.absoluteString)
            if navigationAction.targetFrame == nil {
                // target=_blank inside the platform: keep it in this tab.
                webView.load(navigationAction.request)
                return .cancel
            }
            return .allow
        case let .redirect(to, reason):
            state = s
            onEvent?("redirect \(reason)")
            if let target = redirectURL(to, like: url) {
                installUserScript(previousHref: webView.url?.absoluteString)
                webView.load(URLRequest(url: target))
            }
            return .cancel
        case .openExternally:
            if url.scheme == "https" || url.scheme == "http" {
                onOpenExternally?(url)
            } else {
                onEvent?("blocked non-web scheme \(url.scheme ?? "?")")
            }
            return .cancel
        }
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        lastCommittedURL = webView.url
        mediaReports = 0
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !reportedFirstLoad {
            reportedFirstLoad = true
            onFirstLoad?(Date().timeIntervalSince(createdAt))
        }
        savedInteractionState = webView.interactionState
    }

    /// Files the page can't display (e.g. a saved photo/video) become downloads.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        onEvent?("load failed \(e.domain) \(e.code)")
    }

    /// The web content process died (memory pressure, crash). Reload where we were.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onEvent?("web content process terminated; restoring")
        installUserScript(previousHref: nil)
        if let saved = savedInteractionState {
            webView.interactionState = saved
        } else if webView.url != nil {
            webView.reload()
        } else {
            loadLanding()
        }
    }
}

extension LiteWebController: WKDownloadDelegate {
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bz-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = suggestedFilename.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent(UUID().uuidString + "-" + safeName)
        pendingDownloads[ObjectIdentifier(download)] = url
        return url
    }

    public func downloadDidFinish(_ download: WKDownload) {
        if let url = pendingDownloads.removeValue(forKey: ObjectIdentifier(download)) { onDownloaded?(url) }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pendingDownloads.removeValue(forKey: ObjectIdentifier(download))
        onEvent?("download failed: \((error as NSError).code)")
    }
}

extension LiteWebController: WKUIDelegate {
    /// window.open: route through the same decision as a link tap.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            var s = state
            switch engine.decide(url: url, from: webView.url, state: &s) {
            case .allow, .redirect: webView.load(navigationAction.request)
            case .openExternally: onOpenExternally?(url)
            }
        }
        return nil
    }
}

extension LiteWebController: WKHTTPCookieStoreObserver {
    public nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.cookiesChanged() }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: LiteWebController?

    init(_ target: LiteWebController) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only our main frame's page world.
        guard message.frameInfo.isMainFrame, let parsed = LiteMessage.parse(message.body) else { return }
        MainActor.assumeIsolated { target?.handle(parsed) }
    }
}
#endif
