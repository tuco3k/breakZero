import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Login-free YouTube (BRIEF §6 S2 fallback): channels imported from a Google Takeout
/// `subscriptions.csv`, latest uploads read from each channel's public RSS feed. No account, no
/// cookies. Signed-in web YouTube stays available; this is an extra list, not a replacement.
public struct YouTubeChannel: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// "UC" + 22 characters.
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public static func isValidID(_ s: String) -> Bool {
        s.count == 24 && s.hasPrefix("UC") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The only feed URL `NetworkPolicy` allows for `.youtubeFeed`.
    public var feedURL: URL? {
        guard Self.isValidID(id) else { return nil }
        return URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)")
    }
}

public struct FeedVideo: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// The video id (`yt:videoId`).
    public var id: String
    public var channelID: String
    public var channelTitle: String
    public var title: String
    public var published: Date
    /// The feed links it as /shorts/… rather than /watch.
    public var isShort: Bool

    public init(id: String, channelID: String, channelTitle: String, title: String, published: Date, isShort: Bool) {
        self.id = id
        self.channelID = channelID
        self.channelTitle = channelTitle
        self.title = title
        self.published = published
        self.isShort = isShort
    }

    /// Path to open in the YouTube lite view.
    public var watchPath: String { "/watch?v=\(id)" }
}

public enum TakeoutCSV {
    /// Parse Takeout's `subscriptions.csv`. Header names are localized, so columns are found by
    /// content: the channel id field ("UC" + 22), a URL field (skipped), and the title.
    public static func parseSubscriptions(_ text: String) -> [YouTubeChannel] {
        var seen = Set<String>()
        var out: [YouTubeChannel] = []
        for row in rows(text) {
            guard let id = row.first(where: { YouTubeChannel.isValidID($0.trimmingCharacters(in: .whitespaces)) })?
                .trimmingCharacters(in: .whitespaces) else { continue }
            let title = row.first { f in
                let t = f.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && t != id && !t.lowercased().hasPrefix("http")
            }?.trimmingCharacters(in: .whitespaces) ?? id
            if seen.insert(id).inserted { out.append(.init(id: id, title: title)) }
        }
        return out
    }

    /// Minimal RFC 4180 reader: quoted fields, doubled quotes, commas and newlines inside quotes,
    /// CRLF, and a UTF-8 BOM.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

/// Parses a channel's Atom feed (`/feeds/videos.xml?channel_id=…`).
public enum YouTubeFeedParser {
    public struct ParseError: Error {}

    public static func parse(_ data: Data) throws -> [FeedVideo] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        let ok = parser.parse()
        // Don't trust `parse()` alone: on Linux it is libxml2 underneath, and older libxml2
        // (e.g. Ubuntu 22.04 in the swift:6.0 CI image) reports a truncated document as success.
        // A real feed is a well-formed <feed> whose every element closed, with no error reported.
        guard ok, !delegate.failed, delegate.root == "feed", delegate.depth == 0 else { throw ParseError() }
        return delegate.videos
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var videos: [FeedVideo] = []
        var depth = 0
        var root: String?
        var failed = false
        private var inEntry = false
        private var inAuthor = false
        private var text = ""
        private var feedChannelID = ""
        private var feedTitle = ""
        private var entry: [String: String] = [:]
        private var isShort = false

        // Per parse, not static: formatters aren't Sendable.
        private let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if depth == 0 { root = root == nil ? name : "<multiple roots>" }
            depth += 1
            text = ""
            switch name {
            case "entry":
                inEntry = true
                entry = [:]
                isShort = false
            case "author":
                inAuthor = true
            case "link" where inEntry:
                if attributes["rel"] == "alternate", let href = attributes["href"], href.contains("/shorts/") { isShort = true }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }

        func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) { failed = true }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            depth -= 1
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inEntry {
                switch name {
                case "yt:videoId", "videoId": entry["videoId"] = value
                case "yt:channelId", "channelId": entry["channelId"] = value
                case "title": entry["title"] = value
                case "published": entry["published"] = value
                case "name" where inAuthor: entry["author"] = value
                case "author": inAuthor = false
                case "entry":
                    inEntry = false
                    if let id = entry["videoId"], !id.isEmpty, let p = entry["published"], let date = iso.date(from: p) {
                        videos.append(FeedVideo(id: id, channelID: entry["channelId"] ?? feedChannelID,
                                                channelTitle: entry["author"] ?? feedTitle, title: entry["title"] ?? "",
                                                published: date, isShort: isShort))
                    }
                default: break
                }
            } else {
                switch name {
                case "yt:channelId", "channelId": feedChannelID = value
                case "title": if feedTitle.isEmpty { feedTitle = value }
                case "author": inAuthor = false
                default: break
                }
            }
            text = ""
        }
    }
}

/// Persisted list (SharedStore file `youtube-subscriptions.json`).
public struct SubscriptionsState: Codable, Sendable, Equatable {
    public static let file = "youtube-subscriptions.json"
    public static let maxChannels = 200
    public static let maxVideos = 500
    public static let minRefreshInterval: TimeInterval = 30 * 60

    public var channels: [YouTubeChannel]
    public var videos: [FeedVideo]
    public var lastRefresh: Date?
    /// Channel ids whose last fetch failed (shown so the user knows the list is partial).
    public var failedChannels: [String]

    public init(channels: [YouTubeChannel] = [], videos: [FeedVideo] = [], lastRefresh: Date? = nil, failedChannels: [String] = []) {
        self.channels = channels
        self.videos = videos
        self.lastRefresh = lastRefresh
        self.failedChannels = failedChannels
    }

    /// Replace the channel list from an import (capped). Videos of removed channels go away.
    public mutating func importChannels(_ new: [YouTubeChannel]) {
        channels = Array(new.prefix(Self.maxChannels))
        let ids = Set(channels.map(\.id))
        videos.removeAll { !ids.contains($0.channelID) }
        lastRefresh = nil
    }

    public func needsRefresh(now: Date) -> Bool {
        guard let last = lastRefresh else { return true }
        return now.timeIntervalSince(last) >= Self.minRefreshInterval || now < last
    }

    /// Videos to show: newest first, de-duplicated, Shorts left out when Shorts are hidden.
    public func visibleVideos(includeShorts: Bool) -> [FeedVideo] {
        videos.filter { includeShorts || !$0.isShort }
    }

    /// Merge freshly fetched videos: newest first, one entry per video id, capped.
    public mutating func merge(_ fetched: [FeedVideo]) {
        var byID: [String: FeedVideo] = [:]
        for v in videos + fetched { byID[v.id] = v }
        videos = byID.values.sorted { $0.published != $1.published ? $0.published > $1.published : $0.id < $1.id }
        if videos.count > Self.maxVideos { videos.removeLast(videos.count - Self.maxVideos) }
    }
}

/// Fetches every channel's feed (at most `concurrency` at a time) through an injected fetcher, so
/// the network path is `NetworkPolicy` in the app and a fake in tests.
public enum SubscriptionsRefresher {
    public static func refresh(_ state: SubscriptionsState, now: Date, force: Bool = false, concurrency: Int = 4,
                               fetch: @escaping @Sendable (YouTubeChannel) async throws -> Data) async -> SubscriptionsState {
        guard force || state.needsRefresh(now: now) else { return state }
        var next = state
        var fetched: [FeedVideo] = []
        var failed: [String] = []
        let channels = state.channels
        var index = 0
        while index < channels.count {
            let batch = channels[index..<min(index + max(1, concurrency), channels.count)]
            index += batch.count
            await withTaskGroup(of: (String, [FeedVideo]?).self) { group in
                for ch in batch {
                    group.addTask {
                        guard let data = try? await fetch(ch), let videos = try? YouTubeFeedParser.parse(data) else {
                            return (ch.id, nil)
                        }
                        return (ch.id, videos)
                    }
                }
                for await (id, videos) in group {
                    if let videos { fetched += videos } else { failed.append(id) }
                }
            }
        }
        next.merge(fetched)
        next.failedChannels = failed.sorted()
        next.lastRefresh = now
        return next
    }
}
