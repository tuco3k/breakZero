import Foundation
import XCTest
@testable import Core

/// Limit modes (ARCHITECTURE.md §4d), the Lock's grace period (§4e) and toast coalescing.
final class WallModesTests: XCTestCase {
    var ratchet: Ratchet!
    var policy: WallPolicy!
    var lock: LockState!
    var clock: FakeClock!

    override func setUpWithError() throws {
        ratchet = Ratchet(recipes: [try RecipeLibrary.bundled(.instagram), try RecipeLibrary.bundled(.youtube)])
        policy = WallPolicy(lockEnabled: true)
        lock = LockState()
        clock = FakeClock()
        lock.ledger.record(clock.sample)
    }

    func submit(_ c: PolicyChange) -> SubmitResult {
        ratchet.submit([c], policy: &policy, lock: &lock, at: clock.sample)[0]
    }

    // MARK: Limit modes

    /// Usage with `seconds` of short-form on `platform`, starting at the fake clock's day.
    func usage(_ entries: [(Platform, Double, Bool)]) -> UsageState {
        var u = UsageState()
        var c = FakeClock()
        u.tick(c.sample, activity: nil, timeZone: TimeZone(identifier: "UTC")!)
        for (p, seconds, short) in entries {
            var left = seconds
            while left > 0 {
                let step = min(left, 20)
                c.advance(step)
                u.tick(c.sample, activity: ScreenActivity(platform: p, shortForm: short), timeZone: TimeZone(identifier: "UTC")!)
                left -= step
            }
        }
        return u
    }

    func eval(_ limits: LimitsPolicy, _ u: UsageState) -> LimitStatus {
        LimitEvaluator.evaluate(limits, usage: u, activePassTokens: [], platforms: [.instagram, .youtube])
    }

    func testPerPlatformShortFormBudgets() {
        let u = usage([(.instagram, 120, true), (.youtube, 30, true)])
        XCTAssertEqual(u.shortFormPlatformSeconds[.instagram], 120)
        let s = eval(LimitsPolicy(shortFormPerPlatform: [.instagram: 2, .youtube: 5]), u)
        XCTAssertEqual(s.shortFormMode(.instagram), .forcedBlocked)
        XCTAssertEqual(s.shortFormReason(.instagram), .shortFormBudget)
        XCTAssertEqual(s.shortFormMode(.youtube), .budgetAllowed)
        XCTAssertEqual(s.shortFormRemaining(.youtube), 270)
        XCTAssertEqual(s.shortFormMode(.instagram), .forcedBlocked)
    }

    func testSharedAndPerPlatformBudgetsBothApply() {
        let u = usage([(.youtube, 240, true)])
        let s = eval(LimitsPolicy(shortFormMinutes: 4, shortFormPerPlatform: [.instagram: 10]), u)
        XCTAssertEqual(s.shortFormMode(.instagram), .forcedBlocked, "the shared 4 minutes are gone, even with 10 of its own left")
        XCTAssertEqual(s.shortFormRemaining(.instagram), 0)
        XCTAssertEqual(s.shortFormMode(.youtube), .forcedBlocked)
    }

    func testOverallDailyCapAcrossApps() {
        let u = usage([(.instagram, 600, false), (.youtube, 600, false)])
        let s = eval(LimitsPolicy(dailyTotalMinutes: 20), u)
        XCTAssertEqual(s.platformBlock[.instagram], .dailyLimit)
        XCTAssertEqual(s.platformBlock[.youtube], .dailyLimit)
        XCTAssertEqual(s.totalRemaining, 0)
        let both = eval(LimitsPolicy(dailyMinutes: [.instagram: 5], dailyTotalMinutes: 60), usage([(.instagram, 120, false)]))
        XCTAssertEqual(both.platformRemaining[.instagram], 180, "the per-app limit is the smaller")
        XCTAssertEqual(both.platformRemaining[.youtube], 3480, "the overall cap applies to YouTube too")
    }

    func testLimitModeCooldowns() {
        XCTAssertEqual(submit(.setDailyTotal(minutes: 60)), .applied(.tightening), "none → a cap")
        XCTAssertEqual(submit(.setDailyTotal(minutes: 30)), .applied(.tightening))
        guard case .queued = submit(.setDailyTotal(minutes: 90)) else { return XCTFail("raising waits") }
        guard case .queued = submit(.setDailyTotal(minutes: nil)) else { return XCTFail("removing waits") }
        guard case .queued = submit(.setPlatformShortFormBudget(.instagram, minutes: 10)) else {
            return XCTFail("Reels go from never to 10 min: widening")
        }
        policy.limits.shortFormPerPlatform[.instagram] = 10
        XCTAssertEqual(submit(.setPlatformShortFormBudget(.instagram, minutes: 3)), .applied(.tightening))
        XCTAssertEqual(submit(.setPlatformShortFormBudget(.instagram, minutes: nil)), .applied(.tightening),
                       "off with no shared budget = Reels blocked again (3 → 0 min): narrowing")
    }

    func testRemovingAPlatformBudgetUnderASharedOneIsWidening() {
        policy.limits.shortFormMinutes = 10
        policy.limits.shortFormPerPlatform[.instagram] = 3
        XCTAssertEqual(ratchet.classify(.setPlatformShortFormBudget(.instagram, minutes: nil), against: policy), .loosening,
                       "3 → 10 (the shared budget)")
        XCTAssertEqual(ratchet.classify(.setShortFormBudget(minutes: 20), against: policy), .loosening, "YouTube 10 → 20")
        XCTAssertEqual(ratchet.classify(.setShortFormBudget(minutes: 5), against: policy), .tightening)
    }

