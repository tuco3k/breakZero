// UNVERIFIED: written on Linux, never compiled. Build on a Mac first (see PROGRESS.md).
#if canImport(WebKit) && canImport(UIKit)
import Core
import UIKit
import WebKit

public enum UserAgentMode: String, Codable, Sendable, CaseIterable {
    /// WebKit's own UA (says "Mobile/…" without "Version/… Safari/…").
    case webKitDefault
    /// The device's real mobile-Safari UA. Spike S2/S3 decide whether we need this.
    case safari

    /// Mobile Safari UA for this device's iOS version.
    @MainActor
    static func safariUserAgent() -> String {
        let v = UIDevice.current.systemVersion
        let underscored = v.replacingOccurrences(of: ".", with: "_")
        let major = v.split(separator: ".").first.map(String.init) ?? v
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
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

    private let filterSource: String
    private let strings: LiteStrings
    private var lastJSReportedHref: String?
    private var urlObservation: NSKeyValueObservation?
    private var ruleList: WKContentRuleList?
    private let createdAt = Date()
    private var reportedFirstLoad = false
    private var lastCommittedURL: URL?

    /// Stable per-platform data store identifiers (iOS 17+): sessions persist across launches and
    /// each platform's cookies stay separate (also a candidate workaround for Spike S1).
    static func dataStoreID(_ p: Platform) -> UUID {
        switch p {
        case .instagram: UUID(uuidString: "6F1D7A52-3C0B-4C55-9E7A-1B0A6E1D0001")!
        case .youtube: UUID(uuidString: "6F1D7A52-3C0B-4C55-9E7A-1B0A6E1D0002")!
        }
    }

    public init(platform: Platform, active: ActiveRecipe, strings: LiteStrings,
                userAgent: UserAgentMode = .webKitDefault, dataStore: WKWebsiteDataStore? = nil) throws {
        self.platform = platform
        self.engine = try RuleEngine(active: active)
        self.filterSource = try LiteScriptBuilder.filterSource()
        self.strings = strings

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore ?? WKWebsiteDataStore(forIdentifier: Self.dataStoreID(platform))
        config.allowsInlineMediaPlayback = true
        // YouTube: never start playback without a tap (part of "autoplay off").
        config.mediaTypesRequiringUserActionForPlayback = platform == .youtube ? .all : []
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.limitsNavigationsToAppBoundDomains = false
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        if userAgent == .safari { webView.customUserAgent = UserAgentMode.safariUserAgent() }
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
        installUserScript(previousHref: nil)
        compileContentRules()
    }

    // MARK: Loading

    public func loadLanding() {
        load(path: engine.active.landingPath)
    }

    public func load(path: String) {
        guard let host = engine.recipe.hosts.first(where: { !$0.hasPrefix("*.") && $0.hasPrefix("www.") }) ?? engine.recipe.hosts.first,
              let url = URL(string: "https://\(host)\(path)") else { return }
        webView.load(URLRequest(url: url))
    }

    /// New settings (ratchet applied them): rebuild every layer and reload.
    public func update(active: ActiveRecipe) throws {
        engine = try RuleEngine(active: active)
        installUserScript(previousHref: webView.url?.absoluteString)
        compileContentRules()
        webView.reload()
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
                                                          strings: strings, previousHref: previousHref)
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
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !reportedFirstLoad {
            reportedFirstLoad = true
            onFirstLoad?(Date().timeIntervalSince(createdAt))
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        onEvent?("load failed \(e.domain) \(e.code)")
    }

    /// The web content process died (memory pressure, crash). Reload where we were.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onEvent?("web content process terminated; reloading")
        if webView.url != nil { webView.reload() } else { loadLanding() }
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
