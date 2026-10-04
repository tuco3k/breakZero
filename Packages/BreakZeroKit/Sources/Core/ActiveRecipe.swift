import Foundation

/// The user's per-platform choices. Part of `WallPolicy`, so changes go through the ratchet.
public struct PlatformSettings: Codable, Sendable, Equatable {
    /// Overrides of recipe toggle defaults. Missing = recipe default.
    public var toggles: [String: Bool]
    /// Landing option key (see `Recipe.Landing.options`). nil = recipe default.
    public var landing: String?
    /// User-added path regexes to block (advanced rules).
    public var customBlocks: [String]
    /// User-added CSS selectors to hide (advanced rules).
    public var customHides: [String]
    /// Feed rules "My list": normalized usernames, sorted (rev. 1's Friends list; see `Friends`).
    public var friends: [String]
    /// Feed rules: who the feed and stories show, always/never lists (ARCHITECTURE.md §4c).
    public var feedRules: FeedRules
    /// Search while Explore is blocked. nil = Normal (QUESTIONS #58).
    public var searchMode: SearchMode?

    public init(toggles: [String: Bool] = [:], landing: String? = nil, customBlocks: [String] = [], customHides: [String] = [],
                friends: [String] = [], feedRules: FeedRules = FeedRules(), searchMode: SearchMode? = nil) {
        self.toggles = toggles
        self.landing = landing
        self.customBlocks = customBlocks
        self.customHides = customHides
        self.friends = friends
        self.feedRules = feedRules
        self.searchMode = searchMode
    }

    // Missing keys default, so settings saved by an older build still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toggles = try c.decodeIfPresent([String: Bool].self, forKey: .toggles) ?? [:]
        landing = try c.decodeIfPresent(String.self, forKey: .landing)
        customBlocks = try c.decodeIfPresent([String].self, forKey: .customBlocks) ?? []
        customHides = try c.decodeIfPresent([String].self, forKey: .customHides) ?? []
        friends = try c.decodeIfPresent([String].self, forKey: .friends) ?? []
        if let rules = try c.decodeIfPresent(FeedRules.self, forKey: .feedRules) {
            feedRules = rules
        } else {
            // Saved before feed rules (rev. 1): a Friends list kept the feed to that list. Keep it
            // that way instead of silently widening to all mutuals (QUESTIONS #47).
            feedRules = friends.isEmpty ? FeedRules() : FeedRules(feed: .myList, stories: .myList)
        }
        searchMode = try c.decodeIfPresent(SearchMode.self, forKey: .searchMode)
    }

    public var search: SearchMode { searchMode ?? .normal }

    public static let `default` = PlatformSettings()

    public func isOn(_ toggle: String, in recipe: Recipe) -> Bool {
        toggles[toggle] ?? recipe.toggleDefault(toggle) ?? true
    }
}

/// A recipe with the user's settings applied: disabled rules removed, custom rules appended.
/// This is exactly what the native engine and the injected scripts both evaluate.
public struct ActiveRecipe: Codable, Sendable, Equatable {
    public static let customToggle = "custom"

    public var recipe: Recipe
    public var landingPath: String
    public var shortForm: ShortFormMode
    /// Feed rules, when they filter anything (the page script and the story gate read this).
    public var friends: ActiveFriends?
    /// Search mode, when the recipe has search and Explore is blocked (the page reads "matching").
    public var searchMode: SearchMode?

