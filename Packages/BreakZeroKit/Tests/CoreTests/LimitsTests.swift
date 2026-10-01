import Foundation
import XCTest
@testable import Core

/// Fake-clock tests for daily limits, the short-form budget and schedules (owner item 7).
/// Clock starts Thursday 2026-10-01 20:00 in America/Denver.
final class UsageMeterTests: XCTestCase {
    let denver = TimeZone(identifier: "America/Denver")!
    let t0 = Date(timeIntervalSince1970: 1_790_906_400)   // 2026-10-01 20:00 MDT (Thursday)
    var clock = FakeClock()
    var usage = UsageState()
    let ig = ScreenActivity(platform: .instagram, shortForm: false)
    let reel = ScreenActivity(platform: .instagram, shortForm: true)
    let short = ScreenActivity(platform: .youtube, shortForm: true)

    override func setUp() {
        clock = FakeClock()
        clock.wall = t0
        usage = UsageState()
        usage.tick(clock.sample, activity: nil, timeZone: denver)
    }

    /// Foreground on a lite tab: one tick per second.
    func use(_ seconds: Int, _ activity: ScreenActivity?, tz: TimeZone? = nil) {
        for _ in 0..<seconds {
            clock.advance(1)
            usage.tick(clock.sample, activity: activity, timeZone: tz ?? denver)
        }
    }

    func local(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let f = DateFormatter()
        f.timeZone = denver
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    func testCountsOnlyWhileOnScreen() {
        use(60, ig)
        use(30, reel)
        use(20, short)
        XCTAssertEqual(usage.platformSeconds[.instagram], 90)
        XCTAssertEqual(usage.platformSeconds[.youtube], 20)
        XCTAssertEqual(usage.shortFormSeconds, 50, "Reels and Shorts share one budget")
    }

    func testBackgroundingIsNeverCounted() {
        use(10, ig)
        // App goes to the background for 10 minutes; first sample back is a nil-activity check-in.
        clock.advance(600)
        usage.tick(clock.sample, activity: nil, timeZone: denver)
        use(10, ig)
        XCTAssertEqual(usage.platformSeconds[.instagram], 20)
    }

    func testMissedBackgroundNoticeCountsAtMostOneTick() {
        use(5, ig)
        clock.advance(3600)
        usage.tick(clock.sample, activity: ig, timeZone: denver)
        XCTAssertEqual(usage.platformSeconds[.instagram], 5 + UsageState.maxTick)
    }

    func testMidnightRolloverResetsAtLocalMidnight() {
        XCTAssertEqual(local(usage.dayEndsAt), "2026-10-02 00:00")
        use(120, ig)
        // Jump (legitimately, same boot) to 23:59:50, then use across midnight.
        clock.advance(4 * 3600 - 130)
        usage.tick(clock.sample, activity: nil, timeZone: denver)
        use(5, reel)
        XCTAssertEqual(usage.platformSeconds[.instagram], 125)
        use(10, reel)
        XCTAssertEqual(usage.shortFormSeconds, 5, "reset at midnight; the seconds after it count for the new day")
        XCTAssertEqual(local(usage.dayEndsAt), "2026-10-03 00:00")
        XCTAssertEqual(local(usage.dayStartedAt), "2026-10-02 00:00")
    }

    func testClockForwardCannotResetTheDay() {
        use(600, ig)
        clock.jumpWall(26 * 3600)        // set the date forward past midnight
        usage.tick(clock.sample, activity: nil, timeZone: denver)
        use(10, ig)
        XCTAssertEqual(usage.platformSeconds[.instagram], 610, "no reset")
        XCTAssertEqual(local(usage.dayEndsAt), "2026-10-02 00:00")
        XCTAssertTrue(usage.ledger.tamperEvents.contains { $0.kind == .clockJumpedForward })
    }

    func testClockBackCannotExtendOrReset() {
        use(600, ig)
        let trusted = usage.trustedNow!
        clock.jumpWall(-3 * 3600)
        usage.tick(clock.sample, activity: ig, timeZone: denver)
        XCTAssertGreaterThanOrEqual(usage.trustedNow!, trusted, "trusted time never goes back")
        XCTAssertEqual(usage.platformSeconds[.instagram], 600)
        use(10, ig)
        XCTAssertEqual(usage.platformSeconds[.instagram], 610)
    }

    func testTimeZoneChangeCannotBringTheResetForward() {
        use(600, ig)
        let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!   // UTC+14: it's already tomorrow there
        use(10, ig, tz: kiritimati)
        XCTAssertEqual(usage.platformSeconds[.instagram], 610, "pinned zone: no early reset")
        // At Denver midnight the day rolls; the next day is at least 20 h even in the new zone.
        clock.advance(4 * 3600)
        usage.tick(clock.sample, activity: nil, timeZone: kiritimati)
        XCTAssertEqual(usage.platformSeconds[.instagram] ?? 0, 0)
        let length = usage.dayEndsAt!.timeIntervalSince(usage.dayStartedAt!)
        XCTAssertGreaterThanOrEqual(length, UsageState.minDayLength)
    }

    func testAppClosedOvernightSameBootRollsTheDay() {
        use(600, ig)
        clock.advance(12 * 3600)          // phone asleep in a drawer, app not running, same boot
        usage.tick(clock.sample, activity: nil, timeZone: denver)
        XCTAssertEqual(usage.platformSeconds[.instagram] ?? 0, 0)
    }

    func testRebootCanOnlyDelayTheReset() {
        use(600, ig)
        clock.reboot(after: 10 * 3600, newUptime: 60)   // off overnight; ledger credits ≤ 1 h + uptime
        usage.tick(clock.sample, activity: nil, timeZone: denver)
        XCTAssertEqual(usage.platformSeconds[.instagram], 600, "reset delayed, never early")
        clock.advance(3 * 3600)
        usage.tick(clock.sample, activity: nil, timeZone: denver)
        XCTAssertEqual(usage.platformSeconds[.instagram] ?? 0, 0, "trusted time catches up by running")
    }

    /// Kill the app mid-session and reopen it: usage survives (minus at most the unsaved seconds),
    /// the time the app was dead isn't counted, and the clock moved while it was dead changes nothing.
    func testKillAndReopenKeepsUsageAndIgnoresDowntime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bz-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SharedStore(directory: dir)
        use(300, ig)
        try store.write(usage, UsageState.file)       // the app saves every few seconds
        use(3, ig)                                     // …and is killed before the next save
        // Dead for 20 minutes; meanwhile someone sets the clock a day ahead.
        clock.advance(1200)
        clock.jumpWall(86400)
        var reopened = try XCTUnwrap(store.read(UsageState.self, UsageState.file))
        reopened.tick(clock.sample, activity: nil, timeZone: denver)   // launch check-in
        XCTAssertEqual(reopened.platformSeconds[.instagram], 300, "saved usage kept; downtime not counted; no reset")
        XCTAssertEqual(local(reopened.dayEndsAt), "2026-10-02 00:00")
        clock.advance(1)
        reopened.tick(clock.sample, activity: ig, timeZone: denver)
        XCTAssertEqual(reopened.platformSeconds[.instagram], 301)
    }

