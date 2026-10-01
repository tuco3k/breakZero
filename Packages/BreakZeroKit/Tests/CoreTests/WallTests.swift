import Foundation
import XCTest
@testable import Core

/// Injected clock for wall tests: advance wall and uptime independently, reboot at will.
struct FakeClock {
    var wall = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: TimeInterval = 1000
    var boot = "boot-1"

    var sample: ClockSample { .init(wall: wall, uptime: uptime, bootID: boot) }

    mutating func advance(_ s: TimeInterval) {
        wall += s
        uptime += s
    }

    mutating func jumpWall(_ s: TimeInterval) { wall += s }

    mutating func reboot(after s: TimeInterval, newUptime: TimeInterval = 30) {
        wall += s
        uptime = newUptime
        boot = boot + "+"
    }
}

final class RatchetTests: XCTestCase {
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

    func testClassification() {
        let p = WallPolicy(lockEnabled: true)
        XCTAssertEqual(ratchet.classify(.setToggle(.instagram, id: "ig.blockReels", on: false), against: p), .loosening)
        XCTAssertEqual(ratchet.classify(.setToggle(.instagram, id: "ig.blockReels", on: true), against: p), .neutral)
        XCTAssertEqual(ratchet.classify(.setToggle(.instagram, id: "ig.hideFeed", on: true), against: p), .tightening)
        XCTAssertEqual(ratchet.classify(.setCooldown(3600), against: p), .loosening, "shorter cooldown loosens")
        XCTAssertEqual(ratchet.classify(.setCooldown(2 * 86400), against: p), .tightening)
        XCTAssertEqual(ratchet.classify(.setPassDuration(minutes: 10), against: p), .loosening)
        XCTAssertEqual(ratchet.classify(.setPassWait(seconds: 10), against: p), .loosening)
        XCTAssertEqual(ratchet.classify(.setPassWait(seconds: 60), against: p), .tightening)
        XCTAssertEqual(ratchet.classify(.setPassCap(3), against: p), .loosening)
        XCTAssertEqual(ratchet.classify(.setPassCap(1), against: p), .tightening)
        XCTAssertEqual(ratchet.classify(.setLockEnabled(false), against: p), .loosening)
        XCTAssertEqual(ratchet.classify(.setLanding(.instagram, key: "following"), against: p), .neutral)
        XCTAssertEqual(ratchet.classify(.addCustomBlock(.instagram, pattern: "/x"), against: p), .tightening)
        XCTAssertEqual(ratchet.classify(.removeCustomBlock(.instagram, pattern: "/x"), against: p), .neutral)

        var shielded = p
        shielded.shields = .init(data: Data([1]), tokenIDs: ["a", "b"])
        XCTAssertEqual(ratchet.classify(.setShields(.init(data: Data([2]), tokenIDs: ["a", "b", "c"])), against: shielded), .tightening)
        XCTAssertEqual(ratchet.classify(.setShields(.init(data: Data([3]), tokenIDs: ["a"])), against: shielded), .loosening)
        XCTAssertEqual(ratchet.classify(.setShields(.init(data: Data([3]), tokenIDs: ["a", "c"])), against: shielded), .loosening,
                       "swapping one app for another is a loosening")
    }

    func testTighteningAppliesImmediately() {
        XCTAssertEqual(submit(.setToggle(.instagram, id: "ig.hideFeed", on: true)), .applied(.tightening))
        XCTAssertEqual(policy.settings(for: .instagram).toggles["ig.hideFeed"], true)
        XCTAssertTrue(lock.pending.isEmpty)
    }

