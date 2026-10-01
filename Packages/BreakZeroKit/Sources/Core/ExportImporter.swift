import Foundation

/// Minimal zip reader for Instagram's data export: central directory, stored and deflated entries.
/// No zip64, no encryption (the export uses neither). Every offset is bounds-checked.
public struct ZipReader {
    public struct Entry: Equatable {
        public var name: String
        var method: Int
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
        var encrypted: Bool
    }

    public enum Failure: Error, Equatable {
        case notAZip
        case unsupported
        case corrupt
    }

    let bytes: [UInt8]
    public private(set) var entries: [Entry] = []

    public init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22, u32(0) == 0x0403_4b50 || u32(0) == 0x0605_4b50 else { throw Failure.notAZip }
        // End of central directory: 22 bytes plus a comment of up to 64 KB, at the very end.
        var eocd: Int?
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while i >= lowest {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { throw Failure.notAZip }
        let count = u16(e + 10), size = u32(e + 12), offset = u32(e + 16)
        guard count != 0xFFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else { throw Failure.unsupported }
        guard offset + size <= bytes.count else { throw Failure.corrupt }
        var p = offset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4b50 else { throw Failure.corrupt }
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            guard p + 46 + nameLen <= bytes.count else { throw Failure.corrupt }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries.append(Entry(name: name, method: u16(p + 10), compressedSize: u32(p + 20),
                                 uncompressedSize: u32(p + 24), localHeaderOffset: u32(p + 42),
                                 encrypted: u16(p + 8) & 1 == 1))
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    public func data(_ entry: Entry, maxSize: Int) throws -> Data {
        guard !entry.encrypted else { throw Failure.unsupported }
        guard entry.uncompressedSize <= maxSize else { throw Inflate.Failure.tooLarge }
        let h = entry.localHeaderOffset
        guard h + 30 <= bytes.count, u32(h) == 0x0403_4b50 else { throw Failure.corrupt }
        let start = h + 30 + u16(h + 26) + u16(h + 28)
        guard start + entry.compressedSize <= bytes.count else { throw Failure.corrupt }
        let raw = Array(bytes[start..<(start + entry.compressedSize)])
        switch entry.method {
        case 0: return Data(raw)
        case 8: return Data(try Inflate.inflate(raw, maxOutput: maxSize))
        default: throw Failure.unsupported
        }
    }

    private func u16(_ i: Int) -> Int {
        guard i + 2 <= bytes.count else { return 0 }
        return Int(bytes[i]) | Int(bytes[i + 1]) << 8
    }

    private func u32(_ i: Int) -> Int {
        guard i + 4 <= bytes.count else { return 0 }
        return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
    }
}

/// What an Instagram data export says about the account's connections.
public struct ImportedPeople: Equatable, Sendable {
    public var followers: Set<String> = []
    public var following: Set<String> = []
    /// nil when the export had no close-friends file (keep what we had).
    public var closeFriends: Set<String>?
    /// The account's own username, from `personal_information.json` if present.
    public var owner: String?
    /// Export files that were read (names only, for the summary).
    public var filesRead: [String] = []

    public init() {}

    public var mutuals: Set<String> { followers.intersection(following) }
}

/// Reads Instagram's "Download your information" export (JSON format): the `.zip`, or the JSON
/// files from inside it. Only the connection files are opened; photos and messages are skipped.
/// Tolerant of format drift: usernames come from `string_list_data[].value`, else `title`, else the
/// profile `href`.
public enum ExportImporter {
    public enum Failure: Error, Equatable {
        /// The export was requested as HTML; it has to be JSON.
        case htmlExport
        /// No followers/following files were found.
        case notAnExport
        /// Followers were found but not the following list (rules need it).
        case noFollowingList
        case unreadableArchive
        case tooLarge
    }

    public static let maxArchiveBytes = 300 * 1024 * 1024
    public static let maxFileBytes = 64 * 1024 * 1024

    public static func importFiles(_ files: [(name: String, data: Data)]) throws -> ImportedPeople {
        var result = ImportedPeople()
        var sawHTML = false
        for f in files {
            let lower = f.name.lowercased()
            if lower.hasSuffix(".zip") || f.data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
                try readArchive(f.data, into: &result, sawHTML: &sawHTML)
            } else {
                try readFile(f.name, f.data, into: &result, sawHTML: &sawHTML)
            }
        }
        if result.filesRead.isEmpty { throw sawHTML ? Failure.htmlExport : Failure.notAnExport }
        if result.following.isEmpty { throw Failure.noFollowingList }
        return result
    }

