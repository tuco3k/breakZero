import Foundation

/// The app's one toast (QUESTIONS #56): never stacked, never blocking. A toast of the same kind
/// within `mergeWindow` merges into the one on screen ("Added 5 people"); each toast disappears
/// `displayFor` after its last update. Pure, so it's tested with plain dates.
public struct ToastCenter: Sendable, Equatable {
    public static let mergeWindow: TimeInterval = 2
    public static let displayFor: TimeInterval = 2

    public struct Toast: Sendable, Equatable, Identifiable {
        public var id: UUID
        /// Same kind = mergeable ("added", "violation.instagram"…).
        public var kind: String
        public var count: Int
        public var text: String
        public var updatedAt: Date
    }

    public private(set) var current: Toast?

    public init() {}

    /// Show `text(count)`. Merges with the toast on screen when it's the same kind and recent.
    public mutating func post(kind: String, at now: Date, text: (Int) -> String) {
        if var t = current, t.kind == kind, now.timeIntervalSince(t.updatedAt) < Self.mergeWindow {
            t.count += 1
            t.text = text(t.count)
            t.updatedAt = now
            current = t
        } else {
            current = Toast(id: UUID(), kind: kind, count: 1, text: text(1), updatedAt: now)
        }
    }

    /// Drop the toast once it has been on screen long enough. Returns true if it went away.
    @discardableResult
    public mutating func expire(at now: Date) -> Bool {
        guard let t = current, now.timeIntervalSince(t.updatedAt) >= Self.displayFor else { return false }
        current = nil
        return true
    }
}
