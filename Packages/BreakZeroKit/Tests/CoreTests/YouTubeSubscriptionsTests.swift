import Foundation
import XCTest
@testable import Core

final class TakeoutCSVTests: XCTestCase {
    func testEnglishTakeoutFile() {
        let csv = """
        Channel Id,Channel Url,Channel Title
        UCaaaaaaaaaaaaaaaaaaaaaa,http://www.youtube.com/channel/UCaaaaaaaaaaaaaaaaaaaaaa,Alpha
        UCbbbbbbbbbbbbbbbbbbbbbb,http://www.youtube.com/channel/UCbbbbbbbbbbbbbbbbbbbbbb,"Beta, with comma"

        """
        XCTAssertEqual(TakeoutCSV.parseSubscriptions(csv), [
            .init(id: "UCaaaaaaaaaaaaaaaaaaaaaa", title: "Alpha"),
            .init(id: "UCbbbbbbbbbbbbbbbbbbbbbb", title: "Beta, with comma"),
        ])
    }

    func testLocalizedHeaderBOMCRLFQuotesAndDuplicates() {
        let csv = "\u{FEFF}ID del canal,URL del canal,Título del canal\r\n"
            + "UCcccccccccccccccccccccc,https://www.youtube.com/channel/UCcccccccccccccccccccccc,\"Caf\u{E9} \"\"Quoted\"\"\"\r\n"
            + "UCcccccccccccccccccccccc,https://www.youtube.com/channel/UCcccccccccccccccccccccc,Duplicate\r\n"
            + "not a channel,https://example.com,Nope\r\n"
            + "UCdddddddddddddddddddddd,https://www.youtube.com/channel/UCdddddddddddddddddddddd,\"Multi\nline\"\r\n"
        let channels = TakeoutCSV.parseSubscriptions(csv)
        XCTAssertEqual(channels.map(\.id), ["UCcccccccccccccccccccccc", "UCdddddddddddddddddddddd"])
        XCTAssertEqual(channels[0].title, "Caf\u{E9} \"Quoted\"")
        XCTAssertEqual(channels[1].title, "Multi\nline")
    }

    func testColumnOrderDoesNotMatter() {
        let csv = "Title,Id\nGamma,UCeeeeeeeeeeeeeeeeeeeeee\n"
        XCTAssertEqual(TakeoutCSV.parseSubscriptions(csv), [.init(id: "UCeeeeeeeeeeeeeeeeeeeeee", title: "Gamma")])
    }

