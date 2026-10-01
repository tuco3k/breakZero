import Foundation

/// A native pass: one shielded app unshielded for a few minutes, for a stated purpose.
public struct PassRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Shielding's fingerprint of the app token.
    public var appTokenID: String
    public var purpose: String
    public var requestedAt: Date
    /// When the wait screen may finish.
    public var waitUntil: Date
    public var startedAt: Date?
    public var endsAt: Date?
    /// `ElapsedLedger.credited` at start: the pass also ends once this much trusted time has
    /// passed, so setting the clock back can't stretch it.
    public var creditedAtStart: TimeInterval?
    public var cancelled: Bool

    public var isActive: Bool { startedAt != nil && !cancelled }
}

public enum PassError: Error, Equatable {
    case emptyPurpose
    case capReached(cap: Int)
    case unknownRequest
    case stillWaiting(until: Date)
    case alreadyStarted
}

/// Local-only log of every pass and the daily cap. Never leaves the device.
public struct PassLedger: Codable, Sendable, Equatable {
    public static let maxRecords = 500

    public private(set) var records: [PassRecord] = []

    public init() {}

    /// Passes counted against today's cap: started today (local calendar), plus any whose start
    /// is in the future — that only happens if the clock was moved back, and must not reset the cap.
    public func usedToday(now: Date, calendar: Calendar = .current) -> Int {
        records.filter { r in
            guard let s = r.startedAt else { return false }
            return s > now || calendar.isDate(s, inSameDayAs: now)
        }.count
    }

    public mutating func request(appTokenID: String, purpose: String, rules: PassRules,
                                 now: Date, calendar: Calendar = .current) throws -> PassRecord {
        let purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard purpose.count >= 3 else { throw PassError.emptyPurpose }
        guard usedToday(now: now, calendar: calendar) < rules.dailyCap else { throw PassError.capReached(cap: rules.dailyCap) }
        let r = PassRecord(id: UUID(), appTokenID: appTokenID, purpose: String(purpose.prefix(280)), requestedAt: now,
                           waitUntil: now.addingTimeInterval(TimeInterval(rules.waitSeconds)),
                           startedAt: nil, endsAt: nil, creditedAtStart: nil, cancelled: false)
        records.append(r)
        trim()
        return r
    }

    /// Start a requested pass once its wait is over. The cap is re-checked: two requests made
    /// while under the cap can't both start once it's reached.
    public mutating func start(_ id: UUID, rules: PassRules, now: Date, credited: TimeInterval,
                               calendar: Calendar = .current) throws -> PassRecord {
        guard let i = records.firstIndex(where: { $0.id == id && !$0.cancelled }) else { throw PassError.unknownRequest }
        guard records[i].startedAt == nil else { throw PassError.alreadyStarted }
        guard now >= records[i].waitUntil else { throw PassError.stillWaiting(until: records[i].waitUntil) }
        guard usedToday(now: now, calendar: calendar) < rules.dailyCap else { throw PassError.capReached(cap: rules.dailyCap) }
        records[i].startedAt = now
        records[i].endsAt = now.addingTimeInterval(TimeInterval(rules.durationMinutes * 60))
        records[i].creditedAtStart = credited
        return records[i]
    }

    public mutating func cancel(_ id: UUID) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].cancelled = true }
    }

    /// Passes that should currently keep their app unshielded.
    public func active(now: Date, credited: TimeInterval) -> [PassRecord] {
        records.filter { r in
            guard r.isActive, let s = r.startedAt, let e = r.endsAt, let c = r.creditedAtStart else { return false }
            return s <= now && now < e && credited - c < e.timeIntervalSince(s)
        }
    }

    private mutating func trim() {
        if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
    }
}
