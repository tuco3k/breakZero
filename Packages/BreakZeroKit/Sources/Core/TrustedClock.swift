import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One reading of the clocks, taken at every check-in (app launch, foreground, extension callback).
public struct ClockSample: Codable, Sendable, Equatable {
    /// Wall clock. The user can change it.
    public var wall: Date
    /// Monotonic seconds since boot, *including* time asleep. The user can't change it,
    /// but it resets on reboot.
    public var uptime: TimeInterval
    /// Changes on every boot.
    public var bootID: String

    public init(wall: Date, uptime: TimeInterval, bootID: String) {
        self.wall = wall
        self.uptime = uptime
        self.bootID = bootID
    }
}

public protocol ClockSource: Sendable {
    func sample() -> ClockSample
}

/// Real clocks. Darwin: CLOCK_MONOTONIC is `mach_continuous_time` (counts sleep), unlike
/// `ProcessInfo.systemUptime` which stops while the device sleeps. Boot ID from
/// `kern.bootsessionuuid`. Linux equivalents exist only so tests and CI can run.
public struct SystemClockSource: ClockSource {
    public init() {}

    public func sample() -> ClockSample {
        ClockSample(wall: Date(), uptime: Self.monotonicSeconds(), bootID: Self.bootID())
    }

    static func monotonicSeconds() -> TimeInterval {
        var ts = timespec()
        #if canImport(Darwin)
        clock_gettime(CLOCK_MONOTONIC, &ts)
        #else
        clock_gettime(CLOCK_BOOTTIME, &ts)
        #endif
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9
    }

    static func bootID() -> String {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
        #else
        let s = (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8)) ?? "unknown"
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }
}

public struct TamperEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case clockJumpedForward
        case clockJumpedBackward
        case rebootGapCapped
    }

    public var kind: Kind
    public var at: Date
    /// Seconds of wall-clock time that were *not* credited.
    public var discrepancy: TimeInterval
}

/// Trusted elapsed time. Cooldowns, Hard Lock and pass durations are measured against
/// `credited`, never against the wall clock alone.
///
/// - Same boot: credit `min(wall delta, uptime delta)`. Moving the clock forward is ignored;
///   moving it back only slows the user down.
/// - Across a reboot: uptime restarts, so the time between our last check-in and the reboot
///   is unknowable. Credit `min(wall delta, new uptime + rebootGapCap)`. A legitimate user can
///   lose up to (gap − cap) of progress; an attacker who sets the clock forward and reboots gains
///   at most `rebootGapCap`. Documented in SECURITY_MODEL.md.
public struct ElapsedLedger: Codable, Sendable, Equatable {
    public static let rebootGapCap: TimeInterval = 3600
    /// NTP corrections and sample jitter below this aren't treated as tampering.
    public static let tolerance: TimeInterval = 120
    static let maxEvents = 20

    public private(set) var credited: TimeInterval = 0
    public private(set) var last: ClockSample?
    public private(set) var tamperEvents: [TamperEvent] = []

    public init() {}

    /// Record a check-in. Returns seconds credited by this sample.
    @discardableResult
    public mutating func record(_ s: ClockSample) -> TimeInterval {
        defer { last = s }
        guard let last else { return 0 }
        let wall = s.wall.timeIntervalSince(last.wall)
        let delta: TimeInterval
        if s.bootID == last.bootID, s.uptime >= last.uptime {
            let up = s.uptime - last.uptime
            delta = max(0, min(up, wall))
            if wall > up + Self.tolerance { note(.clockJumpedForward, s.wall, wall - up) }
            if wall < up - Self.tolerance { note(.clockJumpedBackward, s.wall, up - wall) }
        } else {
            let cap = s.uptime + Self.rebootGapCap
            delta = max(0, min(wall, cap))
            if wall > cap { note(.rebootGapCapped, s.wall, wall - cap) }
            if wall < 0 { note(.clockJumpedBackward, s.wall, -wall) }
        }
        credited += delta
        return delta
    }

    private mutating func note(_ kind: TamperEvent.Kind, _ at: Date, _ d: TimeInterval) {
        tamperEvents.append(.init(kind: kind, at: at, discrepancy: d))
        if tamperEvents.count > Self.maxEvents { tamperEvents.removeFirst(tamperEvents.count - Self.maxEvents) }
    }
}
