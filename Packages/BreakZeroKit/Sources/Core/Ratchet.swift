import Foundation

/// One field-level edit to the `WallPolicy`.
public enum PolicyChange: Codable, Sendable, Equatable {
    case setToggle(Platform, id: String, on: Bool)
    case setLanding(Platform, key: String?)
    case addCustomBlock(Platform, pattern: String)
    case removeCustomBlock(Platform, pattern: String)
    case addCustomHide(Platform, selector: String)
    case removeCustomHide(Platform, selector: String)
    case setPlatformEnabled(Platform, Bool)
    case setShields(ShieldSelection)
    case setPassDuration(minutes: Int)
    case setPassWait(seconds: Int)
    case setPassCap(Int)
    case setCooldown(TimeInterval)
    case setLockEnabled(Bool)
    case setDenyAppRemoval(Bool)
    /// nil clears the Hard Lock.
    case setHardLock(until: Date?)
    case setRecipeUpdates(Bool)
    /// nil removes the limit.
    case setDailyLimit(Platform, minutes: Int?)
    /// 0 turns the shared short-form budget off.
    case setShortFormBudget(minutes: Int)
    case addSchedule(ScheduleRule)
    case removeSchedule(id: String)

    /// Changes with the same key edit the same thing; a newer submission supersedes a pending one.
    public var fieldKey: String {
        switch self {
        case let .setToggle(p, id, _): "toggle/\(p.rawValue)/\(id)"
        case let .setLanding(p, _): "landing/\(p.rawValue)"
        case let .addCustomBlock(p, pattern), let .removeCustomBlock(p, pattern): "customBlock/\(p.rawValue)/\(pattern)"
        case let .addCustomHide(p, s), let .removeCustomHide(p, s): "customHide/\(p.rawValue)/\(s)"
        case let .setPlatformEnabled(p, _): "platform/\(p.rawValue)"
        case .setShields: "shields"
        case .setPassDuration: "pass/duration"
        case .setPassWait: "pass/wait"
        case .setPassCap: "pass/cap"
        case .setCooldown: "cooldown"
        case .setLockEnabled: "lock"
        case .setDenyAppRemoval: "denyAppRemoval"
        case .setHardLock: "hardLock"
        case .setRecipeUpdates: "recipeUpdates"
        case let .setDailyLimit(p, _): "limit/daily/\(p.rawValue)"
        case .setShortFormBudget: "limit/shortForm"
        case let .addSchedule(rule): "schedule/\(rule.id)"
        case let .removeSchedule(id): "schedule/\(id)"
        }
    }
}

public enum ChangeKind: String, Codable, Sendable {
    case tightening
    case loosening
    /// Neither (or a no-op): applies immediately.
    case neutral
}

public struct PendingChange: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var change: PolicyChange
    public var submittedAt: Date
    /// `ElapsedLedger.credited` when submitted.
    public var creditedAtSubmit: TimeInterval
    public var cooldown: TimeInterval
    /// Wall-clock estimate for scheduling the DeviceActivity callback. Not authoritative.
    public var estimatedDue: Date

    public func isDue(credited: TimeInterval) -> Bool {
        credited - creditedAtSubmit >= cooldown
    }
}

/// Everything about the wall's *state* (as opposed to its settings).
public struct LockState: Codable, Sendable, Equatable {
    public var pending: [PendingChange]
    public var ledger: ElapsedLedger
    public var passes: PassLedger
    /// Last time authorization and shields were confirmed in place.
    public var lastVerifiedIntact: Date?
    /// Set when we notice the wall came down (authorization revoked).
    public var wallDownSince: Date?

    public init(pending: [PendingChange] = [], ledger: ElapsedLedger = .init(), passes: PassLedger = .init(),
                lastVerifiedIntact: Date? = nil, wallDownSince: Date? = nil) {
        self.pending = pending
        self.ledger = ledger
        self.passes = passes
        self.lastVerifiedIntact = lastVerifiedIntact
        self.wallDownSince = wallDownSince
    }
}