    func testChannelIDValidation() {
        XCTAssertTrue(YouTubeChannel.isValidID("UC_x-yz0123456789abcdefg"))
        XCTAssertFalse(YouTubeChannel.isValidID("UCshort"))
        XCTAssertFalse(YouTubeChannel.isValidID("XXaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertFalse(YouTubeChannel.isValidID("UCaaaaaaaaaaaaaaaaaaaa&x"))
        XCTAssertEqual(YouTubeChannel(id: "UCaaaaaaaaaaaaaaaaaaaaaa", title: "A").feedURL?.absoluteString,
                       "https://www.youtube.com/feeds/videos.xml?channel_id=UCaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertNil(YouTubeChannel(id: "UCaaaa", title: "A").feedURL)
    }
}

final class YouTubeFeedParserTests: XCTestCase {
    static let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
     <link rel="self" href="http://www.youtube.com/feeds/videos.xml?channel_id=UCaaaaaaaaaaaaaaaaaaaaaa"/>
     <id>yt:channel:aaaaaaaaaaaaaaaaaaaaaa</id>
     <yt:channelId>UCaaaaaaaaaaaaaaaaaaaaaa</yt:channelId>
     <title>Alpha Channel</title>
     <author><name>Alpha Channel</name><uri>https://www.youtube.com/channel/UCaaaaaaaaaaaaaaaaaaaaaa</uri></author>
     <published>2015-01-01T00:00:00+00:00</published>
     <entry>
      <id>yt:video:VID00000001</id>
      <yt:videoId>VID00000001</yt:videoId>
      <yt:channelId>UCaaaaaaaaaaaaaaaaaaaaaa</yt:channelId>
      <title>A long video &amp; more</title>
      <link rel="alternate" href="https://www.youtube.com/watch?v=VID00000001"/>
      <author><name>Alpha Channel</name></author>
      <published>2026-09-30T12:00:00+00:00</published>
      <updated>2026-09-30T13:00:00+00:00</updated>
      <media:group><media:title>A long video &amp; more</media:title></media:group>
     </entry>
     <entry>
      <id>yt:video:SHORT000001</id>
      <yt:videoId>SHORT000001</yt:videoId>
      <yt:channelId>UCaaaaaaaaaaaaaaaaaaaaaa</yt:channelId>
      <title>A short</title>
      <link rel="alternate" href="https://www.youtube.com/shorts/SHORT000001"/>
      <author><name>Alpha Channel</name></author>
      <published>2026-09-29T08:30:00+00:00</published>
     </entry>
    </feed>
    """

    func testParsesEntriesAndFlagsShorts() throws {
        let videos = try YouTubeFeedParser.parse(Data(Self.feed.utf8))
        XCTAssertEqual(videos.count, 2)
        XCTAssertEqual(videos[0].id, "VID00000001")
        XCTAssertEqual(videos[0].title, "A long video & more")
        XCTAssertEqual(videos[0].channelTitle, "Alpha Channel")
        XCTAssertEqual(videos[0].channelID, "UCaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(videos[0].published, ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))
        XCTAssertFalse(videos[0].isShort)
        XCTAssertTrue(videos[1].isShort)
        XCTAssertEqual(videos[0].watchPath, "/watch?v=VID00000001")
    }

    /// Must behave the same on every libxml2 (Linux CI images differ) and on Apple's parser.
    func testMalformedOrWrongDocumentsThrow() {
        for bad in ["<feed><entry>", "<feed>", "<feed><entry></feed>", "", "not xml at all",
                    "<html><body>Sign in</body></html>", "<feed></feed><feed></feed>"] {
            XCTAssertThrowsError(try YouTubeFeedParser.parse(Data(bad.utf8)), "should reject: \(bad)")
        }
    }

    func testEmptyFeedIsValid() throws {
        XCTAssertEqual(try YouTubeFeedParser.parse(Data("<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><title>x</title></feed>".utf8)), [])
    }
}

final class SubscriptionsStateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func video(_ id: String, _ ch: String, _ offset: TimeInterval, short: Bool = false) -> FeedVideo {
        FeedVideo(id: id, channelID: ch, channelTitle: ch, title: id, published: t0.addingTimeInterval(offset), isShort: short)
    }

    func testMergeNewestFirstDedupedCapped() {
        var s = SubscriptionsState()
        s.merge([video("a", "c1", 10), video("b", "c1", 30)])
        s.merge([video("a", "c1", 10), video("c", "c2", 20)])
        XCTAssertEqual(s.videos.map(\.id), ["b", "c", "a"])
        s.merge((0..<600).map { video("v\($0)", "c3", TimeInterval(-100 - $0)) })
        XCTAssertEqual(s.videos.count, SubscriptionsState.maxVideos)
        XCTAssertEqual(s.videos.first?.id, "b", "newest stays")
    }

    func testShortsHiddenUnlessAllowed() {
        var s = SubscriptionsState()
        s.merge([video("a", "c1", 10), video("s", "c1", 20, short: true)])
        XCTAssertEqual(s.visibleVideos(includeShorts: false).map(\.id), ["a"])
        XCTAssertEqual(s.visibleVideos(includeShorts: true).map(\.id), ["s", "a"])
    }

    func testImportCapsAndDropsOrphans() {
        var s = SubscriptionsState(channels: [.init(id: "c1", title: "1")], videos: [video("a", "c1", 0)], lastRefresh: t0)
        s.importChannels((0..<250).map { YouTubeChannel(id: "x\($0)", title: "\($0)") })
        XCTAssertEqual(s.channels.count, SubscriptionsState.maxChannels)
        XCTAssertTrue(s.videos.isEmpty)
        XCTAssertNil(s.lastRefresh)
    }

    func testRefreshRateLimitAndClockBack() {
        let s = SubscriptionsState(lastRefresh: t0)
        XCTAssertFalse(s.needsRefresh(now: t0.addingTimeInterval(60)))
        XCTAssertTrue(s.needsRefresh(now: t0.addingTimeInterval(31 * 60)))
        XCTAssertTrue(s.needsRefresh(now: t0.addingTimeInterval(-60)), "clock moved back: refresh rather than stall")
    }

    func testRefresherUsesFetcherAndRecordsFailures() async throws {
        let good = YouTubeChannel(id: "UCaaaaaaaaaaaaaaaaaaaaaa", title: "Alpha")
        let bad = YouTubeChannel(id: "UCbbbbbbbbbbbbbbbbbbbbbb", title: "Beta")
        let state = SubscriptionsState(channels: [good, bad])
        let feed = Data(YouTubeFeedParserTests.feed.utf8)
        let next = await SubscriptionsRefresher.refresh(state, now: t0, concurrency: 2) { ch in
            if ch.id == good.id { return feed }
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(next.videos.map(\.id), ["VID00000001", "SHORT000001"])
        XCTAssertEqual(next.failedChannels, [bad.id])
        XCTAssertEqual(next.lastRefresh, t0)

        // Within 30 minutes nothing is fetched again.
        let again = await SubscriptionsRefresher.refresh(next, now: t0.addingTimeInterval(60)) { _ in
            XCTFail("should not fetch")
            return Data()
        }
        XCTAssertEqual(again, next)
    }
}

final class YouTubeFeedNetworkPolicyTests: XCTestCase {
    func testOnlyExactFeedURLsWhileYouTubeEnabled() throws {
        let yt = try RecipeLibrary.bundled(.youtube)
        let on = NetworkPolicy(recipes: [yt], recipeUpdatesEnabled: false)
        let ok = "https://www.youtube.com/feeds/videos.xml?channel_id=UCaaaaaaaaaaaaaaaaaaaaaa"
        XCTAssertTrue(on.allows(URL(string: ok)!, for: .youtubeFeed))
        for bad in [
            "http://www.youtube.com/feeds/videos.xml?channel_id=UCaaaaaaaaaaaaaaaaaaaaaa",
            "https://m.youtube.com/feeds/videos.xml?channel_id=UCaaaaaaaaaaaaaaaaaaaaaa",
            "https://www.youtube.com/feeds/videos.xml?playlist_id=PLx",
            "https://www.youtube.com/feeds/videos.xml?channel_id=UCaaaaaaaaaaaaaaaaaaaaaa&x=1",
            "https://www.youtube.com/feeds/videos.xml?channel_id=UCshort",
            "https://www.youtube.com/watch?v=abc",
            "https://www.youtube.com:8443/feeds/videos.xml?channel_id=UCaaaaaaaaaaaaaaaaaaaaaa",
            "https://www.youtube.com/feeds/videos.xml?channel_id=UCaaaaaaaaaaaaaaaaaaaaaa#x",
        ] {
            XCTAssertFalse(on.allows(URL(string: bad)!, for: .youtubeFeed), bad)
        }
        XCTAssertFalse(on.allows(URL(string: ok)!, for: .recipeUpdate), "purposes don't mix")

        let off = NetworkPolicy(recipes: [try RecipeLibrary.bundled(.instagram)], recipeUpdatesEnabled: false)
        XCTAssertFalse(off.allows(URL(string: ok)!, for: .youtubeFeed), "YouTube disabled: no feeds")
    }
}
