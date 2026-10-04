import Foundation

public struct RecipeValidationError: Error, Equatable, CustomStringConvertible {
    public var problems: [String]
    public var description: String { problems.joined(separator: "; ") }
}

/// Schema/semantic checks run on every recipe before use: bundled ones in tests,
/// downloaded ones before they replace the last good copy.
public enum RecipeValidator {
    /// Regex features where ICU and JavaScript disagree (or that we never need).
    static let forbiddenRegexTokens = ["(?i", "(?m", "(?s", "(?x", "(?#", "(?>", "\\A", "\\Z", "\\z",
                                       "\\p{", "\\P{", "*+", "++", "?+", "\\Q", "\\E", "(?<=", "(?<!"]

    public static func validate(_ recipe: Recipe, engineVersion: Int = recipeEngineVersion) throws {
        var problems: [String] = []
        func check(_ ok: Bool, _ message: @autoclosure () -> String) {
            if !ok { problems.append(message()) }
        }
        func checkRegex(_ pattern: String, _ where_: String) {
            for token in forbiddenRegexTokens where pattern.contains(token) {
                problems.append("\(where_): regex uses unsupported token \(token)")
            }
            do { _ = try PathRegex(pattern) } catch {
                problems.append("\(where_): regex does not compile: \(pattern)")
            }
        }

        check(!recipe.platform.isEmpty, "platform is empty")
        check(recipe.platform.allSatisfy { $0.isLetter || $0.isNumber }, "platform must be alphanumeric")
        check(recipe.version >= 1, "version must be >= 1")
        check(recipe.minEngine >= 1, "minEngine must be >= 1")
        check(recipe.minEngine <= engineVersion, "minEngine \(recipe.minEngine) > engine \(engineVersion)")
        check(!recipe.hosts.isEmpty, "hosts is empty")
        for host in recipe.hosts + recipe.authHosts {
            check(HostPattern.isValid(host), "invalid host pattern \(host)")
        }
        check(recipe.landing.options[recipe.landing.default] != nil, "landing default has no path")
        if let h = recipe.landing.host {
            check(recipe.hosts.contains(h) && !h.hasPrefix("*."), "landing host must be one of hosts")
        }
        if let ua = recipe.userAgent {
            check(["safari", "desktopSafari"].contains(ua), "userAgent must be safari or desktopSafari")
        }
        if let k = recipe.landing.signedOut {
            check(recipe.landing.options[k] != nil, "landing signedOut has no path")
        }
        for (key, path) in recipe.landing.options {
            check(path.hasPrefix("/"), "landing \(key) must be a path")
        }

        let toggleIDs = recipe.toggles.map(\.id)
        check(Set(toggleIDs).count == toggleIDs.count, "duplicate toggle ids")
        var ruleIDs: [String] = []
        func checkToggle(_ toggle: String, _ id: String) {
            ruleIDs.append(id)
            check(toggleIDs.contains(toggle), "\(id): unknown toggle \(toggle)")
        }

        for (name, pattern) in recipe.scopes { checkRegex(pattern, "scope \(name)") }
        for r in recipe.shortFormRoutes {
            checkRegex(r, "shortFormRoutes")
            check(r.hasPrefix("^"), "shortFormRoutes must be anchored with ^")
        }
        for zone in recipe.allowZones { checkRegex(zone, "allowZone") }

        for route in recipe.routes {
            checkToggle(route.toggle, route.id)
            checkRegex(route.pattern, route.id)
            check(route.pattern.hasPrefix("^"), "\(route.id): route patterns must be anchored with ^")
            switch route.action {
            case .redirect:
                if let to = route.to {
                    check(to.hasPrefix("/") || to == "{landing}", "\(route.id): redirect target must be a path")
                    let groups = Set(PathRegex.namedGroups(in: route.pattern)).union(["landing"])
                    for name in templateNames(in: to) {
                        check(groups.contains(name), "\(route.id): template {\(name)} has no capture")
                    }
                } else {
                    problems.append("\(route.id): redirect needs `to`")
                }
            case .allowOnce:
                if let scope = route.scope {
                    check(recipe.scopes[scope] != nil, "\(route.id): unknown scope \(scope)")
                } else {
                    problems.append("\(route.id): allowOnce needs `scope`")
                }
                if let key = route.key {
                    check(PathRegex.namedGroups(in: route.pattern).contains(key), "\(route.id): key \(key) is not a capture")
                } else {
                    problems.append("\(route.id): allowOnce needs `key`")
                }
            case .allow, .block:
                break
            }
        }
        for rule in recipe.hide {
            checkToggle(rule.toggle, rule.id)
            check(!rule.selector.isEmpty, "\(rule.id): empty selector")
            check(!rule.selector.contains("{") && !rule.selector.contains("}"), "\(rule.id): selector may not contain braces")
            check(!rule.selector.contains("<"), "\(rule.id): selector may not contain <")
            for r in rule.routes ?? [] { checkRegex(r, rule.id) }
        }
        for h in recipe.heuristics {
            checkToggle(h.toggle, h.id)
            if h.type == .anchorHref { checkRegex(h.pattern, h.id) }
            check((h.hideAncestor ?? 0) >= 0 && (h.hideAncestor ?? 0) <= 8, "\(h.id): hideAncestor out of range 0...8")
            for r in h.routes ?? [] { checkRegex(r, h.id) }
        }
        for b in recipe.behaviors {
            checkToggle(b.toggle, b.id)
            for r in b.routes ?? [] { checkRegex(r, b.id) }
        }
        for c in recipe.canaries {
            checkToggle(c.toggle, c.id)
            checkRegex(c.route, c.id)
            check(c.mustNotExist.anchorHref != nil || c.mustNotExist.selector != nil, "\(c.id): empty canary check")
            if let p = c.mustNotExist.anchorHref { checkRegex(p, c.id) }
        }
        for rb in recipe.resourceBlocks {
            checkToggle(rb.toggle, rb.id)
            check(ContentRuleListBuilder.isWebKitCompatible(rb.urlFilter), "\(rb.id): urlFilter not WebKit-compatible")
        }
        if let f = recipe.friendsFilter {
            func selector(_ sel: String, _ name: String) {
                check(!sel.isEmpty && !sel.contains("{") && !sel.contains("}") && !sel.contains("<"),
                      "friendsFilter.\(name): invalid selector")
            }
            check(toggleIDs.contains(f.toggle), "friendsFilter: unknown toggle \(f.toggle)")
            if let t = f.forceFollowingToggle { check(toggleIDs.contains(t), "friendsFilter: unknown toggle \(t)") }
            for t in f.forcedToggles { check(toggleIDs.contains(t), "friendsFilter: unknown forced toggle \(t)") }
            for r in f.feedRoutes { checkRegex(r, "friendsFilter.feedRoutes") }
            check(f.feedPath.hasPrefix("/") && !f.feedPath.contains("?"), "friendsFilter.feedPath must be a path")
            if let q = f.followingQuery {
                check(!q.isEmpty && !q.contains("?") && !q.contains("#") && !q.contains("&"), "friendsFilter.followingQuery must be one name=value")
            }
            selector(f.post, "post")
            selector(f.storyTray, "storyTray")
            selector(f.storyAuthor, "storyAuthor")
            selector(f.scanChecked, "scanChecked")
            checkRegex(f.profileLink, "friendsFilter.profileLink")
            check(PathRegex.namedGroups(in: f.profileLink).contains("user"), "friendsFilter.profileLink needs a `user` group")
            checkRegex(f.postLink, "friendsFilter.postLink")
            checkRegex(f.storyRoute, "friendsFilter.storyRoute")
            check(PathRegex.namedGroups(in: f.storyRoute).contains("user"), "friendsFilter.storyRoute needs a `user` group")
            for e in f.storyExempt { check(Friends.isValid(e), "friendsFilter.storyExempt: invalid \(e)") }
            check((1...200).contains(f.caughtUpAfter), "friendsFilter.caughtUpAfter out of range 1...200")
            check((1...60).contains(f.idleSeconds), "friendsFilter.idleSeconds out of range 1...60")
            for (list, r) in f.scanRoutes {
                check(FriendsScanList(rawValue: list) != nil, "friendsFilter.scanRoutes: unknown list \(list)")
                checkRegex(r, "friendsFilter.scanRoutes.\(list)")
            }
        }
        if let sc = recipe.search {
            check(toggleIDs.contains(sc.toggle), "search: unknown toggle \(sc.toggle)")
            checkRegex(sc.rootPattern, "search.rootPattern")
            check(sc.rootPattern.hasPrefix("^"), "search.rootPattern must be anchored with ^")
            check(sc.searchPath.hasPrefix("/") && !sc.searchPath.contains("{"), "search.searchPath must be a path")
            check(!sc.routes.isEmpty, "search.routes is empty")
            for r in sc.routes { checkRegex(r, "search.routes") }
            checkRegex(sc.gridLink, "search.gridLink")
            check((0...8).contains(sc.gridAncestor), "search.gridAncestor out of range 0...8")
        }
        check(Set(ruleIDs).count == ruleIDs.count, "duplicate rule ids")

        if !problems.isEmpty { throw RecipeValidationError(problems: problems) }
    }

    /// `{name}` placeholders in a redirect template.
    static func templateNames(in template: String) -> [String] {
        var names: [String] = []
        var rest = template[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            names.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return names
    }
}

/// Host matching: "example.com" matches exactly; "*.example.com" matches any subdomain
/// (but not example.com itself — list both if both are wanted).
public enum HostPattern {
    public static func isValid(_ pattern: String) -> Bool {
        let body = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
        guard !body.isEmpty, body.contains("."), body == body.lowercased() else { return false }
        return body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    public static func matches(_ pattern: String, host: String) -> Bool {
        let host = host.lowercased()
        if pattern.hasPrefix("*.") {
            return host.hasSuffix(String(pattern.dropFirst(1)))
        }
        return host == pattern
    }

    public static func matchesAny(_ patterns: [String], host: String?) -> Bool {
        guard let host else { return false }
        return patterns.contains { matches($0, host: host) }
    }
}