    static func readArchive(_ data: Data, into result: inout ImportedPeople, sawHTML: inout Bool) throws {
        guard data.count <= maxArchiveBytes else { throw Failure.tooLarge }
        let zip: ZipReader
        do { zip = try ZipReader(data) } catch { throw Failure.unreadableArchive }
        for entry in zip.entries {
            let base = (entry.name as NSString).lastPathComponent.lowercased()
            if base.hasSuffix(".html"), kind(of: base.replacingOccurrences(of: ".html", with: ".json")) != nil { sawHTML = true }
            guard kind(of: base) != nil || base == "personal_information.json" else { continue }
            let bytes: Data
            do { bytes = try zip.data(entry, maxSize: maxFileBytes) } catch Inflate.Failure.tooLarge {
                throw Failure.tooLarge
            } catch { throw Failure.unreadableArchive }
            try readFile(entry.name, bytes, into: &result, sawHTML: &sawHTML)
        }
    }

    static func readFile(_ name: String, _ data: Data, into result: inout ImportedPeople, sawHTML: inout Bool) throws {
        guard data.count <= maxFileBytes else { throw Failure.tooLarge }
        let base = (name as NSString).lastPathComponent.lowercased()
        if base.hasSuffix(".html") || data.prefix(64).drop(while: { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }).first == UInt8(ascii: "<") {
            sawHTML = true
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return }
        if base == "personal_information.json" {
            if let u = findUsername(json) { result.owner = u }
            return
        }
        guard let list = kind(of: base) ?? kind(ofTopLevel: json) else { return }
        let names = Set(entries(in: json).compactMap(username))
        switch list {
        case .followers: result.followers.formUnion(names)
        case .following: result.following.formUnion(names)
        case .closeFriends: result.closeFriends = (result.closeFriends ?? []).union(names)
        }
        result.filesRead.append(base)
    }

    /// `followers_1.json`, `followers_2.json`, `following.json`, `close_friends.json`. Other files in
    /// the same folder (pending requests, recently unfollowed, blocked…) are not connections.
    static func kind(of base: String) -> FriendsScanList? {
        guard base.hasSuffix(".json") else { return nil }
        let stem = String(base.dropLast(5))
        if stem == "followers" || (stem.hasPrefix("followers_") && stem.dropFirst(10).allSatisfy(\.isNumber) && stem.count > 10) {
            return .followers
        }
        if stem == "following" { return .following }
        if stem == "close_friends" { return .closeFriends }
        return nil
    }

    static func kind(ofTopLevel json: Any) -> FriendsScanList? {
        guard let d = json as? [String: Any] else { return nil }
        if d["relationships_following"] != nil { return .following }
        if d["relationships_followers"] != nil { return .followers }
        if d["relationships_close_friends"] != nil { return .closeFriends }
        return nil
    }

    /// The list of people: the root array, or the array under the single `relationships_*` key.
    static func entries(in json: Any) -> [[String: Any]] {
        if let a = json as? [Any] { return a.compactMap { $0 as? [String: Any] } }
        guard let d = json as? [String: Any] else { return [] }
        for (k, v) in d where k.hasPrefix("relationships_") {
            if let a = v as? [Any] { return a.compactMap { $0 as? [String: Any] } }
        }
        return []
    }

    static func username(_ item: [String: Any]) -> String? {
        let data = (item["string_list_data"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        for d in data {
            if let v = d["value"] as? String, let u = Friends.normalize(v) { return u }
        }
        if let t = item["title"] as? String, let u = Friends.normalize(t) { return u }
        for d in data {
            if let h = d["href"] as? String, let u = usernameFromHref(h) { return u }
        }
        return nil
    }

    /// `https://www.instagram.com/alice`, `…/_u/alice`, `…/alice/`.
    static func usernameFromHref(_ href: String) -> String? {
        guard let url = URL(string: href), let host = url.host?.lowercased(), host.hasSuffix("instagram.com") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "_u" { return Friends.normalize(parts[1]) }
        if parts.count == 1 { return Friends.normalize(parts[0]) }
        return nil
    }

    /// `personal_information.json`: `…"string_map_data": {"Username": {"value": "me"}}`. Searched
    /// by key anywhere, since the nesting has changed over time.
    static func findUsername(_ json: Any, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        if let d = json as? [String: Any] {
            if let u = d["Username"] as? [String: Any], let v = u["value"] as? String, let n = Friends.normalize(v) { return n }
            for v in d.values { if let n = findUsername(v, depth: depth + 1) { return n } }
        } else if let a = json as? [Any] {
            for v in a { if let n = findUsername(v, depth: depth + 1) { return n } }
        }
        return nil
    }
}
