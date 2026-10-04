import Foundation

/// Feed rules (ARCHITECTURE.md §4c rev. 2): the Instagram feed and stories show only people a rule
/// allows. Rules live in `PlatformSettings.feedRules` (through the ratchet); who is mutual lives in
/// `PeopleData` (data, refreshed without a cooldown). Usernames only, lower-cased, on-device only.
public enum Friends {
    /// Per list (My list, Always show, Never show).
    public static let maxCount = 5000
    /// Rule id the story gate reports (toasts, logs).
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
}

/// Instagram search while Explore is blocked (QUESTIONS #58–60). Off < matching < normal.
public enum SearchMode: String, Codable, Sendable, CaseIterable {
    /// The search entry is hidden and Explore blocked (the behavior before search modes).
    case off
    /// Search works, but result rows only show accounts the feed rule allows.
    case matching
    /// Search works for every account (default).
    case normal

    /// Higher = less restrictive.
    public var openness: Int {
        switch self {
        case .off: 0
        case .matching: 1
        case .normal: 2
        }
    }
}

/// Who a surface shows.
public enum Audience: String, Codable, Sendable, CaseIterable {
    /// Everyone I follow.
    case everyone
    /// I follow them and they follow me (default).
    case mutuals
    /// The manual list.
    case myList
    case closeFriends
}

public enum FeedSurface: String, Codable, Sendable, CaseIterable {
    case feed, stories
}

/// The editable lists. `myList` is stored in `PlatformSettings.friends` (rev. 1's Friends list).
public enum PeopleList: String, Codable, Sendable, CaseIterable {
    case myList, always, never
}

/// The rules part of `PlatformSettings`. Missing values take the defaults.
public struct FeedRules: Codable, Sendable, Equatable {
    public var feed: Audience?
    public var stories: Audience?
    /// Show even if the rule doesn't match.
    public var always: [String]
    /// Hide everywhere, even if the rule matches. Beats everything.
    public var never: [String]
    /// Play stories from a profile opened on purpose (one person). nil = on.
    public var profileStories: Bool?

    public init(feed: Audience? = nil, stories: Audience? = nil, always: [String] = [], never: [String] = [],
                profileStories: Bool? = nil) {
        self.feed = feed
        self.stories = stories
        self.always = always
        self.never = never
        self.profileStories = profileStories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feed = try c.decodeIfPresent(Audience.self, forKey: .feed)
        stories = try c.decodeIfPresent(Audience.self, forKey: .stories)
        always = try c.decodeIfPresent([String].self, forKey: .always) ?? []
        never = try c.decodeIfPresent([String].self, forKey: .never) ?? []
        profileStories = try c.decodeIfPresent(Bool.self, forKey: .profileStories)
    }

    /// Beta default (QUESTIONS #65): everyone you follow. Narrow rules hide most of the Following
    /// feed, so it keeps loading more; they're marked Experimental in the app.
    public static let defaultAudience = Audience.everyone
}

extension PlatformSettings {
    public func audience(_ surface: FeedSurface) -> Audience {
        switch surface {
        case .feed: feedRules.feed ?? FeedRules.defaultAudience
        case .stories: feedRules.stories ?? FeedRules.defaultAudience
        }
    }

    public var profileStories: Bool { feedRules.profileStories ?? true }

    public func list(_ list: PeopleList) -> [String] {
        switch list {
        case .myList: friends
        case .always: feedRules.always
        case .never: feedRules.never
        }
    }

    /// Feed rules are on: the recipe supports them and their switch is on.
    public func feedRulesOn(in recipe: Recipe) -> Bool {
        guard let f = recipe.friendsFilter else { return false }
        return isOn(f.toggle, in: recipe)
    }

    mutating func edit(_ list: PeopleList, _ body: (inout [String]) -> Void) {
        switch list {
        case .myList: body(&friends)
        case .always: body(&feedRules.always)
        case .never: body(&feedRules.never)
        }
    }

    /// A list edit can change what shows: `myList` only while a rule uses it.
    func listInUse(_ list: PeopleList) -> Bool {
        list != .myList || audience(.feed) == .myList || audience(.stories) == .myList
    }

    /// Who a surface may show: `(base(rule) ∪ always) − never`, sorted. nil = no audience filter
    /// (the rule's data doesn't exist yet, or "everyone" without a following list).
    public func allowed(_ surface: FeedSurface, people: PeopleData?) -> [String]? {
        guard let base = Self.base(audience(surface), myList: friends, people: people) else { return nil }
        return base.union(feedRules.always).subtracting(feedRules.never).sorted()
    }

    static func base(_ audience: Audience, myList: [String], people: PeopleData?) -> Set<String>? {
        switch audience {
        case .everyone: people.flatMap { $0.following.isEmpty ? nil : $0.following }
        case .mutuals: people.flatMap { $0.hasMutualsData ? $0.mutuals : nil }
        case .myList: Set(myList)
        case .closeFriends: people.flatMap { $0.closeFriends.isEmpty ? nil : $0.closeFriends }
        }
    }
}