    func testStateRoundTripsAndOldFilesLoad() throws {
        use(30, reel)
        let data = try JSONEncoder().encode(usage)
        XCTAssertEqual(try JSONDecoder().decode(UsageState.self, from: data), usage)
        XCTAssertEqual(try JSONDecoder().decode(UsageState.self, from: Data("{}".utf8)), UsageState())
    }
}

final class LimitEvaluatorTests: XCTestCase {
    let denver = TimeZone(identifier: "America/Denver")!
    let t0 = Date(timeIntervalSince1970: 1_790_906_400)   // Thursday 20:00 MDT
    var clock = FakeClock()
    var usage = UsageState()

    override func setUp() {
        clock = FakeClock()
        clock.wall = t0
        usage = UsageState()
        usage.tick(clock.sample, activity: nil, timeZone: denver)
    }

    func use(_ seconds: Int, _ activity: ScreenActivity?) {
        for _ in 0..<seconds {
            clock.advance(1)
            usage.tick(clock.sample, activity: activity, timeZone: denver)
        }
    }

    func eval(_ limits: LimitsPolicy, passes: Set<String> = []) -> LimitStatus {
        LimitEvaluator.evaluate(limits, usage: usage, activePassTokens: passes, platforms: [.instagram, .youtube])
    }

    func testEverythingOffByDefault() {
        use(5000, .init(platform: .instagram, shortForm: true))
        XCTAssertEqual(eval(.off).platformBlock, [:])
        XCTAssertEqual(eval(.off).shortForm, .togglesDecide)
    }

