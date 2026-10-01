import Foundation

/// The version of the recipe format this build understands. A recipe whose
/// `minEngine` is greater than this is rejected (kept on the last good one).
public let recipeEngineVersion = 1

/// One platform's filter rules. Pure data: interpreted by bundled code, never executed
/// (App Store guideline 2.5.2). See RECIPES.md for the format.
public struct Recipe: Codable, Sendable, Equatable {
    public var platform: String
    public var version: Int
    public var minEngine: Int
    /// Hosts where filters run. Top-level navigation is allowed.
    public var hosts: [String]
    /// Hosts allowed for top-level navigation with no filters (login, consent, 2FA).
    public var authHosts: [String]
    public var landing: Landing
    /// User-facing switches. Every rule names one; the toggle's default decides if it runs.
    public var toggles: [Toggle]
    /// Named "where did we come from" patterns used by `allowOnce` scopes.
    public var scopes: [String: String]
    public var routes: [RouteRule]
    public var hide: [HideRule]
    public var heuristics: [Heuristic]
    public var behaviors: [Behavior]
    /// Paths where only route-level rules run (no CSS, heuristics or canaries).
    public var allowZones: [String]
    public var canaries: [Canary]
    /// Subresource URL blocks compiled into the WKContentRuleList (layer 1).
    public var resourceBlocks: [ResourceBlock]
    /// How to tell "signed in" from cookies (names only; values are never read).
    public var session: Session?

    public init(
        platform: String, version: Int, minEngine: Int, hosts: [String], authHosts: [String] = [],
        landing: Landing, toggles: [Toggle], scopes: [String: String] = [:], routes: [RouteRule],
        hide: [HideRule] = [], heuristics: [Heuristic] = [], behaviors: [Behavior] = [],
        allowZones: [String] = [], canaries: [Canary] = [], resourceBlocks: [ResourceBlock] = [],
        session: Session? = nil
    ) {
        self.platform = platform
        self.version = version
        self.minEngine = minEngine
        self.hosts = hosts
        self.authHosts = authHosts
        self.landing = landing
        self.toggles = toggles
        self.scopes = scopes
        self.routes = routes
        self.hide = hide
        self.heuristics = heuristics
        self.behaviors = behaviors
        self.allowZones = allowZones
        self.canaries = canaries
        self.resourceBlocks = resourceBlocks
        self.session = session
    }