    /// - signedIn: false picks the recipe's signed-out landing (YouTube: search).
    /// - shortForm: `.budgetAllowed` drops every rule marked `shortForm`; `.forcedBlocked` keeps
    ///   them even when their toggle is off (budget used up / short-form schedule on).
    /// - people: who is mutual (data), for the feed rules.
    public init(recipe: Recipe, settings: PlatformSettings = .default, signedIn: Bool = true,
                shortForm: ShortFormMode = .togglesDecide, people: PeopleData? = nil) throws {
        var r = recipe
        let rulesOn = settings.feedRulesOn(in: recipe)
        // While feed rules are on, suggestions and ads are always hidden (forced toggles).
        let forced = Set(rulesOn ? recipe.friendsFilter?.forcedToggles ?? [] : [])
        let on = { (toggle: String) in forced.contains(toggle) || settings.isOn(toggle, in: recipe) }
        func keep(_ toggle: String, _ isShortForm: Bool?) -> Bool {
            guard isShortForm == true else { return on(toggle) }
            switch shortForm {
            case .togglesDecide: return on(toggle)
            case .budgetAllowed: return false
            case .forcedBlocked: return true
            }
        }
        r.routes = recipe.routes.filter { keep($0.toggle, $0.shortForm) }
        r.hide = recipe.hide.filter { keep($0.toggle, $0.shortForm) }
        r.heuristics = recipe.heuristics.filter { keep($0.toggle, $0.shortForm) }
        r.behaviors = recipe.behaviors.filter { on($0.toggle) }
        r.canaries = recipe.canaries.filter { keep($0.toggle, $0.shortForm) }
        r.resourceBlocks = recipe.resourceBlocks.filter { on($0.toggle) }

        if !settings.customBlocks.isEmpty || !settings.customHides.isEmpty {
            r.toggles.append(.init(id: Self.customToggle, defaultOn: true))
        }
        // Custom blocks go first: a user's own block must not be shadowed by a recipe allow.
        let custom = settings.customBlocks.enumerated().map { i, pattern in
            Recipe.RouteRule(id: "custom.block.\(i)", toggle: Self.customToggle,
                             pattern: pattern.hasPrefix("^") ? pattern : "^" + pattern, action: .block)
        }
        self.friends = nil
        if rulesOn, let f = recipe.friendsFilter {
            let feed = settings.allowed(.feed, people: people)
            let stories = settings.allowed(.stories, people: people)
            let never = settings.feedRules.never.sorted()
            if feed != nil || stories != nil || !never.isEmpty {
                let force = f.forceFollowingToggle.map(on) ?? false
                self.friends = ActiveFriends(feed: feed, stories: stories, never: never, forceFollowing: force,
                                             profileStories: settings.profileStories,
                                             closePath: f.feedPath(forceFollowing: force))
            }
        }
        // Search (QUESTIONS #58): with Explore blocked and search not Off, the search entry stays, the
        // Explore root goes straight to the search page, and grids on search pages are hidden.
        var searchRoutes: [Recipe.RouteRule] = []
        self.searchMode = nil
        if let sc = recipe.search, on(sc.toggle) {
            self.searchMode = settings.search
            if settings.search != .off {
                let entry = Set(sc.entryRules)
                r.routes.removeAll { entry.contains($0.id) }
                r.hide.removeAll { entry.contains($0.id) }
                r.heuristics.removeAll { entry.contains($0.id) }
                r.canaries.removeAll { entry.contains($0.id) }
                searchRoutes = [Recipe.RouteRule(id: "ig.search.root", toggle: sc.toggle, pattern: sc.rootPattern,
                                                 action: .redirect, to: sc.searchPath)]
                r.heuristics.append(Recipe.Heuristic(id: "ig.search.grid", toggle: sc.toggle, type: .anchorHref,
                                                     pattern: sc.gridLink, hideAncestor: sc.gridAncestor, routes: sc.routes))
                r.canaries.append(contentsOf: sc.routes.enumerated().map { i, route in
                    Recipe.Canary(id: "ig.search.gridCanary.\(i)", toggle: sc.toggle, route: route,
                                  mustNotExist: .init(anchorHref: sc.gridLink))
                })
            }
        }
        r.routes = custom + searchRoutes + r.routes
        r.hide += settings.customHides.enumerated().map { i, selector in
            Recipe.HideRule(id: "custom.hide.\(i)", toggle: Self.customToggle, selector: selector)
        }
        try RecipeValidator.validate(r)
        self.recipe = r
        self.landingPath = recipe.landingPath(for: settings.landing, signedIn: signedIn)
        self.shortForm = shortForm
    }
}