    func testDailyLimitAndPass() {
        let limits = LimitsPolicy(dailyMinutes: [.instagram: 10])
        use(599, .init(platform: .instagram, shortForm: false))
        XCTAssertNil(eval(limits).platformBlock[.instagram])
        XCTAssertEqual(eval(limits).platformRemaining[.instagram], 1)
        use(1, .init(platform: .instagram, shortForm: false))
        XCTAssertEqual(eval(limits).platformBlock[.instagram], .dailyLimit)
        XCTAssertNil(eval(limits).platformBlock[.youtube])
        XCTAssertNil(eval(limits, passes: [LimitEvaluator.passToken(.instagram)]).platformBlock[.instagram], "a pass lifts it")
        XCTAssertEqual(eval(limits, passes: [LimitEvaluator.passToken(.youtube)]).platformBlock[.instagram], .dailyLimit)
    }

    func testBudgetRunsOutMidVideo() {
        let limits = LimitsPolicy(shortFormMinutes: 2)
        use(60, .init(platform: .instagram, shortForm: true))      // a minute of Reels
        XCTAssertEqual(eval(limits).shortForm, .budgetAllowed)
        // Watching a Short: every second is checked; the moment the budget is used up, it flips.
        var flippedAt: Int?
        for second in 1...90 {
            use(1, .init(platform: .youtube, shortForm: true))
            if flippedAt == nil, eval(limits).shortForm == .forcedBlocked { flippedAt = second }
        }
        XCTAssertEqual(flippedAt, 60, "blocked exactly when 2 minutes are used, mid-video")
        XCTAssertEqual(eval(limits).shortFormReason, .shortFormBudget)
        XCTAssertEqual(eval(limits).shortFormRemaining, 0)
        XCTAssertNil(eval(limits).platformBlock[.youtube], "the rest of YouTube still works")
        // Normal (non short-form) use doesn't touch the budget.
        let before = usage.shortFormSeconds
        use(30, .init(platform: .youtube, shortForm: false))
        XCTAssertEqual(usage.shortFormSeconds, before)
    }

    func testBudgetBackNextDay() {
        let limits = LimitsPolicy(shortFormMinutes: 1)
        use(61, .init(platform: .youtube, shortForm: true))
        XCTAssertEqual(eval(limits).shortForm, .forcedBlocked)
        clock.advance(5 * 3600)
        usage.tick(clock.sample, activity: nil, timeZone: denver)
        XCTAssertEqual(eval(limits).shortForm, .budgetAllowed)
    }

    func testSchedules() {
        // "Block Reels and Shorts after 9pm" and "block Instagram 11pm–7am".
        let limits = LimitsPolicy(schedules: [
            .init(id: "sf", target: .shortForm, start: 21 * 60, end: 0),
            .init(id: "ig", target: .platform(.instagram), start: 23 * 60, end: 7 * 60),
        ])
        XCTAssertEqual(eval(limits).shortForm, .togglesDecide, "20:00")
        clock.advance(3600)
        usage.tick(clock.sample, activity: nil, timeZone: denver)          // 21:00
        XCTAssertEqual(eval(limits).shortForm, .forcedBlocked)
        XCTAssertEqual(eval(limits).shortFormReason, .shortFormSchedule)
        XCTAssertNil(eval(limits).platformBlock[.instagram])
        clock.advance(2 * 3600)
        usage.tick(clock.sample, activity: nil, timeZone: denver)          // 23:00
        XCTAssertEqual(eval(limits).platformBlock[.instagram], .schedule)
        clock.advance(2 * 3600)
        usage.tick(clock.sample, activity: nil, timeZone: denver)          // 01:00 next day
        XCTAssertEqual(eval(limits).platformBlock[.instagram], .schedule, "wraps past midnight")
        XCTAssertEqual(eval(limits).shortForm, .togglesDecide, "short-form window ended at midnight")
        clock.advance(6 * 3600)
        usage.tick(clock.sample, activity: nil, timeZone: denver)          // 07:00
        XCTAssertNil(eval(limits).platformBlock[.instagram])
    }

