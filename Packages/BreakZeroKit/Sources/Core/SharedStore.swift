import Foundation

/// App Group identifiers and file names. Change `appGroupID` together with project.yml.
public enum AppGroup {
    public static let appGroupID = "group.com.tuco3k.breakzero"

    public enum File {
        public static let policy = "wall-policy.json"
        public static let lock = "lock-state.json"
        public static let diagnostics = "diagnostics-log.json"
        public static let recipeCacheDirectory = "recipe-cache"
    }
}

/// Codable JSON documents in a shared directory (the App Group container in production).
/// On Darwin every read-modify-write runs inside one `NSFileCoordinator` block so the app and
/// its extensions never interleave writes or read a torn file. Writes are atomic.
public final class SharedStore: @unchecked Sendable {
    // @unchecked: all mutable access goes through `lock` and file coordination.
    public let directory: URL
    // Recursive: an update of one document may read or update another inside its body.
    private let lock = NSRecursiveLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// The App Group container, or nil if the entitlement is missing (e.g. unsigned builds).
    public static func appGroup(_ id: String = AppGroup.appGroupID) -> SharedStore? {
        #if canImport(Darwin)
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
        return SharedStore(directory: url.appendingPathComponent("breakZero", isDirectory: true))
        #else
        return nil
        #endif
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        try coordinated(name, writing: false) { url in try Self.load(type, url) }
    }

    public func write<T: Encodable>(_ value: T, _ name: String) throws {
        try coordinated(name, writing: true) { url in try Self.save(value, url) }
    }

    /// Read, modify and write one document atomically with respect to other processes.
    @discardableResult
    public func update<T: Codable, R>(_ name: String, default make: @autoclosure () -> T,
                                      _ body: (inout T) throws -> R) throws -> R {
        try coordinated(name, writing: true) { url in
            var value = try Self.load(T.self, url) ?? make()
            let result = try body(&value)
            try Self.save(value, url)
            return result
        }
    }

    static func load<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    static func save<T: Encodable>(_ value: T, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private func coordinated<R>(_ name: String, writing: Bool, _ body: (URL) throws -> R) throws -> R {
        lock.lock()
        defer { lock.unlock() }
        let target = url(name)
        #if canImport(Darwin)
        var coordError: NSError?
        var result: Result<R, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writing {
            coordinator.coordinate(writingItemAt: target, options: .forMerging, error: &coordError) { u in
                result = Result { try body(u) }
            }
        } else {
            coordinator.coordinate(readingItemAt: target, options: [], error: &coordError) { u in
                result = Result { try body(u) }
            }
        }
        if let coordError { throw coordError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
        #else
        return try body(target)
        #endif
    }
}

/// Small shared log the app and extensions append to; shown on the Diagnostics screen.
/// Local only. Never contains page content.
public struct DiagnosticsEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var at: Date
    public var source: String
    public var message: String

    public init(at: Date = Date(), source: String, message: String) {
        self.id = UUID()
        self.at = at
        self.source = source
        self.message = message
    }
}

public enum DiagnosticsLog {
    public static let maxEntries = 500

    public static func append(_ store: SharedStore, source: String, _ message: String, at: Date = Date()) {
        try? store.update(AppGroup.File.diagnostics, default: [DiagnosticsEntry]()) { entries in
            entries.append(.init(at: at, source: source, message: message))
            if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        }
    }

    public static func entries(_ store: SharedStore) -> [DiagnosticsEntry] {
        (try? store.read([DiagnosticsEntry].self, AppGroup.File.diagnostics)) ?? []
    }

    public static func clear(_ store: SharedStore) {
        try? store.write([DiagnosticsEntry](), AppGroup.File.diagnostics)
    }
}
