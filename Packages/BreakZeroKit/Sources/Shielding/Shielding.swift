import Core
import Foundation

public enum ScreenTimeAuthorization: String, Codable, Sendable {
    case notDetermined
    case denied
    case approved
}

/// Names of the separate `ManagedSettingsStore`s (ARCHITECTURE.md §4).
public enum ShieldStoreName: String, CaseIterable, Sendable {
    /// The wall itself: shields from `WallPolicy.shields`, minus apps on an active pass.
    case base = "wall.base"
    /// Reserved for schedules (sleep mode etc., Phase 5).
    case schedule = "wall.schedule"
    /// Diagnostics spikes only. Never holds the real wall.
    case diagnostics = "wall.diagnostics"
}

/// Applies shields. Real implementation: `ManagedSettingsShieldApplier`.
public protocol ShieldApplying: Sendable {
    /// Shield everything in `selection` except the app tokens whose fingerprints are in `exempt`.
    func applyBase(_ selection: ShieldSelection, exempt: Set<String>) throws
    func setDenyAppRemoval(_ on: Bool)
    /// Remove every restriction we set (legitimate unlock / lock turned off).
    func clearAll()
}

public protocol AuthorizationChecking: Sendable {
    /// Always re-read; never cached (it has been reported stale after revocation).
    func currentStatus() -> ScreenTimeAuthorization
}

/// Schedules DeviceActivity callbacks so extensions run even if the app is killed.
public protocol ActivityScheduling: Sendable {
    /// Ask for a callback when the pass ends (re-shield).
    func schedulePassEnd(passID: UUID, endsAt: Date, now: Date) throws
    /// Ask for a callback when the earliest pending change may be due.
    func schedulePendingCheck(at: Date, now: Date) throws
    func stopAll()
}

/// DeviceActivity activity names. Extensions parse these to know why they were woken.
public enum ActivityName {
    public static let passPrefix = "bz.pass."
    public static let pending = "bz.pending"

    public static func pass(_ id: UUID) -> String { passPrefix + id.uuidString }
}

public struct ReconcileReport: Equatable, Sendable {
    public var authorization: ScreenTimeAuthorization
    public var appliedPending: [PendingChange]
    public var exemptTokens: Set<String>
    public var shieldsApplied: Bool
    public var wallDown: Bool
    public var errors: [String]
}

/// The one routine every process runs (app launch/foreground, every extension callback):
/// record a clock sample, apply due pending changes, re-derive shields from policy, verify
/// authorization, schedule the next callbacks. Idempotent by design — it never trusts what is
/// currently set, only `WallPolicy` + `LockState`.
public struct WallEnforcer: Sendable {
    public var store: SharedStore
    public var clock: any ClockSource
    public var shields: any ShieldApplying
    public var auth: any AuthorizationChecking
    public var scheduler: any ActivityScheduling
    public var ratchet: Ratchet

    public init(store: SharedStore, clock: any ClockSource, shields: any ShieldApplying,
                auth: any AuthorizationChecking, scheduler: any ActivityScheduling, ratchet: Ratchet) {
        self.store = store
        self.clock = clock
        self.shields = shields
        self.auth = auth
        self.scheduler = scheduler
        self.ratchet = ratchet
    }

    @discardableResult
    public func reconcile(source: String) -> ReconcileReport {
        let sample = clock.sample()
        let status = auth.currentStatus()
        var report = ReconcileReport(authorization: status, appliedPending: [], exemptTokens: [],
                                     shieldsApplied: false, wallDown: false, errors: [])
        do {
            try store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) in
                try store.update(AppGroup.File.policy, default: WallPolicy()) { (policy: inout WallPolicy) in
                    report.appliedPending = ratchet.applyDue(policy: &policy, lock: &lock, at: sample)
                    let exempt = Set(lock.passes.active(now: sample.wall, credited: lock.ledger.credited).map(\.appTokenID))
                    report.exemptTokens = exempt

                    if status != .approved {
                        // The wall came down (or never went up). Record when, once; keep the
                        // last-verified timestamp so the revocation screen can show it.
                        if policy.lockEnabled || !policy.shields.tokenIDs.isEmpty {
                            if lock.wallDownSince == nil { lock.wallDownSince = sample.wall }
                            report.wallDown = true
                        }
                        return
                    }
                    lock.wallDownSince = nil
                    if policy.shields.tokenIDs.isEmpty && !policy.lockEnabled {
                        shields.clearAll()
                    } else {
                        do {
                            try shields.applyBase(policy.shields, exempt: exempt)
                            report.shieldsApplied = true
                        } catch {
                            report.errors.append("applyBase: \(error)")
                        }
                        shields.setDenyAppRemoval(policy.lockEnabled && policy.denyAppRemoval)
                    }
                    lock.lastVerifiedIntact = sample.wall

                    if let next = lock.pending.map(\.estimatedDue).min() {
                        do { try scheduler.schedulePendingCheck(at: next, now: sample.wall) } catch {
                            report.errors.append("schedulePendingCheck: \(error)")
                        }
                    }
                }
            }
        } catch {
            report.errors.append("store: \(error)")
        }
        DiagnosticsLog.append(store, source: source,
                              "reconcile auth=\(status.rawValue) applied=\(report.appliedPending.count) exempt=\(report.exemptTokens.count) down=\(report.wallDown) errors=\(report.errors.count)")
        return report
    }

    public enum PassStartError: Error, Equatable {
        case wallDown
        case pass(PassError)
    }

    /// Start a requested pass: log it, unshield that one app, schedule the re-shield.
    public func startPass(_ id: UUID) throws -> PassRecord {
        let sample = clock.sample()
        guard auth.currentStatus() == .approved else { throw PassStartError.wallDown }
        let record: PassRecord = try store.update(AppGroup.File.lock, default: LockState()) { (lock: inout LockState) in
            lock.ledger.record(sample)
            let policy = (try? store.read(WallPolicy.self, AppGroup.File.policy)) ?? WallPolicy()
            do {
                return try lock.passes.start(id, rules: policy.pass, now: sample.wall, credited: lock.ledger.credited)
            } catch let e as PassError {
                throw PassStartError.pass(e)
            }
        }
        if let ends = record.endsAt {
            try scheduler.schedulePassEnd(passID: record.id, endsAt: ends, now: sample.wall)
        }
        reconcile(source: "pass.start")
        return record
    }
}