    func testScheduleCantBeEscapedByClockOrTimeZone() {
        let limits = LimitsPolicy(schedules: [.init(id: "ig", target: .platform(.instagram), start: 19 * 60, end: 22 * 60)])
        XCTAssertEqual(eval(limits).platformBlock[.instagram], .schedule, "20:00")
        clock.jumpWall(-3 * 3600)    // set the clock to 17:00
        usage.tick(clock.sample, activity: nil, timeZone: denver)
        XCTAssertEqual(eval(limits).platformBlock[.instagram], .schedule)
        usage.tick(clock.sample, activity: nil, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(eval(limits).platformBlock[.instagram], .schedule, "zone is pinned for the day")
    }

    func testWeekdaysAndWrap() {
        // Friday-night-only window, 22:00–02:00.
        let rule = ScheduleRule(id: "x", target: .shortForm, start: 22 * 60, end: 2 * 60, weekdays: [6])
        XCTAssertTrue(rule.isActive(minute: 23 * 60, weekday: 6))
        XCTAssertTrue(rule.isActive(minute: 60, weekday: 7), "Saturday 01:00 belongs to Friday's window")
        XCTAssertFalse(rule.isActive(minute: 60, weekday: 6), "Friday 01:00 belongs to Thursday's")
        XCTAssertFalse(rule.isActive(minute: 23 * 60, weekday: 5))
        XCTAssertEqual(rule.length, 240)
        XCTAssertFalse(ScheduleRule(id: "y", target: .shortForm, start: 60, end: 60).isValid)
        XCTAssertFalse(ScheduleRule(id: "z", target: .shortForm, start: 0, end: 60, weekdays: [0]).isValid)
    }
}

final class LimitsRatchetTests: XCTestCase {
    var ratchet: Ratchet!
    var policy = WallPolicy(lockEnabled: true)
    var lock = LockState()
    var clock = FakeClock()

    override func setUpWithError() throws {
        ratchet = Ratchet(recipes: [try RecipeLibrary.bundled(.instagram), try RecipeLibrary.bundled(.youtube)])
        policy = WallPolicy(lockEnabled: true)
        lock = LockState()
        lock.ledger.record(clock.sample)
    }

    func submit(_ c: PolicyChange) -> SubmitResult { ratchet.submit([c], policy: &policy, lock: &lock, at: clock.sample)[0] }

    func testShortFormTogglesComeFromRecipes() {
        XCTAssertEqual(ratchet.shortFormToggles[.instagram], ["ig.blockReels"])
        XCTAssertEqual(ratchet.shortFormToggles[.youtube], ["yt.shortsAsVideos", "yt.hideShorts"])
    }

    func testDailyLimitDirections() {
        XCTAssertEqual(submit(.setDailyLimit(.instagram, minutes: 30)), .applied(.tightening), "none → some is instant")
        XCTAssertEqual(submit(.setDailyLimit(.instagram, minutes: 20)), .applied(.tightening), "lowering is instant")
        guard case .queued = submit(.setDailyLimit(.instagram, minutes: 45)) else { return XCTFail("raising waits") }
        guard case .queued = submit(.setDailyLimit(.instagram, minutes: nil)) else { return XCTFail("removing waits") }
        XCTAssertEqual(policy.limits.dailyMinutes[.instagram], 20)
    }

    func testBudgetDirections() {
        guard case .queued = submit(.setShortFormBudget(minutes: 10)) else {
            return XCTFail("turning the budget on allows Reels for the first time: loosening")
        }
        clock.advance(86400 + 1)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(policy.limits.shortFormMinutes, 10)
        XCTAssertEqual(submit(.setShortFormBudget(minutes: 5)), .applied(.tightening))
        XCTAssertEqual(submit(.setShortFormBudget(minutes: 0)), .applied(.tightening), "off again = never")
        guard case .queued = submit(.setShortFormBudget(minutes: 1)) else { return XCTFail("adding minutes waits") }
    }

    func testBudgetOffIsLooseningWhenReelsWereUnblocked() {
        policy.platformSettings[.instagram] = PlatformSettings(toggles: ["ig.blockReels": false])
        policy.limits.shortFormMinutes = 10
        guard case .queued = submit(.setShortFormBudget(minutes: 0)) else {
            return XCTFail("with Reels unblocked, removing the budget means unlimited Reels")
        }
    }