    func testCustomMinutesValidation() {
        XCTAssertEqual(submit(.setDailyTotal(minutes: 0)), .rejectedInvalid("daily limit must be 1–1440 minutes"))
        XCTAssertEqual(submit(.setPlatformShortFormBudget(.youtube, minutes: 0)), .rejectedInvalid("short-form budget must be 1–600 minutes"))
        XCTAssertEqual(submit(.setDailyLimit(.instagram, minutes: 137)), .applied(.tightening), "any minute value")
    }

    func testOldLimitsStillDecode() throws {
        let old = #"{"dailyMinutes":{"instagram":30},"shortFormMinutes":5,"schedules":[]}"#
        let l = try JSONDecoder().decode(LimitsPolicy.self, from: Data(old.utf8))
        XCTAssertNil(l.dailyTotalMinutes)
        XCTAssertTrue(l.shortFormPerPlatform.isEmpty)
    }

    // MARK: Grace period

    func unlocked() {
        policy = WallPolicy(lockEnabled: false)
    }

    func testUndoWithinTheGracePeriod() {
        unlocked()
        XCTAssertEqual(submit(.setLockEnabled(true)), .applied(.tightening))
        XCTAssertEqual(lock.grace?.remaining(at: clock.sample), 600)
        clock.advance(9 * 60)
        XCTAssertEqual(submit(.setLockEnabled(false)), .applied(.loosening), "undo: off at once")
        XCTAssertFalse(policy.lockEnabled)
        XCTAssertNil(lock.grace)
    }

    func testAfterTheGracePeriodNormalRulesApply() {
        unlocked()
        _ = submit(.setLockEnabled(true))
        clock.advance(600)
        guard case .queued = submit(.setLockEnabled(false)) else { return XCTFail("cooldown after grace") }
        XCTAssertTrue(policy.lockEnabled)
    }

    func testOnlyTheLockIsUndoneInstantly() {
        unlocked()
        _ = submit(.setLockEnabled(true))
        guard case .queued = submit(.setCooldown(3600)) else { return XCTFail("other loosenings still wait") }
    }

    func testClockTricksOnlyEndGraceEarly() {
        unlocked()
        _ = submit(.setLockEnabled(true))
        let g = lock.grace!
        var c = clock!
        c.jumpWall(-3600)
        XCTAssertNil(g.remaining(at: c.sample), "clock moved back: over")
        c = clock
        c.jumpWall(600)
        XCTAssertNil(g.remaining(at: c.sample), "clock moved forward: over (earliest wins)")
        c = clock
        c.reboot(after: 10)
        XCTAssertNil(g.remaining(at: c.sample), "reboot: over")
        c = clock
        c.uptime += 600
        XCTAssertNil(g.remaining(at: c.sample), "uptime alone also ends it")
        c = clock
        c.advance(60)
        XCTAssertEqual(g.remaining(at: c.sample), 540)
    }

    func testGraceSettingCanOnlyBeShortened() {
        XCTAssertEqual(submit(.setLockGrace(seconds: 120)), .applied(.tightening))
        guard case .queued = submit(.setLockGrace(seconds: 600)) else { return XCTFail("lengthening waits") }
        XCTAssertEqual(submit(.setLockGrace(seconds: 900)), .rejectedInvalid("grace period must be 0–10 minutes"))
        policy.lockEnabled = false
        policy.lockGraceSeconds = 0
        _ = submit(.setLockEnabled(true))
        XCTAssertNil(lock.grace, "no grace period at all")
    }

    func testHardLockStillHoldsDuringGrace() {
        unlocked()
        _ = submit(.setLockEnabled(true))
        _ = submit(.setHardLock(until: clock.wall.addingTimeInterval(86400)))
        XCTAssertEqual(submit(.setLockEnabled(false)), .rejectedHardLock(until: clock.wall.addingTimeInterval(86400)))
    }

    // MARK: Toasts

    func testToastsMergeInsteadOfStacking() {
        var t = ToastCenter()
        let now = Date(timeIntervalSince1970: 1000)
        let added = { (n: Int) in n == 1 ? "Added 1 person" : "Added \(n) people" }
        for i in 0..<5 { t.post(kind: "added", at: now.addingTimeInterval(Double(i) * 0.3), text: added) }
        XCTAssertEqual(t.current?.text, "Added 5 people")
        XCTAssertEqual(t.current?.count, 5)
        t.post(kind: "violation", at: now.addingTimeInterval(1.5), text: { _ in "Behind the wall" })
        XCTAssertEqual(t.current?.text, "Behind the wall", "a different kind replaces; never two at once")
    }

    func testToastsGoAwayAfterTwoSeconds() {
        var t = ToastCenter()
        let now = Date(timeIntervalSince1970: 1000)
        t.post(kind: "a", at: now, text: { _ in "x" })
        XCTAssertFalse(t.expire(at: now.addingTimeInterval(1.9)))
        XCTAssertTrue(t.expire(at: now.addingTimeInterval(2)))
        XCTAssertNil(t.current)
        t.post(kind: "a", at: now.addingTimeInterval(10), text: { "\($0)" })
        XCTAssertEqual(t.current?.text, "1", "too late to merge: a fresh toast")
    }
}