public enum SubmitResult: Equatable, Sendable {
    case applied(ChangeKind)
    case queued(PendingChange)
    case rejectedHardLock(until: Date)
    case rejectedInvalid(String)
}

/// The ratchet: tightening applies now, loosening waits out the cooldown.
public struct Ratchet: Sendable {
    /// Recipe toggle defaults, needed to know whether a toggle is currently on.
    public var toggleDefaults: [Platform: [String: Bool]]
    /// Toggles of each platform's short-form *route* rules: all on = short-form unreachable
    /// without a budget (allowance 0); any off = unlimited.
    public var shortFormToggles: [Platform: Set<String>]

    public init(toggleDefaults: [Platform: [String: Bool]], shortFormToggles: [Platform: Set<String>] = [:]) {
        self.toggleDefaults = toggleDefaults
        self.shortFormToggles = shortFormToggles
    }

    public init(recipes: [Recipe]) {
        var d: [Platform: [String: Bool]] = [:]
        var sf: [Platform: Set<String>] = [:]
        for r in recipes {
            guard let p = Platform(rawValue: r.platform) else { continue }
            d[p] = Dictionary(uniqueKeysWithValues: r.toggles.map { ($0.id, $0.defaultOn) })
            let toggles = Set(r.routes.filter { $0.shortForm == true }.map(\.toggle))
            if !toggles.isEmpty { sf[p] = toggles }
        }
        self.toggleDefaults = d
        self.shortFormToggles = sf
    }

    func isOn(_ p: Platform, _ id: String, _ policy: WallPolicy) -> Bool {
        policy.settings(for: p).toggles[id] ?? toggleDefaults[p]?[id] ?? true
    }

    public func classify(_ change: PolicyChange, against policy: WallPolicy) -> ChangeKind {
        func cmp<T: Comparable>(_ new: T, _ old: T, looserWhenGreater: Bool) -> ChangeKind {
            if new == old { return .neutral }
            return (new > old) == looserWhenGreater ? .loosening : .tightening
        }
        switch change {
        case let .setToggle(p, id, on):
            let current = isOn(p, id, policy)
            return on == current ? .neutral : (on ? .tightening : .loosening)
        case .setLanding, .setPlatformEnabled, .setRecipeUpdates:
            return .neutral
        case let .addCustomBlock(p, pattern):
            return policy.settings(for: p).customBlocks.contains(pattern) ? .neutral : .tightening
        case let .removeCustomBlock(p, pattern):
            return policy.settings(for: p).customBlocks.contains(pattern) ? .loosening : .neutral
        case let .addCustomHide(p, s):
            return policy.settings(for: p).customHides.contains(s) ? .neutral : .tightening
        case let .removeCustomHide(p, s):
            return policy.settings(for: p).customHides.contains(s) ? .loosening : .neutral
        case let .setShields(sel):
            let old = policy.shields.tokenIDs
            if sel.tokenIDs == old { return sel.data == policy.shields.data ? .neutral : .tightening }
            return sel.tokenIDs.isSuperset(of: old) ? .tightening : .loosening
        case let .setPassDuration(m):
            return cmp(m, policy.pass.durationMinutes, looserWhenGreater: true)
        case let .setPassWait(s):
            return cmp(s, policy.pass.waitSeconds, looserWhenGreater: false)
        case let .setPassCap(n):
            return cmp(n, policy.pass.dailyCap, looserWhenGreater: true)
        case let .setCooldown(c):
            return cmp(c, policy.cooldown, looserWhenGreater: false)
        case let .setLockEnabled(on):
            return on == policy.lockEnabled ? .neutral : (on ? .tightening : .loosening)
        case let .setDenyAppRemoval(on):
            return on == policy.denyAppRemoval ? .neutral : (on ? .tightening : .loosening)
        case let .setDailyLimit(p, minutes):
            // nil = no limit = the loosest.
            let old = policy.limits.dailyMinutes[p] ?? Int.max
            return cmp(minutes ?? Int.max, old, looserWhenGreater: true)
        case let .setShortFormBudget(minutes):
            var after = policy
            after.limits.shortFormMinutes = minutes
            var up = false, down = false
            for p in shortFormToggles.keys {
                let before = shortFormAllowance(p, policy), new = shortFormAllowance(p, after)
                if new > before { up = true } else if new < before { down = true }
            }
            return up ? .loosening : (down ? .tightening : .neutral)
        case let .addSchedule(rule):
            guard let old = policy.limits.schedules.first(where: { $0.id == rule.id }) else { return .tightening }
            return old == rule ? .neutral : .loosening
        case let .removeSchedule(id):
            return policy.limits.schedules.contains { $0.id == id } ? .loosening : .neutral
        case let .setHardLock(until):
            switch (policy.hardLock?.until, until) {
            case (nil, nil): return .neutral
            case (nil, .some): return .tightening
            case (.some, nil): return .loosening
            case let (.some(old), .some(new)): return cmp(new, old, looserWhenGreater: false)
            }
        }
    }

