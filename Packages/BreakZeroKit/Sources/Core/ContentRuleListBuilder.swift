import Foundation

/// Layer 1: turns an active recipe into WebKit content-blocker JSON for `WKContentRuleListStore`.
///
/// WebKit's `url-filter` is a restricted regex dialect: no `|`, no `{n,m}`, no named or
/// non-capturing groups, no backreferences. Route patterns that can't be translated are
/// skipped here; layer 2 (navigation delegate + route guard) still enforces them.
public enum ContentRuleListBuilder {
    public struct Rule: Codable, Equatable, Sendable {
        public struct Trigger: Codable, Equatable, Sendable {
            public var urlFilter: String
            public var resourceType: [String]?
            public var ifDomain: [String]?

            enum CodingKeys: String, CodingKey {
                case urlFilter = "url-filter"
                case resourceType = "resource-type"
                case ifDomain = "if-domain"
            }
        }

        public struct Action: Codable, Equatable, Sendable {
            public var type: String
        }

        public var trigger: Trigger
        public var action: Action
    }

    /// WebKit-safe if it has none of the constructs WebKit rejects.
    public static func isWebKitCompatible(_ pattern: String) -> Bool {
        if pattern.isEmpty { return false }
        for bad in ["|", "{", "}", "(?", "\\d", "\\w", "\\s", "\\b", "\\D", "\\W", "\\S", "\\B"] where pattern.contains(bad) {
            return false
        }
        // Backreferences like \1.
        if pattern.range(of: #"\\[0-9]"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// Translate a recipe path pattern (anchored with ^) into a full-URL WebKit filter for `host`.
    /// Returns nil if the pattern can't be expressed in WebKit's dialect.
    static func urlFilter(forPathPattern pattern: String, host: String) -> String? {
        // Named groups → plain groups (WebKit allows capturing groups, not names).
        var p = pattern.replacingOccurrences(of: #"\(\?<[A-Za-z][A-Za-z0-9]*>"#, with: "(", options: .regularExpression)
        guard p.hasPrefix("^") else { return nil }
        p.removeFirst()
        // A path pattern ending in `$` may be followed by a query/fragment in a full URL.
        if p.hasSuffix("$"), !p.hasSuffix("\\$") {
            p.removeLast()
            p += "([?#].*)?$"
        }
        let hostPart: String
        if host.hasPrefix("*.") {
            hostPart = "[^/]*" + escapeLiteral(String(host.dropFirst(1)))
        } else {
            hostPart = escapeLiteral(host)
        }
        let filter = "^https?://" + hostPart + p
        return isWebKitCompatible(filter) ? filter : nil
    }

    static func escapeLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: "\\.")
    }

    /// Build the rule list. Only `block` routes are compiled (redirects need the delegate),
    /// for top-level documents only — blocking subframes or XHR by route would break SPAs.
    public static func rules(for active: ActiveRecipe) -> [Rule] {
        var rules: [Rule] = []
        for route in active.recipe.routes where route.action == .block {
            for host in active.recipe.hosts {
                guard let filter = urlFilter(forPathPattern: route.pattern, host: host) else { continue }
                rules.append(Rule(trigger: .init(urlFilter: filter, resourceType: ["document"]),
                                  action: .init(type: "block")))
            }
        }
        for rb in active.recipe.resourceBlocks {
            rules.append(Rule(trigger: .init(urlFilter: rb.urlFilter, resourceType: rb.resourceTypes),
                              action: .init(type: "block")))
        }
        return rules
    }

    /// JSON string for `WKContentRuleListStore.compileContentRuleList(forIdentifier:encodedContentRuleList:)`.
    /// WebKit rejects an empty list, so an inert rule is emitted when there is nothing to block.
    public static func json(for active: ActiveRecipe) throws -> String {
        var list = rules(for: active)
        if list.isEmpty {
            list = [Rule(trigger: .init(urlFilter: "^bz-inert:"), action: .init(type: "block"))]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(list), as: UTF8.self)
    }
}
