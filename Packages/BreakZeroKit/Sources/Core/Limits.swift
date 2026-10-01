import Foundation

// Time limits, the shared short-form budget and schedules (ARCHITECTURE.md §4a).
// Everything here is pure and driven by `ClockSample`s, so it is tested with a fake clock.

/// What a schedule blocks.
public enum LimitTarget: Codable, Hashable, Sendable {
    /// Reels, Shorts, Spotlight on every platform.
    case shortForm
    /// The whole platform.
    case platform(Platform)
}

/// "Block X from `start` to `end`" in local time. `end` < `start` wraps past midnight
/// (23:00–07:00). Minutes after midnight, 0..<1440.
public struct ScheduleRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var target: LimitTarget
    public var start: Int
    public var end: Int
    /// Calendar weekdays (1 = Sunday … 7 = Saturday) the window *starts* on. nil = every day.
    public var weekdays: Set<Int>?

    public init(id: String, target: LimitTarget, start: Int, end: Int, weekdays: Set<Int>? = nil) {
        self.id = id
        self.target = target
        self.start = start
        self.end = end
        self.weekdays = weekdays
    }

    public var isValid: Bool {
        (0..<1440).contains(start) && (0..<1440).contains(end) && start != end
            && !id.isEmpty && id.count <= 64
            && (weekdays.map { !$0.isEmpty && $0.allSatisfy { (1...7).contains($0) } } ?? true)
    }

    /// Is the window on at `minute` (after local midnight) on `weekday`?
    public func isActive(minute: Int, weekday: Int) -> Bool {
        let previous = weekday == 1 ? 7 : weekday - 1
        func day(_ d: Int) -> Bool { weekdays?.contains(d) ?? true }
        if start < end { return day(weekday) && minute >= start && minute < end }
        // Wraps midnight: the evening part belongs to today, the morning part to yesterday's window.
        if minute >= start { return day(weekday) }
        if minute < end { return day(previous) }
        return false
    }

    /// Minutes in the window (for "is the new window at least as big" checks).
    public var length: Int { start < end ? end - start : 1440 - start + end }
}

/// All OFF by default.
public struct LimitsPolicy: Codable, Sendable, Equatable {
    public static let maxSchedules = 20

    /// Minutes per day per platform; absent = no limit.
    public var dailyMinutes: [Platform: Int]
    /// One budget shared by every platform's short-form surfaces. 0 = off.
    public var shortFormMinutes: Int
    public var schedules: [ScheduleRule]

    public init(dailyMinutes: [Platform: Int] = [:], shortFormMinutes: Int = 0, schedules: [ScheduleRule] = []) {
        self.dailyMinutes = dailyMinutes
        self.shortFormMinutes = shortFormMinutes
        self.schedules = schedules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailyMinutes = try c.decodeIfPresent([Platform: Int].self, forKey: .dailyMinutes) ?? [:]
        shortFormMinutes = try c.decodeIfPresent(Int.self, forKey: .shortFormMinutes) ?? 0
        schedules = try c.decodeIfPresent([ScheduleRule].self, forKey: .schedules) ?? []
    }

    public static let off = LimitsPolicy()
}

/// What was on screen since the previous sample.
public struct ScreenActivity: Equatable, Sendable {
    public var platform: Platform
    public var shortForm: Bool

    public init(platform: Platform, shortForm: Bool) {
        self.platform = platform
        self.shortForm = shortForm
    }
}

/// Today's usage, kept in its own file (`usage.json`) because it's written every few seconds.
public struct UsageState: Codable, Sendable, Equatable {
    public static let file = "usage.json"
    /// No single sample credits more than this to usage: a missed "went to background" can't
    /// turn into minutes of phantom use.
    public static let maxTick: TimeInterval = 30
    /// A "day" is never shorter than this, so changing the time zone can't bring a reset early.
    public static let minDayLength: TimeInterval = 20 * 3600

