import Foundation

/// "Old Instagram": the feed and stories show only people on the user's Friends list
/// (ARCHITECTURE.md §4c). The list lives in `PlatformSettings.friends`, so it goes through the
/// ratchet. Usernames only, lower-cased, on-device only.
public enum Friends {
    public static let maxCount = 2000
    /// Rule id of the generated story-viewer gate (see `storyGateRule`).
    public static let storyGateID = "ig.friends.storyGate"

    /// "@Alice.B " → "alice.b". nil if it isn't a valid username (letters, digits, `.` and `_`,
    /// at most 30 characters).
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("@") { s.removeFirst() }
        guard isValid(s) else { return nil }
        return s
    }

    public static func isValid(_ username: String) -> Bool {
        guard (1...30).contains(username.count) else { return false }
        return username.unicodeScalars.allSatisfy { c in
            ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "." || c == "_"
        }
    }

    /// Regex for `/stories/<user>/…` where `<user>` is neither a friend nor exempt (highlights).
    /// Lookahead only (no lookbehind), so ICU and JavaScript agree (RecipeValidator subset).
    public static func storyGatePattern(friends: [String], exempt: [String]) -> String {
        let names = (friends + exempt).sorted().map(escape)
        return "^/stories/(?!(?:\(names.joined(separator: "|")))(?:/|$))[^/]+(?:/|$)"
    }

    /// The gate as an ordinary route rule: every existing layer (navigation delegate, page guard,
    /// native backstop, both watchdogs) enforces it with no new engine code.
    public static func storyGateRule(friends: [String], filter: Recipe.FriendsFilter, forceFollowing: Bool) -> Recipe.RouteRule {
        Recipe.RouteRule(id: storyGateID, toggle: filter.toggle,
                         pattern: storyGatePattern(friends: friends, exempt: filter.storyExempt),
                         action: .redirect, to: filter.feedPath(forceFollowing: forceFollowing))
    }

    /// Usernames contain only `[a-z0-9._]`; `.` is the one regex metacharacter among them.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: "\\.")
    }
}

/// What the page script needs to run the friends filter. nil in `ActiveRecipe` = Old Instagram off.
public struct ActiveFriends: Codable, Sendable, Equatable {
    public var usernames: [String]
    public var forceFollowing: Bool

    public init(usernames: [String], forceFollowing: Bool) {
        self.usernames = usernames
        self.forceFollowing = forceFollowing
    }
}

/// Which list a scan message came from.
public enum FriendsScanList: String, Codable, Sendable, CaseIterable {
    case followers, following, closeFriends
}

/// Usernames read from the lists the user opened in the Instagram tab (setup flow). Never part of
/// the policy: these are only *suggestions*; the user adds friends from them. Stored on-device in
/// its own file.
public struct FriendsScanState: Codable, Sendable, Equatable {
    public static let file = "ig-friends-scan.json"
    /// Per list, so one huge list can't crowd out the others.
    public static let maxPerList = 20_000

    /// Whose Followers/Following we read. A scan of a different account starts over.
    public var owner: String?
    public var followers: Set<String>
    public var following: Set<String>
    public var closeFriends: Set<String>
    public var updatedAt: Date?

    public init(owner: String? = nil, followers: Set<String> = [], following: Set<String> = [],
                closeFriends: Set<String> = [], updatedAt: Date? = nil) {
        self.owner = owner
        self.followers = followers
        self.following = following
        self.closeFriends = closeFriends
        self.updatedAt = updatedAt
    }

    /// Add usernames seen on one list. `owner` is the account in the URL (nil for Close Friends,
    /// which is always your own). Invalid names are dropped; the owner never counts as their own
    /// follower. Returns how many were new.
    @discardableResult
    public mutating func merge(_ list: FriendsScanList, owner rawOwner: String?, usernames: [String], now: Date) -> Int {
        if list != .closeFriends {
            guard let o = rawOwner.flatMap(Friends.normalize) else { return 0 }
            if owner != o {
                owner = o
                followers = []
                following = []
            }
        }
        let names = usernames.compactMap(Friends.normalize).filter { $0 != owner }
        var added = 0
        func add(_ set: inout Set<String>) {
            for n in names where set.count < Self.maxPerList {
                if set.insert(n).inserted { added += 1 }
            }
        }
        switch list {
        case .followers: add(&followers)
        case .following: add(&following)
        case .closeFriends: add(&closeFriends)
        }
        if added > 0 { updatedAt = now }
        return added
    }

    /// People who follow you and whom you follow.
    public var mutuals: Set<String> { followers.intersection(following) }

    /// Mutuals and close friends not already on the list, sorted.
    public func suggestions(excluding friends: [String]) -> [String] {
        mutuals.union(closeFriends).subtracting(friends).sorted()
    }

    public mutating func clear() {
        self = FriendsScanState()
    }
}