    /// Minutes of short-form a day the policy allows on `p`: the budget if it's on, otherwise
    /// none while every short-form route toggle is on, unlimited if any is off.
    func shortFormAllowance(_ p: Platform, _ policy: WallPolicy) -> Int {
        if policy.limits.shortFormMinutes > 0 { return policy.limits.shortFormMinutes }
        let toggles = shortFormToggles[p] ?? []
        return toggles.allSatisfy { isOn(p, $0, policy) } ? 0 : Int.max
    }

    func validate(_ change: PolicyChange) -> String? {
        switch change {
        case let .setDailyLimit(_, m?) where !(1...1440).contains(m): return "daily limit must be 1–1440 minutes"
        case let .setShortFormBudget(m) where !(0...600).contains(m): return "short-form budget must be 0–600 minutes"
        case let .addSchedule(rule) where !rule.isValid: return "invalid schedule"
        case let .setPassDuration(m) where !(1...60).contains(m): return "pass duration must be 1–60 minutes"
        case let .setPassWait(s) where !(0...600).contains(s): return "pass wait must be 0–600 seconds"
        case let .setPassCap(n) where !(0...20).contains(n): return "pass cap must be 0–20"
        case let .setCooldown(c) where !WallPolicy.cooldownRange.contains(c): return "cooldown must be 1 h – 7 d"
        case let .addCustomBlock(_, p) where (try? PathRegex(p.hasPrefix("^") ? p : "^" + p)) == nil: return "invalid pattern"
        case let .addCustomHide(_, s) where s.isEmpty || s.contains("{") || s.contains("}") || s.contains("<"): return "invalid selector"
        default: return nil
        }
    }

    public func isHardLocked(_ policy: WallPolicy, lock: LockState, now: Date) -> Bool {
        guard let h = policy.hardLock else { return false }
        return now < h.until || lock.ledger.credited < h.creditedEnd
    }

    /// Submit changes at `sample` (recorded into the ledger first).
    public func submit(_ changes: [PolicyChange], policy: inout WallPolicy, lock: inout LockState,
                       at sample: ClockSample) -> [SubmitResult] {
        lock.ledger.record(sample)
        return changes.map { change in
            if let problem = validate(change) { return .rejectedInvalid(problem) }
            if case let .addSchedule(rule) = change, policy.limits.schedules.count >= LimitsPolicy.maxSchedules,
               !policy.limits.schedules.contains(where: { $0.id == rule.id }) {
                return .rejectedInvalid("at most \(LimitsPolicy.maxSchedules) schedules")
            }
            let kind = classify(change, against: policy)
            // A newer edit to the same field replaces whatever was waiting.
            lock.pending.removeAll { $0.change.fieldKey == change.fieldKey }
            if kind != .loosening || !policy.lockEnabled {
                apply(change, to: &policy, lock: lock, now: sample.wall)
                return .applied(kind)
            }
            if isHardLocked(policy, lock: lock, now: sample.wall), let h = policy.hardLock {
                return .rejectedHardLock(until: h.until)
            }
            let p = PendingChange(id: UUID(), change: change, submittedAt: sample.wall,
                                  creditedAtSubmit: lock.ledger.credited, cooldown: policy.cooldown,
                                  estimatedDue: sample.wall.addingTimeInterval(policy.cooldown))
            lock.pending.append(p)
            return .queued(p)
        }
    }

