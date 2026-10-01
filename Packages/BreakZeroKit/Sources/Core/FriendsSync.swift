import Foundation

/// Pace of the visible auto-scroll in the Instagram tab (QUESTIONS #46). The page picks each delay
/// at random within these bounds.
public struct SyncPacing: Codable, Sendable, Equatable {
    /// Seconds between one screen-height scroll and the next.
    public var minStep: Double
    public var maxStep: Double
    /// About every `pauseEvery` screens, a longer pause.
    public var pauseEvery: Int
    public var minPause: Double
    public var maxPause: Double

    public init(minStep: Double = 2, maxStep: Double = 4, pauseEvery: Int = 12, minPause: Double = 8, maxPause: Double = 15) {
        self.minStep = minStep
        self.maxStep = maxStep
        self.pauseEvery = pauseEvery
        self.minPause = minPause
        self.maxPause = maxPause
    }

    public static let `default` = SyncPacing()

    /// Never faster than one screen a second, pauses longer than steps.
    public var isValid: Bool {
        minStep >= 1 && maxStep >= minStep && pauseEvery >= 1 && minPause >= maxStep && maxPause >= minPause
    }
}

public enum SyncStopReason: String, Codable, Sendable, CaseIterable {
    /// Read the per-session maximum; tap again later to continue.
    case cap
    /// Instagram showed a challenge/checkpoint.
    case challenge
    /// Instagram asked to log in.
    case login
    /// A dialog without the list appeared (e.g. "Try again later").
    case warning
    /// Nothing new loaded for a while away from the end.
    case stalled
    /// The page left the list (the user navigated away).
    case leftPage
    case userStopped

    /// Reasons that mean "Instagram objected": say so plainly and don't retry by ourselves.
    public var isWarning: Bool { self == .challenge || self == .login || self == .warning }
}

/// Auto-scroll sync of the user's own Followers, then Following (ARCHITECTURE.md §4c rev. 2).
/// Pure state machine: the page scrolls and reports names and events; this decides when to stop,
/// what to save and where to resume. Persisted, so the next session continues.
public struct SyncSession: Codable, Sendable, Equatable {
    public static let file = "ig-sync.json"
    /// New names per list per session.
    public static let defaultCap = 800
    /// A list "read to the end" replaces the old one only if it has at least this share of it;
    /// otherwise the end was probably a stall and we only add (QUESTIONS #49).
    public static let replaceThreshold = 0.5

    public var owner: String
    public var lists: [FriendsScanList]
    public var listIndex: Int
    /// Names read in this pass (across sessions), per list.
    public var collected: [FriendsScanList: Set<String>]
    /// How long each list was when this pass first started on it.
    public var baseline: [FriendsScanList: Int]
    public var newThisSession: Int
    public var cap: Int
    public var running: Bool
    public var finished: Bool
    public var lastStop: SyncStopReason?
    /// A list ended but looked much shorter than before, so it was only added to.
    public var incompleteLists: Set<FriendsScanList>

    public init(owner: String, lists: [FriendsScanList] = [.followers, .following], cap: Int = defaultCap) {
        self.owner = owner
        self.lists = lists
        self.listIndex = 0
        self.collected = [:]
        self.baseline = [:]
        self.newThisSession = 0
        self.cap = cap
        self.running = false
        self.finished = false
        self.lastStop = nil
        self.incompleteLists = []
    }

    public var currentList: FriendsScanList? { listIndex < lists.count ? lists[listIndex] : nil }

    public enum Step: Equatable, Sendable {
        case keepGoing
        case stop(SyncStopReason)
        case nextList(FriendsScanList)
        case finished
    }

    /// Start (or resume) on the user's tap. A finished pass starts over from the first list.
    public mutating func begin(people: PeopleData) {
        if finished || currentList == nil {
            listIndex = 0
            collected = [:]
            baseline = [:]
            incompleteLists = []
            finished = false
        }
        running = true
        newThisSession = 0
        lastStop = nil
        if let list = currentList, baseline[list] == nil { baseline[list] = people.get(list).count }
    }

    /// Names the page read. Adds them to the data at once (data, not a rule change).
    public mutating func record(_ list: FriendsScanList, _ names: [String], people: inout PeopleData, now: Date) -> Step {
        guard running, list == currentList else { return .keepGoing }
        var set = collected[list] ?? []
        var fresh: [String] = []
        for n in names.compactMap(Friends.normalize) where n != owner && set.insert(n).inserted {
            fresh.append(n)
        }
        collected[list] = set
        let budget = max(0, cap - newThisSession)
        let counted = Array(fresh.prefix(budget))
        newThisSession += counted.count
        people.add(list, counted, source: .sync, now: now)
        if newThisSession >= cap {
            running = false
            lastStop = .cap
            return .stop(.cap)
        }
        return .keepGoing
    }

    /// The page reached the end of `list`: replace it (unless it looks incomplete) and move on.
    public mutating func reachedEnd(_ list: FriendsScanList, people: inout PeopleData, now: Date) -> Step {
        guard running, list == currentList else { return .keepGoing }
        let got = collected[list] ?? []
        let before = baseline[list] ?? 0
        if !got.isEmpty, Double(got.count) >= Double(before) * Self.replaceThreshold {
            people.replaceList(list, with: got, source: .sync, now: now)
        } else {
            incompleteLists.insert(list)
        }
        listIndex += 1
        newThisSession = 0
        if let next = currentList {
            if baseline[next] == nil { baseline[next] = people.get(next).count }
            return .nextList(next)
        }
        finished = true
        running = false
        return .finished
    }

    /// Stop now (warning, stall, cap from the page, user). What was read is already saved as
    /// additions; the next `begin` continues this list.
    public mutating func stop(_ reason: SyncStopReason) {
        running = false
        lastStop = reason
    }

    /// Lists finished in this pass, for progress copy.
    public var doneLists: [FriendsScanList] { Array(lists.prefix(listIndex)) }
}
