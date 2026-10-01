import Foundation

extension Platform: CodingKeyRepresentable {}

/// The apps the user chose to shield. `data` is the opaque, encoded
/// `FamilyActivitySelection` (only the Shielding layer can decode it). `tokenIDs` are stable
/// per-token fingerprints computed by Shielding so Core can tell additions from removals.
public struct ShieldSelection: Codable, Sendable, Equatable {
    public var data: Data
    public var tokenIDs: Set<String>

    public init(data: Data = Data(), tokenIDs: Set<String> = []) {
        self.data = data
        self.tokenIDs = tokenIDs
    }
}

public struct PassRules: Codable, Sendable, Equatable {
    public var durationMinutes: Int
    public var waitSeconds: Int
    public var dailyCap: Int

    public init(durationMinutes: Int = 5, waitSeconds: Int = 30, dailyCap: Int = 2) {
        self.durationMinutes = durationMinutes
        self.waitSeconds = waitSeconds
        self.dailyCap = dailyCap
    }
}

/// Until `until` (wall clock) *and* until the trusted elapsed ledger reaches `creditedEnd`,
/// no loosening is accepted. Both must pass, so moving the clock forward doesn't end it early.
public struct HardLock: Codable, Sendable, Equatable {
    public var until: Date
    public var creditedEnd: TimeInterval

    public init(until: Date, creditedEnd: TimeInterval) {
        self.until = until
        self.creditedEnd = creditedEnd
    }
}

/// Every restriction setting. Stored in the App Group; read by the app and all extensions.
public struct WallPolicy: Codable, Sendable, Equatable {
    public static let cooldownRange: ClosedRange<TimeInterval> = 3600...(7 * 86400)

    public var enabledPlatforms: [Platform]
    public var platformSettings: [Platform: PlatformSettings]
    public var shields: ShieldSelection
    public var pass: PassRules
    /// Delay before a loosening change applies.
    public var cooldown: TimeInterval
    /// The ratchet itself. Off on a fresh install (nothing to protect yet); turning it off later
    /// is a loosening change.
    public var lockEnabled: Bool
    public var denyAppRemoval: Bool
    public var hardLock: HardLock?
    /// Optional daily signed-recipe fetch. Privacy setting, not a restriction: neutral.
    public var recipeUpdatesEnabled: Bool
    /// Which lite tab a shielded app's token maps to (token fingerprint → platform), set when the
    /// user picks apps per platform in onboarding. Lets the shield's button open the right tab.
    public var shieldPlatforms: [String: Platform]
    /// Daily time limits, the shared short-form budget and schedules. All off by default.
    public var limits: LimitsPolicy
    /// After the Lock goes on, it can be undone instantly for this long. Can only be shortened.
    public var lockGraceSeconds: TimeInterval
    public static let defaultLockGrace: TimeInterval = 600

    public init(
        enabledPlatforms: [Platform] = [.instagram, .youtube],
        platformSettings: [Platform: PlatformSettings] = [:],
        shields: ShieldSelection = .init(),
        pass: PassRules = .init(),
        cooldown: TimeInterval = 86400,
        lockEnabled: Bool = false,
        denyAppRemoval: Bool = false,
        hardLock: HardLock? = nil,
        recipeUpdatesEnabled: Bool = false,
        shieldPlatforms: [String: Platform] = [:],
        limits: LimitsPolicy = .off,
        lockGraceSeconds: TimeInterval = WallPolicy.defaultLockGrace
    ) {
        self.enabledPlatforms = enabledPlatforms
        self.platformSettings = platformSettings
        self.shields = shields
        self.pass = pass
        self.cooldown = cooldown
        self.lockEnabled = lockEnabled
        self.denyAppRemoval = denyAppRemoval
        self.hardLock = hardLock
        self.recipeUpdatesEnabled = recipeUpdatesEnabled
        self.shieldPlatforms = shieldPlatforms
        self.limits = limits
        self.lockGraceSeconds = lockGraceSeconds
    }

    // Missing keys take defaults so a policy saved by an older build still loads. A policy that
    // fails to decode would otherwise read as the (unlocked) default: never let that happen
    // silently — callers treat a decode *error* as "keep the wall up" (see AppModel).
    public init(from decoder: Decoder) throws {
        let d = WallPolicy()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledPlatforms = try c.decodeIfPresent([Platform].self, forKey: .enabledPlatforms) ?? d.enabledPlatforms
        platformSettings = try c.decodeIfPresent([Platform: PlatformSettings].self, forKey: .platformSettings) ?? d.platformSettings
        shields = try c.decodeIfPresent(ShieldSelection.self, forKey: .shields) ?? d.shields
        pass = try c.decodeIfPresent(PassRules.self, forKey: .pass) ?? d.pass
        cooldown = try c.decodeIfPresent(TimeInterval.self, forKey: .cooldown) ?? d.cooldown
        lockEnabled = try c.decodeIfPresent(Bool.self, forKey: .lockEnabled) ?? d.lockEnabled
        denyAppRemoval = try c.decodeIfPresent(Bool.self, forKey: .denyAppRemoval) ?? d.denyAppRemoval
        hardLock = try c.decodeIfPresent(HardLock.self, forKey: .hardLock)
        recipeUpdatesEnabled = try c.decodeIfPresent(Bool.self, forKey: .recipeUpdatesEnabled) ?? d.recipeUpdatesEnabled
        shieldPlatforms = try c.decodeIfPresent([String: Platform].self, forKey: .shieldPlatforms) ?? d.shieldPlatforms
        limits = try c.decodeIfPresent(LimitsPolicy.self, forKey: .limits) ?? d.limits
        lockGraceSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .lockGraceSeconds) ?? d.lockGraceSeconds
    }

    public func settings(for platform: Platform) -> PlatformSettings {
        platformSettings[platform] ?? .default
    }
}
