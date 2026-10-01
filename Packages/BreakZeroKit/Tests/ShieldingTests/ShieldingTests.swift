import Core
import Foundation
import XCTest
@testable import Shielding

final class FakeClockSource: ClockSource, @unchecked Sendable {
    var current = ClockSample(wall: Date(timeIntervalSince1970: 1_800_000_000), uptime: 1000, bootID: "b1")
    func sample() -> ClockSample { current }
    func advance(_ s: TimeInterval) {
        current.wall += s
        current.uptime += s
    }
}

final class FakeShields: ShieldApplying, @unchecked Sendable {
    var applied: (ShieldSelection, Set<String>)?
    var denyRemoval: Bool?
    var cleared = 0
    func applyBase(_ selection: ShieldSelection, exempt: Set<String>) throws { applied = (selection, exempt) }
    func setDenyAppRemoval(_ on: Bool) { denyRemoval = on }
    func clearAll() { cleared += 1 }
}

final class FakeAuth: AuthorizationChecking, @unchecked Sendable {
    var status: ScreenTimeAuthorization = .approved
    func currentStatus() -> ScreenTimeAuthorization { status }
}

final class FakeScheduler: ActivityScheduling, @unchecked Sendable {
    var passEnds: [UUID: Date] = [:]
    var pendingChecks: [Date] = []
    func schedulePassEnd(passID: UUID, endsAt: Date, now: Date) throws { passEnds[passID] = endsAt }
    func schedulePendingCheck(at: Date, now: Date) throws { pendingChecks.append(at) }
    func stopAll() {}
}

final class WallEnforcerTests: XCTestCase {
    var dir: URL!
    var store: SharedStore!
    var clock: FakeClockSource!
    var shields: FakeShields!
    var auth: FakeAuth!
    var scheduler: FakeScheduler!
    var enforcer: WallEnforcer!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bz-enf-\(UUID().uuidString)")
        store = SharedStore(directory: dir)
        clock = FakeClockSource()
        shields = FakeShields()
        auth = FakeAuth()
        scheduler = FakeScheduler()
        enforcer = WallEnforcer(store: store, clock: clock, shields: shields, auth: auth, scheduler: scheduler,
                                ratchet: Ratchet(recipes: [try RecipeLibrary.bundled(.instagram)]))
        var policy = WallPolicy(lockEnabled: true, denyAppRemoval: true)
        policy.shields = ShieldSelection(data: Data([1]), tokenIDs: ["app:IG", "app:YT"])
        try store.write(policy, AppGroup.File.policy)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReconcileAppliesShieldsAndRecordsVerification() throws {
        let r = enforcer.reconcile(source: "test")
        XCTAssertTrue(r.shieldsApplied)
        XCTAssertEqual(shields.applied?.0.tokenIDs, ["app:IG", "app:YT"])
        XCTAssertEqual(shields.applied?.1, [])
        XCTAssertEqual(shields.denyRemoval, true)
        XCTAssertNotNil(try store.read(LockState.self, AppGroup.File.lock)?.lastVerifiedIntact)
        XCTAssertFalse(DiagnosticsLog.entries(store).isEmpty)
    }

    func testPassExemptsOneAppThenReshieldsOnExpiry() throws {
        let req: PassRecord = try store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) in
            try lock.passes.request(appTokenID: "app:IG", purpose: "story with music", rules: PassRules(), now: clock.current.wall)
        }
        XCTAssertThrowsError(try enforcer.startPass(req.id), "still in the wait period")
        clock.advance(30)
        let started = try enforcer.startPass(req.id)
        XCTAssertEqual(scheduler.passEnds[req.id], started.endsAt)
        XCTAssertEqual(shields.applied?.1, ["app:IG"])

        clock.advance(5 * 60 + 1)
        enforcer.reconcile(source: "DeviceActivityMonitor.intervalDidEnd")
        XCTAssertEqual(shields.applied?.1, [], "pass over: back behind the wall")
    }

    func testRevocationIsRecordedOnceAndNotOverwritten() throws {
        enforcer.reconcile(source: "launch")
        let verified = try XCTUnwrap(store.read(LockState.self, AppGroup.File.lock)?.lastVerifiedIntact)
        auth.status = .denied
        clock.advance(3600)
        let r = enforcer.reconcile(source: "launch")
        XCTAssertTrue(r.wallDown)
        let lock1 = try XCTUnwrap(store.read(LockState.self, AppGroup.File.lock))
        XCTAssertEqual(lock1.lastVerifiedIntact, verified)
        let downSince = try XCTUnwrap(lock1.wallDownSince)
        clock.advance(3600)
        enforcer.reconcile(source: "launch")
        XCTAssertEqual(try store.read(LockState.self, AppGroup.File.lock)?.wallDownSince, downSince)
        XCTAssertThrowsError(try enforcer.startPass(UUID()))
    }

    func testDuePendingChangeAppliedByExtensionCallback() throws {
        let ratchet = enforcer.ratchet
        try store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) in
            try store.update(AppGroup.File.policy, default: WallPolicy()) { (policy: inout WallPolicy) in
                _ = ratchet.submit([.setDenyAppRemoval(false)], policy: &policy, lock: &lock, at: clock.current)
            }
        }
        enforcer.reconcile(source: "launch")
        XCTAssertEqual(scheduler.pendingChecks.count, 1)
        XCTAssertEqual(shields.denyRemoval, true)
        clock.advance(86400 + 1)
        let r = enforcer.reconcile(source: "DeviceActivityMonitor.intervalDidStart")
        XCTAssertEqual(r.appliedPending.count, 1)
        XCTAssertEqual(shields.denyRemoval, false)
    }

    func testNothingToProtectClearsEverything() throws {
        try store.write(WallPolicy(), AppGroup.File.policy)
        enforcer.reconcile(source: "launch")
        XCTAssertEqual(shields.cleared, 1)
        XCTAssertNil(shields.applied)
    }
}