    func testLooseningWaitsForCooldown() {
        guard case .queued = submit(.setToggle(.instagram, id: "ig.blockReels", on: false)) else { return XCTFail() }
        XCTAssertNil(policy.settings(for: .instagram).toggles["ig.blockReels"])

        clock.advance(86400 - 60)
        XCTAssertTrue(ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample).isEmpty)
        clock.advance(61)
        XCTAssertEqual(ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample).count, 1)
        XCTAssertEqual(policy.settings(for: .instagram).toggles["ig.blockReels"], false)
        XCTAssertTrue(lock.pending.isEmpty)
    }

    func testClockJumpForwardDoesNotShortenCooldown() {
        _ = submit(.setLockEnabled(false))
        clock.advance(3600)
        clock.jumpWall(7 * 86400)
        XCTAssertTrue(ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample).isEmpty)
        XCTAssertTrue(policy.lockEnabled)
        XCTAssertTrue(lock.ledger.tamperEvents.contains { $0.kind == .clockJumpedForward })
    }

    func testClockJumpForwardThenRebootGainsAtMostTheCap() {
        _ = submit(.setLockEnabled(false))
        clock.reboot(after: 7 * 86400, newUptime: 60)   // clock forward a week + reboot
        XCTAssertTrue(ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample).isEmpty)
        XCTAssertLessThanOrEqual(lock.ledger.credited, 60 + ElapsedLedger.rebootGapCap + 1)
        XCTAssertTrue(lock.ledger.tamperEvents.contains { $0.kind == .rebootGapCapped })
    }

    func testCooldownCompletesAcrossLegitimateReboots() {
        _ = submit(.setLockEnabled(false))
        // Phone checks in, reboots shortly after, keeps running; repeat.
        for _ in 0..<4 {
            clock.advance(6 * 3600)
            ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
            clock.reboot(after: 60, newUptime: 30)
            ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        }
        clock.advance(600)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertFalse(policy.lockEnabled)
    }

    func testShorteningCooldownIsItselfDelayedByTheOldCooldown() {
        _ = submit(.setCooldown(3600))
        XCTAssertEqual(policy.cooldown, 86400)
        clock.advance(3600 * 2)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(policy.cooldown, 86400)
        clock.advance(86400)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(policy.cooldown, 3600)
    }

    func testRetighteningSupersedesPendingLoosening() {
        _ = submit(.setToggle(.youtube, id: "yt.hideShorts", on: false))
        XCTAssertEqual(lock.pending.count, 1)
        _ = submit(.setToggle(.youtube, id: "yt.hideShorts", on: true))
        XCTAssertTrue(lock.pending.isEmpty)
        clock.advance(2 * 86400)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertNotEqual(policy.settings(for: .youtube).toggles["yt.hideShorts"], false)
    }

    func testCancelPending() {
        guard case let .queued(p) = submit(.setPassCap(5)) else { return XCTFail() }
        ratchet.cancel(p.id, lock: &lock)
        clock.advance(2 * 86400)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(policy.pass.dailyCap, 2)
    }

    func testLockOffAppliesEverythingImmediately() {
        policy.lockEnabled = false
        XCTAssertEqual(submit(.setPassCap(5)), .applied(.loosening))
        XCTAssertEqual(policy.pass.dailyCap, 5)
    }

    func testHardLockRejectsLooseningUntilBothClocksAgree() {
        let until = clock.wall.addingTimeInterval(3 * 86400)
        XCTAssertEqual(submit(.setHardLock(until: until)), .applied(.tightening))
        XCTAssertEqual(submit(.setPassCap(5)), .rejectedHardLock(until: until))
        XCTAssertEqual(submit(.setHardLock(until: nil)), .rejectedHardLock(until: until))
        XCTAssertEqual(submit(.setToggle(.instagram, id: "ig.hideFeed", on: true)), .applied(.tightening), "tightening still works")

        clock.jumpWall(4 * 86400)
        XCTAssertEqual(submit(.setPassCap(5)), .rejectedHardLock(until: until), "clock jump doesn't end Hard Lock")

        clock.advance(3 * 86400)
        guard case .queued = submit(.setPassCap(5)) else { return XCTFail("after Hard Lock, normal cooldown applies") }
    }

    func testHardLockHoldsBackPendingLooseningsQueuedBeforeIt() {
        _ = submit(.setPassCap(5))
        _ = submit(.setHardLock(until: clock.wall.addingTimeInterval(5 * 86400)))
        clock.advance(2 * 86400)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(policy.pass.dailyCap, 2)
        clock.advance(4 * 86400)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(policy.pass.dailyCap, 5)
    }

    func testInvalidValuesRejected() {
        XCTAssertEqual(submit(.setCooldown(60)), .rejectedInvalid("cooldown must be 1 h – 7 d"))
        if case .rejectedInvalid = submit(.addCustomBlock(.instagram, pattern: "(")) {} else { XCTFail() }
        if case .rejectedInvalid = submit(.addCustomHide(.instagram, selector: "a{}")) {} else { XCTFail() }
    }

    func testStateRoundTripsThroughJSON() throws {
        _ = submit(.setPassCap(5))
        _ = submit(.setShields(.init(data: Data([9]), tokenIDs: ["x"])))
        let e = JSONEncoder()
        let d = JSONDecoder()
        XCTAssertEqual(try d.decode(WallPolicy.self, from: e.encode(policy)), policy)
        XCTAssertEqual(try d.decode(LockState.self, from: e.encode(lock)), lock)
    }
}