/// What the page script and the native story gate need. nil in `ActiveRecipe` = feed rules off, or
/// on but nothing to filter yet.
public struct ActiveFriends: Codable, Sendable, Equatable {
    /// Allowed authors in the feed; nil = everyone (only `never` applies).
    public var feed: [String]?
    /// Allowed story owners; nil = everyone (only `never` applies).
    public var stories: [String]?
    public var never: [String]
    public var forceFollowing: Bool
    public var profileStories: Bool
    /// Where closing a story goes (the feed, Following variant when forced).
    public var closePath: String

    public init(feed: [String]?, stories: [String]?, never: [String], forceFollowing: Bool,
                profileStories: Bool, closePath: String) {
        self.feed = feed
        self.stories = stories
        self.never = never
        self.forceFollowing = forceFollowing
        self.profileStories = profileStories
        self.closePath = closePath
    }

    public func allows(_ surface: FeedSurface, _ user: String) -> Bool {
        if never.contains(user) { return false }
        let set = surface == .feed ? feed : stories
        return set.map { $0.contains(user) } ?? true
    }
}

/// Which list a scan/sync message came from.
public enum FriendsScanList: String, Codable, Sendable, CaseIterable {
    case followers, following, closeFriends
}

/// Who follows the user and whom they follow (the data rules are applied to). Never part of the
/// policy: refreshing it is data, not a rule change. Stored on-device in its own file.
public struct PeopleData: Codable, Sendable, Equatable {
    public static let file = "ig-people.json"
    /// rev. 1's scan file, read once and folded in.
    public static let legacyFile = "ig-friends-scan.json"
    public static let maxPerList = 20_000
    public static let staleAfter: TimeInterval = 30 * 86400

    public enum Source: String, Codable, Sendable { case export, sync, manual }

    /// The account the lists belong to.
    public var owner: String?
    public var followers: Set<String>
    public var following: Set<String>
    public var closeFriends: Set<String>
    public var updatedAt: Date?
    public var source: Source?

    public init(owner: String? = nil, followers: Set<String> = [], following: Set<String> = [],
                closeFriends: Set<String> = [], updatedAt: Date? = nil, source: Source? = nil) {
        self.owner = owner
        self.followers = followers
        self.following = following
        self.closeFriends = closeFriends
        self.updatedAt = updatedAt
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        followers = try c.decodeIfPresent(Set<String>.self, forKey: .followers) ?? []
        following = try c.decodeIfPresent(Set<String>.self, forKey: .following) ?? []
        closeFriends = try c.decodeIfPresent(Set<String>.self, forKey: .closeFriends) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        source = try c.decodeIfPresent(Source.self, forKey: .source)
    }

    /// Both lists are known, so "mutual" means something.
    public var hasMutualsData: Bool { !followers.isEmpty && !following.isEmpty }
    public var mutuals: Set<String> { followers.intersection(following) }
    /// I follow them; they don't follow me.
    public var followingOnly: Set<String> { following.subtracting(followers) }

    public func daysSinceUpdate(now: Date) -> Int? {
        updatedAt.map { max(0, Int(now.timeIntervalSince($0) / 86400)) }
    }

    public func isStale(now: Date) -> Bool {
        updatedAt.map { now.timeIntervalSince($0) >= Self.staleAfter } ?? false
    }

    public enum ReplaceError: Error, Equatable {
        /// An import with no following list would switch the rules off without a cooldown.
        case noFollowing
    }

    /// A full snapshot (data export): replaces both lists, and close friends if the export had them.
    public mutating func replace(followers newFollowers: Set<String>, following newFollowing: Set<String>,
                                 closeFriends newClose: Set<String>?, owner newOwner: String?, now: Date) throws {
        guard !newFollowing.isEmpty else { throw ReplaceError.noFollowing }
        followers = Self.cap(newFollowers)
        following = Self.cap(newFollowing)
        if let newClose { closeFriends = Self.cap(newClose) }
        if let newOwner { owner = newOwner }
        updatedAt = now
        source = .export
    }

    /// One list read to its end (auto-scroll): replace just that list.
    public mutating func replaceList(_ list: FriendsScanList, with names: Set<String>, source: Source, now: Date) {
        set(list, Self.cap(names))
        updatedAt = now
        self.source = source
    }

    /// A partial read (stopped early, manual scrolling): add only; it can't tell who was removed.
    @discardableResult
    public mutating func add(_ list: FriendsScanList, _ names: [String], source: Source, now: Date) -> Int {
        var current = get(list)
        var added = 0
        for n in names.compactMap(Friends.normalize) where current.count < Self.maxPerList {
            if current.insert(n).inserted { added += 1 }
        }
        set(list, current)
        if added > 0 {
            updatedAt = now
            self.source = source
        }
        return added
    }

    public func get(_ list: FriendsScanList) -> Set<String> {
        switch list {
        case .followers: followers
        case .following: following
        case .closeFriends: closeFriends
        }
    }

    mutating func set(_ list: FriendsScanList, _ names: Set<String>) {
        switch list {
        case .followers: followers = names
        case .following: following = names
        case .closeFriends: closeFriends = names
        }
    }

    static func cap(_ s: Set<String>) -> Set<String> {
        s.count <= maxPerList ? s : Set(s.sorted().prefix(maxPerList))
    }
}
