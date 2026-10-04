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
    /// Paths whose on-screen time counts against the shared short-form budget.
    public var shortFormRoutes: [String]
    /// User agent the lite view should use: nil (WebKit default), "safari" or "desktopSafari".
    public var userAgent: String?
    /// "Old Instagram": how to find posts, authors and stories (ARCHITECTURE.md §4c). nil = none.
    public var friendsFilter: FriendsFilter?
    /// How search is reached while the recommendation surfaces are blocked (search modes). nil = none.
    public var search: SearchConfig?

    public init(
        platform: String, version: Int, minEngine: Int, hosts: [String], authHosts: [String] = [],
        landing: Landing, toggles: [Toggle], scopes: [String: String] = [:], routes: [RouteRule],
        hide: [HideRule] = [], heuristics: [Heuristic] = [], behaviors: [Behavior] = [],
        allowZones: [String] = [], canaries: [Canary] = [], resourceBlocks: [ResourceBlock] = [],
        session: Session? = nil, shortFormRoutes: [String] = [], userAgent: String? = nil,
        friendsFilter: FriendsFilter? = nil, search: SearchConfig? = nil
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
        self.shortFormRoutes = shortFormRoutes
        self.userAgent = userAgent
        self.friendsFilter = friendsFilter
        self.search = search
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
        shortFormRoutes = try c.decodeIfPresent([String].self, forKey: .shortFormRoutes) ?? []
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        friendsFilter = try c.decodeIfPresent(FriendsFilter.self, forKey: .friendsFilter)
        search = try c.decodeIfPresent(SearchConfig.self, forKey: .search)
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
        /// Host to load the landing page on (one of `hosts`). nil = the first "www." host.
        public var host: String?

        public init(default: String, options: [String: String], signedOut: String? = nil, host: String? = nil) {
            self.default = `default`
            self.options = options
            self.signedOut = signedOut
            self.host = host
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
        /// Part of a short-form surface (Reels/Shorts/Spotlight): dropped while the short-form
        /// budget has time left, forced on when it's used up (see `ShortFormMode`).
        public var shortForm: Bool?

        public init(
            id: String, toggle: String, pattern: String, action: RouteAction,
            to: String? = nil, scope: String? = nil, key: String? = nil, shortForm: Bool? = nil
        ) {
            self.id = id
            self.toggle = toggle
            self.pattern = pattern
            self.action = action
            self.to = to
            self.scope = scope
            self.key = key
            self.shortForm = shortForm
        }
    }

    public struct HideRule: Codable, Sendable, Equatable {
        public var id: String
        public var toggle: String
        public var selector: String
        /// Path regexes where this applies; nil = everywhere outside allow zones.
        public var routes: [String]?
        public var shortForm: Bool?

        public init(id: String, toggle: String, selector: String, routes: [String]? = nil, shortForm: Bool? = nil) {
            self.id = id
            self.toggle = toggle
            self.selector = selector
            self.routes = routes
            self.shortForm = shortForm
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
        public var shortForm: Bool?

        public init(
            id: String, toggle: String, type: HeuristicType, pattern: String,
            hideAncestor: Int? = nil, routes: [String]? = nil, shortForm: Bool? = nil
        ) {
            self.id = id
            self.toggle = toggle
            self.type = type
            self.pattern = pattern
            self.hideAncestor = hideAncestor
            self.routes = routes
            self.shortForm = shortForm
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
        public var shortForm: Bool?

        public init(id: String, toggle: String, route: String, mustNotExist: CanaryCheck, shortForm: Bool? = nil) {
            self.id = id
            self.toggle = toggle
            self.route = route
            self.mustNotExist = mustNotExist
            self.shortForm = shortForm
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
    /// Search while recommendations are blocked: the search entry stays, its page shows only the
    /// search box and results, never a post grid. Applied by `ActiveRecipe` per `SearchMode`.
    public struct SearchConfig: Codable, Sendable, Equatable {
        /// Search modes only matter while this toggle (blocking Explore) is on.
        public var toggle: String
        /// Rules that hide the search entry while search is off; dropped when it's on.
        public var entryRules: [String]
        /// The Explore root, sent straight to `searchPath` instead of showing its grid.
        public var rootPattern: String
        public var searchPath: String
        /// Path regexes of search pages (grid hidden there; "matching" filters results there).
        public var routes: [String]
        /// Path regex of a grid item (post/reel) on a search page.
        public var gridLink: String
        public var gridAncestor: Int

        public init(toggle: String, entryRules: [String], rootPattern: String, searchPath: String, routes: [String],
                    gridLink: String, gridAncestor: Int = 1) {
            self.toggle = toggle
            self.entryRules = entryRules
            self.rootPattern = rootPattern
            self.searchPath = searchPath
            self.routes = routes
            self.gridLink = gridLink
            self.gridAncestor = gridAncestor
        }
    }

    /// Data for the friends-only feed and stories. Selectors and regexes only; the page script
    /// (`bz-filter.js`) and `ActiveRecipe` interpret them. Matching is on `href`s, never text.
    public struct FriendsFilter: Codable, Sendable, Equatable {
        /// Master switch ("Old Instagram"). On + a non-empty Friends list = active.
        public var toggle: String
        /// Redirect the feed to its Following variant.
        public var forceFollowingToggle: String?
        /// Rules of these toggles run while the filter is active, even if switched off
        /// (suggestions, sponsored).
        public var forcedToggles: [String]
        /// Path regexes of the home feed.
        public var feedRoutes: [String]
        /// The feed's path, and the query that selects the Following feed ("variant=following").
        public var feedPath: String
        public var followingQuery: String?
        /// CSS selector of one feed post. Default deny: unmarked posts are hidden.
        public var post: String
        /// Path regex of a profile link; the first one in a post is its author.
        public var profileLink: String
        /// First path segments that aren't usernames (explore, p, reel, stories, …).
        public var reservedPaths: [String]
        /// Path regex of a post/reel permalink (canary: one visible outside a checked post).
        public var postLink: String
        /// CSS selector of a story-tray item that links to `/stories/<user>/`.
        public var storyTray: String
        /// Path regex of the story viewer with a named group `user`.
        public var storyRoute: String
        /// `/stories/<segment>/` values that aren't usernames (highlights).
        public var storyExempt: [String]
        /// CSS selector of the author's profile link inside the story viewer.
        public var storyAuthor: String
        /// Hidden posts in a row before "You're all caught up".
        public var caughtUpAfter: Int
        /// Seconds without a new post (last one hidden) before "You're all caught up".
        public var idleSeconds: Int
        /// Hidden posts in a row before "Finding posts from your people…". nil = 5.
        public var findingAfter: Int?
        /// Setup: list → path regex (named group `owner` for followers/following).
        public var scanRoutes: [String: String]
        /// Setup, Close Friends: selector of a checked row's checkbox.
        public var scanChecked: String

        public init(toggle: String, forceFollowingToggle: String? = nil, forcedToggles: [String] = [],
                    feedRoutes: [String], feedPath: String = "/", followingQuery: String? = nil,
                    post: String, profileLink: String, reservedPaths: [String] = [], postLink: String,
                    storyTray: String, storyRoute: String, storyExempt: [String] = [], storyAuthor: String,
                    caughtUpAfter: Int = 20, idleSeconds: Int = 4, scanRoutes: [String: String] = [:],
                    scanChecked: String = "input[type=checkbox]:checked") {
            self.toggle = toggle
            self.forceFollowingToggle = forceFollowingToggle
            self.forcedToggles = forcedToggles
            self.feedRoutes = feedRoutes
            self.feedPath = feedPath
            self.followingQuery = followingQuery
            self.post = post
            self.profileLink = profileLink
            self.reservedPaths = reservedPaths
            self.postLink = postLink
            self.storyTray = storyTray
            self.storyRoute = storyRoute
            self.storyExempt = storyExempt
            self.storyAuthor = storyAuthor
            self.caughtUpAfter = caughtUpAfter
            self.idleSeconds = idleSeconds
            self.scanRoutes = scanRoutes
            self.scanChecked = scanChecked
        }

        /// Where closing a story goes: the feed, as its Following variant when that's forced.
        public func feedPath(forceFollowing: Bool) -> String {
            guard forceFollowing, let q = followingQuery else { return feedPath }
            return feedPath + "?" + q
        }
    }

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