final class ElapsedLedgerTests: XCTestCase {
    func testSameBootCreditsMinimum() {
        var c = FakeClock()
        var l = ElapsedLedger()
        l.record(c.sample)
        c.advance(100)
        XCTAssertEqual(l.record(c.sample), 100)
        c.jumpWall(-500)
        c.advance(100)
        XCTAssertEqual(l.record(c.sample), 0, "clock set back: nothing credited")
        XCTAssertEqual(l.credited, 100)
        XCTAssertTrue(l.tamperEvents.contains { $0.kind == .clockJumpedBackward })
    }

    func testSmallDriftIsNotTamper() {
        var c = FakeClock()
        var l = ElapsedLedger()
        l.record(c.sample)
        c.advance(1000)
        c.jumpWall(30)
        l.record(c.sample)
        XCTAssertTrue(l.tamperEvents.isEmpty)
        XCTAssertEqual(l.credited, 1000)
    }

    func testUptimeGoingBackwardsMeansReboot() {
        var c = FakeClock()
        var l = ElapsedLedger()
        l.record(c.sample)
        c.wall += 100
        c.uptime = 10   // same boot id reported, but uptime went back: treat as reboot
        XCTAssertEqual(l.record(c.sample), 100)
    }
}

final class PassLedgerTests: XCTestCase {
    let rules = PassRules()
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC

    func testWaitThenStartThenExpire() throws {
        var l = PassLedger()
        let r = try l.request(appTokenID: "ig", purpose: "post a story with music", rules: rules, now: t0, calendar: cal)
        XCTAssertThrowsError(try l.start(r.id, rules: rules, now: t0.addingTimeInterval(10), credited: 10, calendar: cal))
        let s = try l.start(r.id, rules: rules, now: t0.addingTimeInterval(30), credited: 30, calendar: cal)
        XCTAssertEqual(s.endsAt, t0.addingTimeInterval(30 + 300))
        XCTAssertEqual(l.active(now: t0.addingTimeInterval(100), credited: 100).count, 1)
        XCTAssertEqual(l.active(now: t0.addingTimeInterval(331), credited: 331).count, 0)
    }

    func testClockSetBackDoesNotStretchPass() throws {
        var l = PassLedger()
        let r = try l.request(appTokenID: "ig", purpose: "close friends", rules: rules, now: t0, calendar: cal)
        _ = try l.start(r.id, rules: rules, now: t0.addingTimeInterval(30), credited: 30, calendar: cal)
        // 10 trusted minutes later, but the clock says only 1 minute passed.
        XCTAssertEqual(l.active(now: t0.addingTimeInterval(90), credited: 30 + 600).count, 0)
    }

    func testDailyCap() throws {
        var l = PassLedger()
        for i in 0..<2 {
            let r = try l.request(appTokenID: "ig", purpose: "purpose \(i)", rules: rules, now: t0, calendar: cal)
            _ = try l.start(r.id, rules: rules, now: t0.addingTimeInterval(30), credited: 30, calendar: cal)
        }
        XCTAssertThrowsError(try l.request(appTokenID: "ig", purpose: "third", rules: rules, now: t0, calendar: cal)) {
            XCTAssertEqual($0 as? PassError, .capReached(cap: 2))
        }
        // Next day: allowed again.
        XCTAssertNoThrow(try l.request(appTokenID: "ig", purpose: "next day", rules: rules, now: t0.addingTimeInterval(86400), calendar: cal))
    }

    func testCapSurvivesClockSetBack() throws {
        var l = PassLedger()
        for i in 0..<2 {
            let r = try l.request(appTokenID: "ig", purpose: "purpose \(i)", rules: rules, now: t0, calendar: cal)
            _ = try l.start(r.id, rules: rules, now: t0.addingTimeInterval(30), credited: 30, calendar: cal)
        }
        XCTAssertThrowsError(try l.request(appTokenID: "ig", purpose: "yesterday?", rules: rules, now: t0.addingTimeInterval(-86400), calendar: cal))
    }

    func testCapRecheckedAtStart() throws {
        var l = PassLedger()
        let rules1 = PassRules(dailyCap: 1)
        let a = try l.request(appTokenID: "ig", purpose: "first", rules: rules1, now: t0, calendar: cal)
        let b = try l.request(appTokenID: "yt", purpose: "second", rules: rules1, now: t0, calendar: cal)
        _ = try l.start(a.id, rules: rules1, now: t0.addingTimeInterval(30), credited: 30, calendar: cal)
        XCTAssertThrowsError(try l.start(b.id, rules: rules1, now: t0.addingTimeInterval(30), credited: 30, calendar: cal))
    }

    func testPurposeRequired() {
        var l = PassLedger()
        XCTAssertThrowsError(try l.request(appTokenID: "ig", purpose: "  ", rules: rules, now: t0, calendar: cal))
    }
}