    /// Apply every pending change whose cooldown has elapsed (by trusted time) and that
    /// the Hard Lock doesn't hold back. Call on launch and from every extension callback.
    @discardableResult
    public func applyDue(policy: inout WallPolicy, lock: inout LockState, at sample: ClockSample) -> [PendingChange] {
        lock.ledger.record(sample)
        var applied: [PendingChange] = []
        for p in lock.pending where p.isDue(credited: lock.ledger.credited) {
            let stillLoosening = classify(p.change, against: policy) == .loosening
            if stillLoosening, isHardLocked(policy, lock: lock, now: sample.wall) { continue }
            apply(p.change, to: &policy, lock: lock, now: sample.wall)
            applied.append(p)
        }
        let ids = Set(applied.map(\.id))
        lock.pending.removeAll { ids.contains($0.id) }
        return applied
    }

    public func cancel(_ id: UUID, lock: inout LockState) {
        lock.pending.removeAll { $0.id == id }
    }

    func apply(_ change: PolicyChange, to policy: inout WallPolicy, lock: LockState, now: Date) {
        func edit(_ p: Platform, _ body: (inout PlatformSettings) -> Void) {
            var s = policy.settings(for: p)
            body(&s)
            policy.platformSettings[p] = s
        }
        switch change {
        case let .setToggle(p, id, on): edit(p) { $0.toggles[id] = on }
        case let .setLanding(p, key): edit(p) { $0.landing = key }
        case let .addCustomBlock(p, pattern): edit(p) { if !$0.customBlocks.contains(pattern) { $0.customBlocks.append(pattern) } }
        case let .removeCustomBlock(p, pattern): edit(p) { $0.customBlocks.removeAll { $0 == pattern } }
        case let .addCustomHide(p, s): edit(p) { if !$0.customHides.contains(s) { $0.customHides.append(s) } }
        case let .removeCustomHide(p, s): edit(p) { $0.customHides.removeAll { $0 == s } }
        case let .setPlatformEnabled(p, on):
            policy.enabledPlatforms.removeAll { $0 == p }
            if on { policy.enabledPlatforms.append(p) }
            policy.enabledPlatforms.sort { $0.rawValue < $1.rawValue }
        case let .setShields(sel): policy.shields = sel
        case let .setPassDuration(m): policy.pass.durationMinutes = m
        case let .setPassWait(s): policy.pass.waitSeconds = s
        case let .setPassCap(n): policy.pass.dailyCap = n
        case let .setCooldown(c): policy.cooldown = c
        case let .setLockEnabled(on): policy.lockEnabled = on
        case let .setDenyAppRemoval(on): policy.denyAppRemoval = on
        case let .setHardLock(until):
            policy.hardLock = until.map {
                HardLock(until: $0, creditedEnd: lock.ledger.credited + max(0, $0.timeIntervalSince(now)))
            }
        case let .setRecipeUpdates(on): policy.recipeUpdatesEnabled = on
        case let .setDailyLimit(p, minutes): policy.limits.dailyMinutes[p] = minutes
        case let .setShortFormBudget(minutes): policy.limits.shortFormMinutes = minutes
        case let .addSchedule(rule):
            policy.limits.schedules.removeAll { $0.id == rule.id }
            policy.limits.schedules.append(rule)
        case let .removeSchedule(id): policy.limits.schedules.removeAll { $0.id == id }
        }
    }
}