    public private(set) var ledger = ElapsedLedger()
    /// Trusted clock estimate: starts at the first sample's wall time and then advances only by
    /// credited (trusted) time. Clock changes never move it directly.
    public private(set) var trustedNow: Date?
    public private(set) var dayStartedAt: Date?
    public private(set) var dayEndsAt: Date?
    /// Time zone pinned when the day started; schedules and the next midnight use it.
    public private(set) var dayTimeZone: String?
    public private(set) var platformSeconds: [Platform: Double] = [:]
    public private(set) var shortFormSeconds: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ledger = try c.decodeIfPresent(ElapsedLedger.self, forKey: .ledger) ?? ElapsedLedger()
        trustedNow = try c.decodeIfPresent(Date.self, forKey: .trustedNow)
        dayStartedAt = try c.decodeIfPresent(Date.self, forKey: .dayStartedAt)
        dayEndsAt = try c.decodeIfPresent(Date.self, forKey: .dayEndsAt)
        dayTimeZone = try c.decodeIfPresent(String.self, forKey: .dayTimeZone)
        platformSeconds = try c.decodeIfPresent([Platform: Double].self, forKey: .platformSeconds) ?? [:]
        shortFormSeconds = try c.decodeIfPresent(Double.self, forKey: .shortFormSeconds) ?? 0
    }

    public var pinnedTimeZone: TimeZone {
        dayTimeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// Advance with a new sample. Call once a second while a lite tab is on screen in the
    /// foreground (with `activity`), and with `activity: nil` at every other check-in (launch,
    /// returning to the foreground, leaving a lite tab) so that gap is never counted as use.
    public mutating func tick(_ sample: ClockSample, activity: ScreenActivity?, timeZone: TimeZone = .current) {
        let credited = ledger.record(sample)
        guard let now = trustedNow else {
            // First sample ever: today began at the last local midnight.
            trustedNow = sample.wall
            startDay(at: Self.startOfDay(sample.wall, timeZone: timeZone), timeZone: timeZone, now: sample.wall)
            return
        }
        trustedNow = now.addingTimeInterval(credited)
        if let activity {
            let used = min(credited, Self.maxTick)
            platformSeconds[activity.platform, default: 0] += used
            if activity.shortForm { shortFormSeconds += used }
        }
        rollOverIfNeeded(timeZone: timeZone)
    }

    mutating func rollOverIfNeeded(timeZone: TimeZone) {
        guard let now = trustedNow, let end = dayEndsAt, now >= end else { return }
        platformSeconds = [:]
        shortFormSeconds = 0
        startDay(at: end, timeZone: timeZone, now: now)
    }

    /// `start` is a local midnight (the previous day's end, or the midnight before the first
    /// sample). The day ends at the next local midnight after `now`, but never less than
    /// `minDayLength` after `start`, so a time-zone change can't bring a reset forward.
    private mutating func startDay(at start: Date, timeZone: TimeZone, now: Date) {
        dayStartedAt = start
        dayTimeZone = timeZone.identifier
        let next = Self.nextMidnight(after: now, timeZone: timeZone)
        dayEndsAt = max(next, start.addingTimeInterval(Self.minDayLength))
    }

    static func startOfDay(_ date: Date, timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.startOfDay(for: date)
    }

    public static func nextMidnight(after date: Date, timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date)) ?? date.addingTimeInterval(86400)
    }

    /// Minute after local midnight and weekday of the trusted clock, in the pinned time zone.
    public func localTime() -> (minute: Int, weekday: Int)? {
        guard let now = trustedNow else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = pinnedTimeZone
        let c = cal.dateComponents([.hour, .minute, .weekday], from: now)
        return ((c.hour ?? 0) * 60 + (c.minute ?? 0), c.weekday ?? 1)
    }
}

public enum ShortFormMode: String, Codable, Sendable {
    /// Budget off and no short-form schedule on: the recipe toggles decide (today's default).
    case togglesDecide
    /// Budget left: short-form rules are dropped, Reels/Shorts work.
    case budgetAllowed
    /// Budget used up or a short-form schedule on: short-form rules run even if toggled off.
    case forcedBlocked
}

public enum BlockReason: String, Codable, Sendable {
    case dailyLimit
    case schedule
    case shortFormBudget
    case shortFormSchedule
}

public struct LimitStatus: Equatable, Sendable {
    /// Platforms that are done for now, and why.
    public var platformBlock: [Platform: BlockReason]
    public var shortForm: ShortFormMode
    /// Why short-form is forced off (when `shortForm == .forcedBlocked`).
    public var shortFormReason: BlockReason?
    /// Seconds left in the short-form budget (budget on only).
    public var shortFormRemaining: TimeInterval?
    /// Seconds left today per platform with a daily limit.
    public var platformRemaining: [Platform: TimeInterval]
    /// When the trusted day ends (for "back tomorrow" copy).
    public var dayEndsAt: Date?

    public static let unlimited = LimitStatus(platformBlock: [:], shortForm: .togglesDecide, shortFormReason: nil,
                                              shortFormRemaining: nil, platformRemaining: [:], dayEndsAt: nil)
}

public enum LimitEvaluator {
    /// Pass token for "extra time in breakZero" on a platform (same `PassLedger` as native passes).
    public static func passToken(_ p: Platform) -> String { "lite:\(p.rawValue)" }

    /// - activePassTokens: `appTokenID`s of passes active right now.
    public static func evaluate(_ limits: LimitsPolicy, usage: UsageState, activePassTokens: Set<String>,
                                platforms: [Platform]) -> LimitStatus {
        var status = LimitStatus.unlimited
        status.dayEndsAt = usage.dayEndsAt
        let local = usage.localTime()
        func scheduled(_ target: LimitTarget) -> Bool {
            guard let local else { return false }
            return limits.schedules.contains { $0.isValid && $0.target == target && $0.isActive(minute: local.minute, weekday: local.weekday) }
        }

        for p in platforms {
            let onPass = activePassTokens.contains(passToken(p))
            if let minutes = limits.dailyMinutes[p] {
                let left = TimeInterval(minutes * 60) - (usage.platformSeconds[p] ?? 0)
                status.platformRemaining[p] = max(0, left)
                if left <= 0, !onPass { status.platformBlock[p] = .dailyLimit }
            }
            if status.platformBlock[p] == nil, scheduled(.platform(p)), !onPass {
                status.platformBlock[p] = .schedule
            }
        }

        if scheduled(.shortForm) {
            status.shortForm = .forcedBlocked
            status.shortFormReason = .shortFormSchedule
        } else if limits.shortFormMinutes > 0 {
            let left = TimeInterval(limits.shortFormMinutes * 60) - usage.shortFormSeconds
            status.shortFormRemaining = max(0, left)
            if left > 0 {
                status.shortForm = .budgetAllowed
            } else {
                status.shortForm = .forcedBlocked
                status.shortFormReason = .shortFormBudget
            }
        }
        if limits.shortFormMinutes > 0, status.shortFormRemaining == nil {
            status.shortFormRemaining = max(0, TimeInterval(limits.shortFormMinutes * 60) - usage.shortFormSeconds)
        }
        return status
    }
}

/// Matches a recipe's `shortFormRoutes` (paths whose time counts against the budget).
public struct ShortFormMatcher: Sendable {
    private let regexes: [PathRegex]

    public init(_ recipe: Recipe) {
        regexes = recipe.shortFormRoutes.compactMap { try? PathRegex($0) }
    }

    public func matches(path: String) -> Bool {
        regexes.contains { $0.matches(path) }
    }
}
