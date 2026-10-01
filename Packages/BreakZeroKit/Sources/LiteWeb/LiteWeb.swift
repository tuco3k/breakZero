import Core
import Foundation

/// Localized strings the in-page overlay shows. Built natively so the page never decides copy.
public struct LiteStrings: Codable, Sendable, Equatable {
    public var needsUpdate: String
    public var report: String

    public init(needsUpdate: String, report: String) {
        self.needsUpdate = needsUpdate
        self.report = report
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
    }

    /// Contents of bz-filter.js, loaded once.
    public static func filterSource() throws -> String {
        guard let url = Bundle.module.url(forResource: "bz-filter", withExtension: "js", subdirectory: "Scripts") else {
            throw BuildError.missingScript
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func configJSON(active: ActiveRecipe, state: NavigationState, strings: LiteStrings,
                                  previousHref: String?, limits: LiteLimits = .none) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let config = Config(active: active, state: state, strings: strings, previousHref: previousHref, limits: limits)
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
                                  strings: LiteStrings, previousHref: String?, limits: LiteLimits = .none) throws -> String {
        let config = try configJSON(active: active, state: state, strings: strings, previousHref: previousHref, limits: limits)
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
    public static func updateScript(active: ActiveRecipe, limits: LiteLimits) throws -> String {
        struct Update: Encodable { var active: ActiveRecipe; var limits: LiteLimits }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(Update(active: active, limits: limits)), as: UTF8.self)
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
        default:
            return nil
        }
    }

    static func parseState(_ any: Any?) -> NavigationState? {
        guard let d = any as? [String: Any] else { return nil }
        guard let g = d["grant"] as? [String: Any] else { return NavigationState(grant: nil) }
        guard let ruleID = g["ruleID"] as? String, let key = g["key"] as? String, let returnTo = g["returnTo"] as? String,
              returnTo.hasPrefix("/") else { return NavigationState(grant: nil) }
        return NavigationState(grant: .init(ruleID: ruleID, key: key, returnTo: returnTo))
    }
}
