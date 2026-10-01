// UNVERIFIED: written on Linux, never compiled. Build on a Mac first (see PROGRESS.md).
// Screen Time APIs don't work in the Simulator; behavior must be checked on a device
// (docs/ON_DEVICE_CHECKLIST.md). Never assume a shield works because this compiles.
#if os(iOS) && canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
import Core
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

/// Fingerprints for tokens so Core can diff selections without understanding tokens.
/// Tokens are opaque but Codable; their encoding is stable for a given token on a device.
public enum TokenFingerprint {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static func of<T: Encodable>(_ token: T) -> String {
        ((try? encoder.encode(token)) ?? Data()).base64EncodedString()
    }

    public static func selection(_ s: FamilyActivitySelection) throws -> ShieldSelection {
        var ids = Set<String>()
        for t in s.applicationTokens { ids.insert("app:" + of(t)) }
        for t in s.categoryTokens { ids.insert("cat:" + of(t)) }
        for t in s.webDomainTokens { ids.insert("web:" + of(t)) }
        return ShieldSelection(data: try JSONEncoder().encode(s), tokenIDs: ids)
    }

    public static func decode(_ s: ShieldSelection) -> FamilyActivitySelection? {
        guard !s.data.isEmpty else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: s.data)
    }
}

public struct ManagedSettingsShieldApplier: ShieldApplying {
    public init() {}

    private var base: ManagedSettingsStore { ManagedSettingsStore(named: .init(ShieldStoreName.base.rawValue)) }

    public func applyBase(_ selection: ShieldSelection, exempt: Set<String>) throws {
        let store = base
        guard let s = TokenFingerprint.decode(selection) else {
            store.shield.applications = nil
            store.shield.applicationCategories = nil
            store.shield.webDomains = nil
            return
        }
        // `exempt` holds pass fingerprints ("app:<base64>"). Apps on a pass are removed from the
        // app shield *and* excepted from category shields: ManagedSettings merges stores with
        // "most restrictive wins", so a pass must edit this store, not add a looser one.
        let exemptApps = Set(s.applicationTokens.filter { exempt.contains("app:" + TokenFingerprint.of($0)) })
        let apps = s.applicationTokens.subtracting(exemptApps)
        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = s.categoryTokens.isEmpty
            ? nil : .specific(s.categoryTokens, except: exemptApps)
        // shield.webDomains holds at most 50 tokens (BRIEF §3).
        let webs = Set(s.webDomainTokens.prefix(50))
        store.shield.webDomains = webs.isEmpty ? nil : webs
    }

    public func setDenyAppRemoval(_ on: Bool) {
        base.application.denyAppRemoval = on ? true : nil
    }

    public func clearAll() {
        for name in ShieldStoreName.allCases {
            ManagedSettingsStore(named: .init(name.rawValue)).clearAllSettings()
        }
    }
}

public struct FamilyControlsAuthorization: AuthorizationChecking {
    public init() {}

    public func currentStatus() -> ScreenTimeAuthorization {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approved: .approved
        case .denied: .denied
        default: .notDetermined
        }
    }

    @MainActor
    public static func request() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    }
}

public struct DeviceActivityScheduler: ActivityScheduling {
    /// DeviceActivity reportedly rejects intervals shorter than 15 minutes (verify in S7).
    public static let minimumInterval: TimeInterval = 15 * 60

    public init() {}

    static func components(_ d: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
    }

    /// HACK (documented): to get a callback N < 15 minutes from now, the interval *start* is
    /// backdated so the whole interval is ≥ 15 min while its *end* lands on `end`.
    /// What breaks it: Apple validating that intervalStart is in the future, or ignoring
    /// already-started intervals. How we'd notice: Spike S7 / QA "pass re-lock with app
    /// force-quit" — the re-shield wouldn't fire. Belt and braces: every launch reconciles.
    static func schedule(ending end: Date, now: Date) -> DeviceActivitySchedule {
        let start = min(now, end.addingTimeInterval(-minimumInterval))
        return DeviceActivitySchedule(intervalStart: components(start), intervalEnd: components(end), repeats: false)
    }

    public func schedulePassEnd(passID: UUID, endsAt: Date, now: Date) throws {
        try DeviceActivityCenter().startMonitoring(.init(ActivityName.pass(passID)), during: Self.schedule(ending: endsAt, now: now))
    }

    public func schedulePendingCheck(at: Date, now: Date) throws {
        // intervalDidStart fires at `at`; the interval itself must be ≥ 15 min.
        let start = max(at, now.addingTimeInterval(60))
        let end = start.addingTimeInterval(Self.minimumInterval + 60)
        let schedule = DeviceActivitySchedule(intervalStart: Self.components(start), intervalEnd: Self.components(end), repeats: false)
        let center = DeviceActivityCenter()
        center.stopMonitoring([.init(ActivityName.pending)])
        try center.startMonitoring(.init(ActivityName.pending), during: schedule)
    }

    public func stopAll() {
        DeviceActivityCenter().stopMonitoring()
    }
}

extension WallEnforcer {
    /// Production wiring used by the app and every extension.
    public static func live(store: SharedStore, recipes: [Recipe]) -> WallEnforcer {
        WallEnforcer(store: store, clock: SystemClockSource(), shields: ManagedSettingsShieldApplier(),
                     auth: FamilyControlsAuthorization(), scheduler: DeviceActivityScheduler(),
                     ratchet: Ratchet(recipes: recipes))
    }
}
#endif
