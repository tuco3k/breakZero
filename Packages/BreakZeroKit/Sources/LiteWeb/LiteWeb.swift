import Core
import Foundation

/// Localized strings the in-page overlay shows. Built natively so the page never decides copy.
public struct LiteStrings: Codable, Sendable, Equatable {
    public var needsUpdate: String
    public var report: String
    /// Feed rules: the card that ends the feed.
    public var caughtUp: String
    /// Feed rules: the one-tap hide button on a post.
    public var hide: String
    /// Feed rules: shown while many posts in a row are being hidden.
    public var finding: String

    public init(needsUpdate: String, report: String, caughtUp: String = "You're all caught up", hide: String = "Hide",
                finding: String = "Finding posts from your people…") {
        self.needsUpdate = needsUpdate
        self.report = report
        self.caughtUp = caughtUp
        self.hide = hide
        self.finding = finding
    }
}

/// Assembles the document-start user script: the bundled filter code plus a data-only config.
/// Pure (no WebKit) so it is tested on Linux.
public enum LiteScriptBuilder {
    public enum BuildError: Error {
        case missingScript
    }

    struct Config: Encodable {
        var active: ActiveRecipe
        var state: NavigationState
        var strings: LiteStrings
        var previousHref: String?
        var limits: LiteLimits
        /// Feed rules setup: read usernames on the user's Followers/Following/Close Friends pages.
        var scan: Bool
        /// Feed rules auto-scroll sync of one list, or nil.
        var sync: LiteSync?
    }