    // Optional arrays default to empty so recipe authors can omit them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(String.self, forKey: .platform)
        version = try c.decode(Int.self, forKey: .version)
        minEngine = try c.decode(Int.self, forKey: .minEngine)
        hosts = try c.decode([String].self, forKey: .hosts)
        authHosts = try c.decodeIfPresent([String].self, forKey: .authHosts) ?? []
        landing = try c.decode(Landing.self, forKey: .landing)
        toggles = try c.decodeIfPresent([Toggle].self, forKey: .toggles) ?? []
        scopes = try c.decodeIfPresent([String: String].self, forKey: .scopes) ?? [:]
        routes = try c.decodeIfPresent([RouteRule].self, forKey: .routes) ?? []
        hide = try c.decodeIfPresent([HideRule].self, forKey: .hide) ?? []
        heuristics = try c.decodeIfPresent([Heuristic].self, forKey: .heuristics) ?? []
        behaviors = try c.decodeIfPresent([Behavior].self, forKey: .behaviors) ?? []
        allowZones = try c.decodeIfPresent([String].self, forKey: .allowZones) ?? []
        canaries = try c.decodeIfPresent([Canary].self, forKey: .canaries) ?? []
        resourceBlocks = try c.decodeIfPresent([ResourceBlock].self, forKey: .resourceBlocks) ?? []
        session = try c.decodeIfPresent(Session.self, forKey: .session)
    }

    public struct Session: Codable, Sendable, Equatable {
        /// Any one of these cookie names, set for one of the recipe's hosts, means signed in.
        public var cookies: [String]

        public init(cookies: [String]) { self.cookies = cookies }
    }

    public struct Landing: Codable, Sendable, Equatable {
        /// Key into `options` used when the user hasn't picked one.
        public var `default`: String
        /// Landing choices, e.g. {"inbox": "/direct/inbox/", "following": "/?variant=following"}.
        public var options: [String: String]
        /// Key into `options` used instead when the user is signed out (e.g. YouTube → search,
        /// because Subscriptions is empty without an account). nil = same as signed in.
        public var signedOut: String?

        public init(default: String, options: [String: String], signedOut: String? = nil) {
            self.default = `default`
            self.options = options
            self.signedOut = signedOut
        }
    }

    public struct Toggle: Codable, Sendable, Equatable {
        public var id: String
        public var defaultOn: Bool

        public init(id: String, defaultOn: Bool) {
            self.id = id
            self.defaultOn = defaultOn
        }
    }

    public enum RouteAction: String, Codable, Sendable {
        /// Explicitly allowed; stops evaluation (used to carve exceptions before a block).
        case allow
        /// Cancel; send the user to the landing page.
        case block
        /// Go to `to` (a path template; `{name}` = named capture, `{landing}` = landing path).
        case redirect
        /// Allowed only when entered from `scope`; see `RuleEngine`.
        case allowOnce
    }

    public struct RouteRule: Codable, Sendable, Equatable {
        public var id: String
        public var toggle: String
        /// Regex over the URL path (no query). Subset shared by ICU and JavaScript.
        public var pattern: String
        public var action: RouteAction
        public var to: String?
        public var scope: String?
        /// Name of the capture group that identifies the item for `allowOnce`.
        public var key: String?

        public init(
            id: String, toggle: String, pattern: String, action: RouteAction,
            to: String? = nil, scope: String? = nil, key: String? = nil
        ) {
            self.id = id
            self.toggle = toggle
            self.pattern = pattern
            self.action = action
            self.to = to
            self.scope = scope
            self.key = key
        }
    }

    public struct HideRule: Codable, Sendable, Equatable {
        public var id: String
        public var toggle: String
        public var selector: String
        /// Path regexes where this applies; nil = everywhere outside allow zones.
        public var routes: [String]?

        public init(id: String, toggle: String, selector: String, routes: [String]? = nil) {
            self.id = id
            self.toggle = toggle
            self.selector = selector
            self.routes = routes
        }
    }

    public enum HeuristicType: String, Codable, Sendable {
        /// Hide elements containing (or being) an <a> whose href path matches `pattern`.
        case anchorHref
        /// Hide elements matching a CSS selector `pattern` (for things CSS alone can't scope).
        case selector
    }

    public struct Heuristic: Codable, Sendable, Equatable {
        public var id: String
        public var toggle: String
        public var type: HeuristicType
        public var pattern: String
        /// How many ancestors above the match to hide (0 = the match itself).
        public var hideAncestor: Int?
        public var routes: [String]?

        public init(
            id: String, toggle: String, type: HeuristicType, pattern: String,
            hideAncestor: Int? = nil, routes: [String]? = nil
        ) {
            self.id = id
            self.toggle = toggle
            self.type = type
            self.pattern = pattern
            self.hideAncestor = hideAncestor
            self.routes = routes
        }
    }

    public enum BehaviorType: String, Codable, Sendable {
        /// After a media `ended` event, refuse a route change to a different item
        /// that the user didn't initiate (YouTube autoplay chain).
        case blockAutoAdvance
    }

    public struct Behavior: Codable, Sendable, Equatable {
        public var id: String
        public var toggle: String
        public var type: BehaviorType
        public var routes: [String]?
        /// Query parameter identifying the item (e.g. "v" for YouTube watch pages).
        public var param: String?
        /// Query parameters that exempt a page (e.g. "list": a playlist the user chose).
        public var exemptParams: [String]?

        public init(
            id: String, toggle: String, type: BehaviorType, routes: [String]? = nil,
            param: String? = nil, exemptParams: [String]? = nil
        ) {
            self.id = id
            self.toggle = toggle
            self.type = type
            self.routes = routes
            self.param = param
            self.exemptParams = exemptParams
        }
    }

    public struct CanaryCheck: Codable, Sendable, Equatable {
        public var anchorHref: String?
        public var selector: String?

        public init(anchorHref: String? = nil, selector: String? = nil) {
            self.anchorHref = anchorHref
            self.selector = selector
        }
    }

    public struct Canary: Codable, Sendable, Equatable {
        public var id: String
        public var toggle: String
        public var route: String
        public var mustNotExist: CanaryCheck

        public init(id: String, toggle: String, route: String, mustNotExist: CanaryCheck) {
            self.id = id
            self.toggle = toggle
            self.route = route
            self.mustNotExist = mustNotExist
        }
    }

    public struct ResourceBlock: Codable, Sendable, Equatable {
        public var id: String
        public var toggle: String
        /// WebKit content-rule `url-filter` regex (WebKit's restricted dialect).
        public var urlFilter: String
        /// WebKit resource types, e.g. ["script", "media"]; nil = all.
        public var resourceTypes: [String]?

        public init(id: String, toggle: String, urlFilter: String, resourceTypes: [String]? = nil) {
            self.id = id
            self.toggle = toggle
            self.urlFilter = urlFilter
            self.resourceTypes = resourceTypes
        }
    }
}

extension Recipe {
    public func toggleDefault(_ id: String) -> Bool? {
        toggles.first { $0.id == id }?.defaultOn
    }

    /// Path for a landing key; falls back to the recipe default, then "/".
    public func landingPath(for key: String?) -> String {
        if let key, let path = landing.options[key] { return path }
        return landing.options[landing.default] ?? "/"
    }

    /// Landing for the user's choice, or the signed-out landing when there's no session.
    public func landingPath(for key: String?, signedIn: Bool) -> String {
        if !signedIn, let k = landing.signedOut, let path = landing.options[k] { return path }
        return landingPath(for: key)
    }
}