    func testSchedulesAddInstantRemoveWaits() {
        let rule = ScheduleRule(id: "night", target: .platform(.instagram), start: 23 * 60, end: 7 * 60)
        XCTAssertEqual(submit(.addSchedule(rule)), .applied(.tightening))
        XCTAssertEqual(submit(.addSchedule(rule)), .applied(.neutral))
        var smaller = rule
        smaller.end = 6 * 60
        guard case .queued = submit(.addSchedule(smaller)) else { return XCTFail("editing a window can loosen it") }
        guard case .queued = submit(.removeSchedule(id: "night")) else { return XCTFail("removing waits") }
        XCTAssertEqual(policy.limits.schedules, [rule])
    }

    func testLimitValidation() {
        if case .rejectedInvalid = submit(.setDailyLimit(.instagram, minutes: 0)) {} else { XCTFail() }
        if case .rejectedInvalid = submit(.setShortFormBudget(minutes: 601)) {} else { XCTFail() }
        if case .rejectedInvalid = submit(.addSchedule(.init(id: "", target: .shortForm, start: 0, end: 1))) {} else { XCTFail() }
        for i in 0..<LimitsPolicy.maxSchedules {
            _ = submit(.addSchedule(.init(id: "s\(i)", target: .shortForm, start: i, end: i + 1)))
        }
        if case .rejectedInvalid = submit(.addSchedule(.init(id: "extra", target: .shortForm, start: 100, end: 200))) {} else {
            XCTFail("schedule count capped")
        }
    }

    func testLimitsSurviveOldPolicyFiles() throws {
        let old = try JSONDecoder().decode(WallPolicy.self, from: Data(#"{"lockEnabled":true}"#.utf8))
        XCTAssertEqual(old.limits, .off)
    }
}

final class ShortFormModeTests: XCTestCase {
    func engine(_ mode: ShortFormMode, toggles: [String: Bool] = [:], _ p: Platform = .instagram) throws -> RuleEngine {
        try RuleEngine(active: ActiveRecipe(recipe: RecipeLibrary.bundled(p), settings: .init(toggles: toggles), shortForm: mode))
    }

    func decide(_ e: RuleEngine, _ url: String, from: String? = nil) -> NavigationDecision {
        var s = NavigationState()
        return e.decide(url: URL(string: url)!, from: from.flatMap(URL.init(string:)), state: &s)
    }

    func testBudgetAllowedOpensReelsAndShorts() throws {
        XCTAssertEqual(decide(try engine(.budgetAllowed), "https://www.instagram.com/reels/"), .allow)
        XCTAssertEqual(decide(try engine(.budgetAllowed), "https://www.instagram.com/reel/ABC/"), .allow)
        XCTAssertEqual(decide(try engine(.budgetAllowed, .youtube), "https://m.youtube.com/shorts/abc"), .allow)
        XCTAssertNotEqual(decide(try engine(.budgetAllowed), "https://www.instagram.com/explore/"), .allow, "Explore isn't short-form")
    }

    func testForcedBlockedIgnoresToggles() throws {
        let e = try engine(.forcedBlocked, toggles: ["ig.blockReels": false])
        XCTAssertNotEqual(decide(e, "https://www.instagram.com/reels/"), .allow)
        XCTAssertEqual(decide(e, "https://www.instagram.com/reel/A/", from: "https://www.instagram.com/direct/t/1/"), .allow,
                       "blocked means back to the default wall: a DM'd reel still plays once")
        XCTAssertEqual(decide(try engine(.togglesDecide, toggles: ["ig.blockReels": false]), "https://www.instagram.com/reels/"), .allow)
    }

    func testMatcher() throws {
        let ig = ShortFormMatcher(try RecipeLibrary.bundled(.instagram))
        XCTAssertTrue(ig.matches(path: "/reels/"))
        XCTAssertTrue(ig.matches(path: "/reel/ABC/"))
        XCTAssertTrue(ig.matches(path: "/someone/reels/"))
        XCTAssertFalse(ig.matches(path: "/direct/inbox/"))
        XCTAssertFalse(ig.matches(path: "/reelsfan/"))
        let yt = ShortFormMatcher(try RecipeLibrary.bundled(.youtube))
        XCTAssertTrue(yt.matches(path: "/shorts/abc"))
        XCTAssertFalse(yt.matches(path: "/watch"))
    }
}