    /// Contents of bz-filter.js, loaded once.
    public static func filterSource() throws -> String {
        guard let url = Bundle.module.url(forResource: "bz-filter", withExtension: "js", subdirectory: "Scripts") else {
            throw BuildError.missingScript
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func configJSON(active: ActiveRecipe, state: NavigationState, strings: LiteStrings,
                                  previousHref: String?, limits: LiteLimits = .none, scan: Bool = false,
                                  sync: LiteSync? = nil) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let config = Config(active: active, state: state, strings: strings, previousHref: previousHref, limits: limits,
                            scan: scan, sync: sync)
        let json = String(decoding: try encoder.encode(config), as: UTF8.self)
        // JSON is a JS expression, but keep the literal safe in every engine and context.
        return json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    /// Full user-script source. The filter is wrapped so a failure to install never throws into
    /// the page: worst case the page loads unfiltered and the native layers (content rules,
    /// navigation delegate, URL observer) still hold.
    public static func userScript(filterSource: String, active: ActiveRecipe, state: NavigationState,
                                  strings: LiteStrings, previousHref: String?, limits: LiteLimits = .none,
                                  scan: Bool = false, sync: LiteSync? = nil) throws -> String {
        let config = try configJSON(active: active, state: state, strings: strings, previousHref: previousHref,
                                    limits: limits, scan: scan, sync: sync)
        return """
        (function () {
        \(filterSource)
        ;try {
          if (!window.__bzInstalled && window.__bzFilter) {
            window.__bzInstalled = true;
            window.__bzFilter.install(window, \(config));
          }
        } catch (e) {
          try { window.webkit.messageHandlers.bz.postMessage({ type: 'filterError', id: 'install' }); } catch (_) {}
        }
        })();
        """
    }

    /// JS that pushes new rules/limits into a live page (`window.__bzUpdate`), no reload.
    public static func updateScript(active: ActiveRecipe, limits: LiteLimits, scan: Bool = false,
                                    sync: LiteSync? = nil) throws -> String {
        struct Update: Encodable {
            var active: ActiveRecipe
            var limits: LiteLimits
            var scan: Bool
            var sync: LiteSync?

            // `sync: null` must reach the page (it stops a running scroll), so encode it explicitly.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(active, forKey: .active)
                try c.encode(limits, forKey: .limits)
                try c.encode(scan, forKey: .scan)
                try c.encode(sync, forKey: .sync)
            }

            enum CodingKeys: String, CodingKey { case active, limits, scan, sync }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(Update(active: active, limits: limits, scan: scan, sync: sync)), as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "window.__bzUpdate && window.__bzUpdate(\(json));"
    }

    /// FNV-1a, hex. Stable across launches (unlike `hashValue`), for cache identifiers.
    public static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    /// Build a "Filter needs an update" GitHub issue link. Contains only recipe/canary ids and
    /// versions — never the page URL or anything read from the page.
    public static func reportURL(repo: String = "tuco3k/breakZero", platform: String, recipeVersion: Int,
                                 canaryIDs: [String], appVersion: String, osVersion: String) -> URL? {
        let ids = canaryIDs
            .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" } }
            .filter { !$0.isEmpty }
            .prefix(10)
        var c = URLComponents()
        c.scheme = "https"
        c.host = "github.com"
        c.path = "/\(repo)/issues/new"
        let body = """
        Filter needs an update.

        - Platform: \(platform)
        - Recipe version: \(recipeVersion)
        - Failed canaries: \(ids.joined(separator: ", "))
        - App version: \(appVersion)
        - iOS: \(osVersion)

        (Nothing else is sent. Add a description of what you saw if you like.)
        """
        c.queryItems = [
            URLQueryItem(name: "title", value: "[\(platform)] filter needs an update (\(ids.first ?? "canary"))"),
            URLQueryItem(name: "labels", value: "filter-broken"),
            URLQueryItem(name: "body", value: body),
        ]
        return c.url
    }
}

/// Unread count from a page title like "(3) Instagram" — digits only, so it works in every
/// language. Used for the tab badge (notifications option A: counts shown when opened).
public enum UnreadBadge {
    public static func count(fromTitle title: String?) -> Int? {
        guard let title, title.hasPrefix("(") , let close = title.firstIndex(of: ")") else { return nil }
        let inner = title[title.index(after: title.startIndex)..<close]
        let digits = inner.filter(\.isNumber)
        guard !digits.isEmpty, digits.count == inner.filter({ $0 != "+" }).count, let n = Int(digits) else { return nil }
        return n
    }
}

/// Media playback in lite views. Owner decision (QUESTIONS #27, 2026-10-01): the wall rule is
/// "no autoplay chains", not "no playback". So the video you open may start without an extra tap
/// (no user-gesture requirement), and moving on to *another* video after one ends is still refused
/// by the autoplay guard (`blockAutoAdvance` in the recipe, enforced by the route guard and the
/// watchdog).
public enum PlaybackPolicy {
    /// Should WebKit require a user gesture before media plays? Maps to
    /// `WKWebViewConfiguration.mediaTypesRequiringUserActionForPlayback` (`.all` / `[]`).
    public static func requiresUserGesture(_ platform: Platform) -> Bool { false }
}

/// Human names for `MediaError.code`, for the Diagnostics log.
public enum MediaDiagnostics {
    public static func describe(event: String, kind: String, code: Int?, source: String) -> String {
        var line = "\(kind) \(event)"
        if let code { line += " code \(code) (\(errorName(code)))" }
        line += " source=\(source)"
        return line
    }

    public static func errorName(_ code: Int) -> String {
        switch code {
        case 1: "MEDIA_ERR_ABORTED: fetching was aborted"
        case 2: "MEDIA_ERR_NETWORK: network error while loading (VPN, blocked host, offline)"
        case 3: "MEDIA_ERR_DECODE: the media couldn't be decoded"
        case 4: "MEDIA_ERR_SRC_NOT_SUPPORTED: source not supported or not allowed"
        default: "unknown"
        }
    }
}

/// Auto-scroll sync instruction for the page: scroll `owner`'s `list` at `pacing`.
public struct LiteSync: Codable, Sendable, Equatable {
    public var list: FriendsScanList
    public var owner: String
    public var pacing: SyncPacing

    public init(list: FriendsScanList, owner: String, pacing: SyncPacing = .default) {
        self.list = list
        self.owner = owner
        self.pacing = pacing
    }
}

/// What the page reports about a running auto-scroll.
public enum SyncPageEvent: String, Sendable, CaseIterable {
    /// Reached the bottom and nothing more loads.
    case end
    case stalled, challenge, login, warning, leftPage
}

/// What native tells the page about limits: the platform is blocked (daily limit / schedule).
public struct LiteLimits: Codable, Sendable, Equatable {
    public var blocked: String?

    public init(blocked: String?) { self.blocked = blocked }
    public static let none = LiteLimits(blocked: nil)
}

/// A watchdog violation (page or native): what was showing that shouldn't be, for the toast/log.
public struct WatchdogViolation: Equatable, Sendable {
    public enum Source: String, Sendable { case page, native }

    /// "blocked", "redirected", "bounced", "outOfScope", "autoAdvance" or "limit".
    public var reason: String
    /// For "limit": "dailyLimit" or "schedule".
    public var detail: String?
    public var ruleID: String?
    public var source: Source

    public init(reason: String, detail: String?, ruleID: String?, source: Source) {
        self.reason = reason
        self.detail = detail
        self.ruleID = ruleID
        self.source = source
    }

    public static func from(_ reason: NavigationDecision.Reason) -> WatchdogViolation {
        switch reason {
        case let .blocked(id): .init(reason: "blocked", detail: nil, ruleID: id, source: .native)
        case let .redirected(id): .init(reason: "redirected", detail: nil, ruleID: id, source: .native)
        case let .bounced(id): .init(reason: "bounced", detail: nil, ruleID: id, source: .native)
        case let .outOfScope(id): .init(reason: "outOfScope", detail: nil, ruleID: id, source: .native)
        }
    }
}

/// Messages the injected script posts to the `bz` handler. Page scripts can post too, so every
/// field is validated and nothing here can widen what the user can reach.
public enum LiteMessage: Equatable, Sendable {
    case route(href: String, state: NavigationState?)
    case redirect(reason: String, ruleID: String?)
    case refuse(reason: String)
    case canary(ids: [String])
    case report(ids: [String])
    case filterError(id: String)
    /// A `<video>`/`<audio>` event: "error", "stalled" or "playing" (first per element).
    case media(event: String, kind: String, code: Int?, source: String)
    case violation(WatchdogViolation)
    /// Old Instagram setup: usernames read from profile links on one of the user's lists.
    case friendsScan(list: FriendsScanList, owner: String?, usernames: [String])
    /// Feed rules events for the log (no usernames): see `friendsEvents`.
    case friends(event: String)
    /// Authors the feed rules hid on this page (for the status pill; never logged).
    case friendsHidden(usernames: [String])
    /// The one-tap "hide this account" on a post.
    case hideAccount(username: String)
    case syncEvent(list: FriendsScanList, event: SyncPageEvent)

    static let friendsEvents: Set<String> = ["forcedFollowing", "followingGaveUp", "caughtUp", "storySkipped",
                                             "storyClosed", "scanNoChecked"]
    /// Per message; the page sends only names it hasn't sent before.
    static let maxScanBatch = 500

    public static func parse(_ body: Any) -> LiteMessage? {
        guard let d = body as? [String: Any], let type = d["type"] as? String else { return nil }
        func ids() -> [String] { ((d["ids"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(10).map { String($0.prefix(80)) } }
        switch type {
        case "route":
            guard let href = d["href"] as? String else { return nil }
            return .route(href: href, state: parseState(d["state"]))
        case "redirect":
            return .redirect(reason: (d["reason"] as? String) ?? "", ruleID: d["ruleID"] as? String)
        case "refuse":
            return .refuse(reason: (d["reason"] as? String) ?? "")
        case "canary":
            return .canary(ids: ids())
        case "report":
            return .report(ids: ids())
        case "filterError":
            return .filterError(id: String(((d["id"] as? String) ?? "?").prefix(80)))
        case "violation":
            let reasons: Set<String> = ["blocked", "redirected", "bounced", "outOfScope", "autoAdvance", "limit"]
            guard let reason = d["reason"] as? String, reasons.contains(reason) else { return nil }
            let details: Set<String> = ["dailyLimit", "schedule"]
            let detail = (d["detail"] as? String).flatMap { details.contains($0) ? $0 : nil }
            let ruleID = (d["ruleID"] as? String).map { String($0.prefix(80)) }
            return .violation(.init(reason: reason, detail: detail, ruleID: ruleID, source: .page))
        case "media":
            let allowedEvents: Set<String> = ["error", "stalled", "playing"]
            guard let event = d["event"] as? String, allowedEvents.contains(event) else { return nil }
            let kind = (d["kind"] as? String) == "audio" ? "audio" : "video"
            let rawSource = d["source"] as? String ?? ""
            let source = ["blob", "url"].contains(rawSource) ? rawSource : "none"
            return .media(event: event, kind: kind, code: (d["code"] as? NSNumber)?.intValue, source: source)
        case "friendsScan":
            // Page scripts can post this too: validate everything; the result is only ever a suggestion.
            guard let list = (d["list"] as? String).flatMap(FriendsScanList.init(rawValue:)) else { return nil }
            let owner = (d["owner"] as? String).flatMap(Friends.normalize)
            if list != .closeFriends, owner == nil { return nil }
            let names = ((d["usernames"] as? [Any]) ?? []).prefix(maxScanBatch).compactMap { ($0 as? String).flatMap(Friends.normalize) }
            return .friendsScan(list: list, owner: list == .closeFriends ? nil : owner, usernames: names)
        case "friends":
            guard let event = d["event"] as? String, friendsEvents.contains(event) else { return nil }
            return .friends(event: event)
        case "friendsHidden":
            let names = ((d["usernames"] as? [Any]) ?? []).prefix(100).compactMap { ($0 as? String).flatMap(Friends.normalize) }
            return names.isEmpty ? nil : .friendsHidden(usernames: names)
        case "hideAccount":
            // A page script could post this too; hiding is only ever a narrowing.
            guard let u = (d["username"] as? String).flatMap(Friends.normalize) else { return nil }
            return .hideAccount(username: u)
        case "syncEvent":
            guard let list = (d["list"] as? String).flatMap(FriendsScanList.init(rawValue:)),
                  let event = (d["event"] as? String).flatMap(SyncPageEvent.init(rawValue:)) else { return nil }
            return .syncEvent(list: list, event: event)
        default:
            return nil
        }
    }

    static func parseState(_ any: Any?) -> NavigationState? {
        guard let d = any as? [String: Any] else { return nil }
        let storyUser = (d["storyUser"] as? String).flatMap(Friends.normalize)
        guard let g = d["grant"] as? [String: Any] else { return NavigationState(grant: nil, storyUser: storyUser) }
        guard let ruleID = g["ruleID"] as? String, let key = g["key"] as? String, let returnTo = g["returnTo"] as? String,
              returnTo.hasPrefix("/") else { return NavigationState(grant: nil, storyUser: storyUser) }
        return NavigationState(grant: .init(ruleID: ruleID, key: key, returnTo: returnTo), storyUser: storyUser)
    }
}
