import Foundation

/// Per-tab navigation state the engine threads through decisions.
public struct NavigationState: Codable, Sendable, Equatable {
    /// An `allowOnce` admission: the one item (e.g. a reel id) the user may view,
    /// and where to bounce back to if they try to move on to another.
    public struct Grant: Codable, Sendable, Equatable {
        public var ruleID: String
        public var key: String
        public var returnTo: String

        public init(ruleID: String, key: String, returnTo: String) {
            self.ruleID = ruleID
            self.key = key
            self.returnTo = returnTo
        }
    }

    public var grant: Grant?
    /// Feed rules: the person whose stories were opened from their profile on purpose. Their
    /// stories play; moving on to someone else goes back to their profile.
    public var storyUser: String?

    public init(grant: Grant? = nil, storyUser: String? = nil) {
        self.grant = grant
        self.storyUser = storyUser
    }
}

public enum NavigationDecision: Equatable, Sendable {
    case allow
    /// Load this path (+query) on the same host instead.
    case redirect(to: String, reason: Reason)
    /// Not one of this platform's hosts: open outside the lite view (SFSafariViewController).
    case openExternally

    public enum Reason: Equatable, Sendable {
        case blocked(ruleID: String)
        case redirected(ruleID: String)
        /// Moved from the granted item to a different one (e.g. swiping to the next reel).
        case bounced(ruleID: String)
        /// An `allowOnce` route reached from outside its scope.
        case outOfScope(ruleID: String)
    }
}

/// Native half of layer 2. The injected route guard (`bz-filter.js`) implements the same
/// algorithm; both are checked against `Tests/CoreTests/Fixtures/route-vectors.json`.
public struct RuleEngine: Sendable {
    public let active: ActiveRecipe
    private let routes: [(Recipe.RouteRule, PathRegex)]
    private let scopes: [String: PathRegex]
    private let allowZones: [PathRegex]
    private let storyGate: StoryGate?

    public init(active: ActiveRecipe) throws {
        self.active = active
        self.routes = try active.recipe.routes.map { ($0, try PathRegex($0.pattern)) }
        self.scopes = try active.recipe.scopes.mapValues { try PathRegex($0) }
        self.allowZones = try active.recipe.allowZones.map { try PathRegex($0) }
        if let friends = active.friends, let f = active.recipe.friendsFilter {
            self.storyGate = try StoryGate(friends: friends, filter: f)
        } else {
            self.storyGate = nil
        }
    }

    public var recipe: Recipe { active.recipe }

    public func isFilteredHost(_ host: String?) -> Bool {
        HostPattern.matchesAny(recipe.hosts, host: host)
    }

    public func isAuthHost(_ host: String?) -> Bool {
        HostPattern.matchesAny(recipe.authHosts, host: host)
    }

    public func isAllowZone(path: String) -> Bool {
        allowZones.contains { $0.matches(path) }
    }

    /// Decide a top-level navigation to `url`, coming from `previous` (the page being left).
    public func decide(url: URL, from previous: URL?, state: inout NavigationState) -> NavigationDecision {
        let scheme = url.scheme?.lowercased()
        if scheme == "about" || scheme == "blob" || scheme == "data" { return .allow }
        guard scheme == "https" || scheme == "http" else { return .openExternally }
        if isAuthHost(url.host) { return .allow }
        guard isFilteredHost(url.host) else { return .openExternally }

        var previousPath: String?
        if let previous, isFilteredHost(previous.host) {
            previousPath = Self.pathAndQuery(previous)
        }
        return decide(path: Self.path(url), query: url.query, previousPathAndQuery: previousPath, state: &state)
    }

    /// Watchdog check of the page *as it is now*: the same decision with no side effects (the
    /// state is copied, nothing is granted, a granted DM reel stays allowed). Mirrored by
    /// `watchdogCheck` in bz-filter.js; both run the shared route vectors.
    public func check(url: URL, state: NavigationState) -> NavigationDecision {
        var copy = state
        return decide(url: url, from: nil, state: &copy)
    }

    /// Host-free core of `decide`, mirrored exactly by the JS route guard.
    public func decide(path: String, query: String?, previousPathAndQuery: String?, state: inout NavigationState) -> NavigationDecision {
        let path = path.isEmpty ? "/" : path
        let here = query.map { path + "?" + $0 } ?? path
        let previousPath = previousPathAndQuery.map { Self.stripQuery($0) }

        if let gate = storyGate {
            if let user = gate.storyUser(path) {
                return gate.decide(user: user, here: here, previousPath: previousPath,
                                   previousPathAndQuery: previousPathAndQuery, state: &state)
            }
            state.storyUser = nil
        }

        for (rule, regex) in routes {
            guard let captures = regex.firstMatch(path) else { continue }
            switch rule.action {
            case .allow:
                state.grant = nil
                return .allow
            case .block:
                state.grant = nil
                return redirectUnlessHere(active.landingPath, here: here, reason: .blocked(ruleID: rule.id))
            case .redirect:
                state.grant = nil
                let target = fill(rule.to ?? "{landing}", captures: captures)
                return redirectUnlessHere(target, here: here, reason: .redirected(ruleID: rule.id))
            case .allowOnce:
                let key = rule.key.flatMap { captures[$0] } ?? path
                if let grant = state.grant, grant.ruleID == rule.id {
                    if grant.key == key { return .allow }
                    let returnTo = grant.returnTo
                    state.grant = nil
                    return redirectUnlessHere(returnTo, here: here, reason: .bounced(ruleID: rule.id))
                }
                if let scopeName = rule.scope, let scope = scopes[scopeName],
                   let previousPath, scope.matches(previousPath) {
                    state.grant = .init(ruleID: rule.id, key: key, returnTo: previousPathAndQuery ?? previousPath)
                    return .allow
                }
                state.grant = nil
                return redirectUnlessHere(active.landingPath, here: here, reason: .outOfScope(ruleID: rule.id))
            }
        }
        state.grant = nil
        return .allow
    }

    private func redirectUnlessHere(_ target: String, here: String, reason: NavigationDecision.Reason) -> NavigationDecision {
        Self.redirectUnlessHere(target, here: here, reason: reason)
    }

    static func redirectUnlessHere(_ target: String, here: String, reason: NavigationDecision.Reason) -> NavigationDecision {
        // Never redirect to the page we're on: a recipe mistake must not become a reload loop.
        target == here ? .allow : .redirect(to: target, reason: reason)
    }

    private func fill(_ template: String, captures: [String: String]) -> String {
        var out = template.replacingOccurrences(of: "{landing}", with: active.landingPath)
        for (name, value) in captures {
            out = out.replacingOccurrences(of: "{\(name)}", with: Self.encodeComponent(value))
        }
        return out
    }

    /// Captures land in paths and query strings: keep only unreserved characters raw.
    static func encodeComponent(_ value: String) -> String {
        // ASCII only (CharacterSet.alphanumerics includes non-ASCII letters); matches the JS guard.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Percent-encoded path, as JavaScript's `location.pathname` reports it.
    public static func path(_ url: URL) -> String {
        let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return p.isEmpty ? "/" : p
    }

    public static func pathAndQuery(_ url: URL) -> String {
        let p = path(url)
        return url.query.map { p + "?" + $0 } ?? p
    }

    static func stripQuery(_ s: String) -> String {
        s.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
    }
}

/// Feed rules' story gate (ARCHITECTURE.md §4c rev. 2). Engine code rather than a route rule because
/// it depends on where you came from. Mirrored by `storyDecision` in bz-filter.js; both run the
/// shared route vectors.
struct StoryGate: Sendable {
    let friends: ActiveFriends
    let route: PathRegex
    let feedRoutes: [PathRegex]
    let exempt: Set<String>

    init(friends: ActiveFriends, filter: Recipe.FriendsFilter) throws {
        self.friends = friends
        self.route = try PathRegex(filter.storyRoute)
        self.feedRoutes = try filter.feedRoutes.map { try PathRegex($0) }
        self.exempt = Set(filter.storyExempt)
    }

    /// The story owner in a viewer path, lower-cased; nil if `path` isn't the story viewer.
    func storyUser(_ path: String) -> String? {
        route.firstMatch(path)?["user"]?.lowercased()
    }

    /// - Allowed person → play.
    /// - Opened from that person's profile → play them only (profile stories on), else stay on the
    ///   profile. Moving on to someone else → back to the profile you came from.
    /// - Never-shown → their profile if you came from it, else close.
    /// - From anywhere else that isn't the feed or a story → back to where you were.
    /// - From the feed or another story, or a direct load → close to the feed (the page tries the next
    ///   allowed person in the tray first).
    func decide(user: String, here: String, previousPath: String?, previousPathAndQuery: String?,
                state: inout NavigationState) -> NavigationDecision {
        let id = Friends.storyGateID
        if exempt.contains(user) { return .allow }
        if let opened = state.storyUser {
            if opened == user { return .allow }
            state.storyUser = nil
            return RuleEngine.redirectUnlessHere("/\(opened)/", here: here, reason: .bounced(ruleID: id))
        }
        if friends.allows(.stories, user) { return .allow }
        let profile = "/\(user)/"
        let fromProfile = previousPath.map { Self.trimSlash($0).lowercased() == "/" + user } ?? false
        if fromProfile {
            if friends.profileStories, !friends.never.contains(user) {
                state.storyUser = user
                return .allow
            }
            return RuleEngine.redirectUnlessHere(profile, here: here, reason: .bounced(ruleID: id))
        }
        if let prev = previousPath, let back = previousPathAndQuery, storyUser(prev) == nil,
           !feedRoutes.contains(where: { $0.matches(prev) }) {
            return RuleEngine.redirectUnlessHere(back, here: here, reason: .bounced(ruleID: id))
        }
        return RuleEngine.redirectUnlessHere(friends.closePath, here: here, reason: .redirected(ruleID: id))
    }

    static func trimSlash(_ p: String) -> String {
        p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }
}
