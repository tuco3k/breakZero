import Foundation
import XCTest
@testable import Core

/// Feed rules (ARCHITECTURE.md §4c rev. 2): rules and precedence, ratchet cooldowns for every list
/// and rule change, people data, the export importer, and the auto-scroll sync session.
final class FeedRulesTests: XCTestCase {
    var ratchet: Ratchet!
    var policy: WallPolicy!
    var lock: LockState!
    var clock: FakeClock!

    override func setUpWithError() throws {
        ratchet = Ratchet(recipes: [try RecipeLibrary.bundled(.instagram), try RecipeLibrary.bundled(.youtube)])
        policy = WallPolicy(lockEnabled: true)
        lock = LockState()
        clock = FakeClock()
        lock.ledger.record(clock.sample)
    }

    func submit(_ c: PolicyChange) -> SubmitResult {
        ratchet.submit([c], policy: &policy, lock: &lock, at: clock.sample)[0]
    }

    func classify(_ c: PolicyChange) -> ChangeKind { ratchet.classify(c, against: policy) }

    var ig: PlatformSettings {
        get { policy.settings(for: .instagram) }
        set { policy.platformSettings[.instagram] = newValue }
    }

    static let people = PeopleData(followers: ["alice", "bob.b", "carol", "fan"],
                                   following: ["alice", "bob.b", "carol", "brand", "celeb"],
                                   closeFriends: ["alice"], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))

    // MARK: Usernames

    func testNormalize() {
        XCTAssertEqual(Friends.normalize("@Alice.B "), "alice.b")
        XCTAssertEqual(Friends.normalize("bob_99"), "bob_99")
        XCTAssertNil(Friends.normalize(""))
        XCTAssertNil(Friends.normalize("has space"))
        XCTAssertNil(Friends.normalize("émile"), "Instagram usernames are ASCII")
        XCTAssertNil(Friends.normalize(String(repeating: "a", count: 31)))
    }

    // MARK: Rules and precedence

    func testDefaultsAreMutualsWithProfileStoriesOn() {
        let s = PlatformSettings()
        XCTAssertEqual(s.audience(.feed), .mutuals)
        XCTAssertEqual(s.audience(.stories), .mutuals)
        XCTAssertTrue(s.profileStories)
    }

    func testRev1FriendsListKeepsMyList() throws {
        let old = #"{"toggles":{},"customBlocks":[],"customHides":[],"friends":["alice"]}"#
        let s = try JSONDecoder().decode(PlatformSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.audience(.feed), .myList, "no silent widening to all mutuals (QUESTIONS #47)")
        XCTAssertEqual(s.audience(.stories), .myList)
        let empty = try JSONDecoder().decode(PlatformSettings.self, from: Data(#"{"friends":[]}"#.utf8))
        XCTAssertEqual(empty.audience(.feed), .mutuals)
    }

    func testPrecedenceNeverBeatsAlwaysBeatsTheRule() {
        var s = PlatformSettings(feedRules: FeedRules(always: ["zed", "carol"], never: ["alice", "zed"]))
        XCTAssertEqual(s.allowed(.feed, people: Self.people), ["bob.b", "carol"],
                       "mutuals ∪ always − never: zed is in both lists, never wins")
        s.feedRules.feed = .everyone
        XCTAssertEqual(s.allowed(.feed, people: Self.people), ["bob.b", "brand", "carol", "celeb"])
        s.feedRules.feed = .closeFriends
        XCTAssertEqual(s.allowed(.feed, people: Self.people), ["carol"], "alice is a close friend but never-shown")
        s.feedRules.feed = .myList
        s.friends = ["dave"]
        XCTAssertEqual(s.allowed(.feed, people: Self.people), ["carol", "dave"])
    }

    func testNoDataMeansNoAudienceFilter() {
        let s = PlatformSettings()
        XCTAssertNil(s.allowed(.feed, people: nil))
        XCTAssertNil(s.allowed(.feed, people: PeopleData(followers: ["a"])), "mutuals need both lists")
        var close = PlatformSettings(feedRules: FeedRules(feed: .closeFriends))
        XCTAssertNil(close.allowed(.feed, people: PeopleData(followers: ["a"], following: ["a"])))
        close.feedRules.feed = .myList
        XCTAssertEqual(close.allowed(.feed, people: nil), [], "an empty My list shows nobody")
    }

    func active(_ s: PlatformSettings, people: PeopleData? = FeedRulesTests.people) throws -> ActiveRecipe {
        try ActiveRecipe(recipe: RecipeLibrary.bundled(.instagram), settings: s, people: people)
    }

    func testActiveRecipeCarriesTheSets() throws {
        let a = try active(PlatformSettings(feedRules: FeedRules(stories: .everyone, never: ["celeb"])))
        let f = try XCTUnwrap(a.friends)
        XCTAssertEqual(f.feed, ["alice", "bob.b", "carol"])
        XCTAssertEqual(f.stories, ["alice", "bob.b", "brand", "carol"])
        XCTAssertEqual(f.never, ["celeb"])
        XCTAssertTrue(f.profileStories)
        XCTAssertEqual(f.closePath, "/?variant=following")
        XCTAssertTrue(f.allows(.feed, "alice"))
        XCTAssertFalse(f.allows(.feed, "brand"))
        XCTAssertFalse(f.allows(.stories, "celeb"))
    }

    func testNothingToFilterMeansNoFriendsConfig() throws {
        XCTAssertNil(try active(PlatformSettings(), people: nil).friends, "no data, no never list")
        XCTAssertNotNil(try active(PlatformSettings(feedRules: FeedRules(never: ["x"])), people: nil).friends,
                        "never-show works before any import")
        XCTAssertNil(try active(PlatformSettings(toggles: ["ig.friendsOnly": false])).friends)
    }

    func testSuggestionsAndAdsAreAlwaysHiddenWhileRulesAreOn() throws {
        let off = PlatformSettings(toggles: ["ig.hideSuggested": false, "ig.hideSponsored": false])
        let a = try active(off)
        XCTAssertTrue(a.recipe.heuristics.contains { $0.id == "ig.heur.suggestedPeople" })
        XCTAssertTrue(a.recipe.hide.contains { $0.id == "ig.hide.sponsored" })
        var rulesOff = off
        rulesOff.toggles["ig.friendsOnly"] = false
        XCTAssertFalse(try active(rulesOff).recipe.heuristics.contains { $0.id == "ig.heur.suggestedPeople" })
    }

    func testNativeWatchdogSeesTheStoryGate() throws {
        let engine = try RuleEngine(active: active(PlatformSettings()))
        let d = engine.check(url: URL(string: "https://www.instagram.com/stories/brand/5/")!, state: NavigationState())
        XCTAssertEqual(d, .redirect(to: "/?variant=following", reason: .redirected(ruleID: Friends.storyGateID)))
        XCTAssertEqual(engine.check(url: URL(string: "https://www.instagram.com/stories/brand/5/")!,
                                    state: NavigationState(storyUser: "brand")), .allow, "opened from their profile")
    }

    func testStoryUserTravelsToThePage() throws {
        let s = NavigationState(storyUser: "brand")
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertTrue(json.contains(#""storyUser":"brand""#))
        XCTAssertEqual(try JSONDecoder().decode(NavigationState.self, from: Data(json.utf8)), s)
    }

    // MARK: Ratchet: rules

    func testAudienceChanges() {
        XCTAssertEqual(classify(.setAudience(.instagram, .feed, .everyone)), .loosening)
        XCTAssertEqual(classify(.setAudience(.instagram, .feed, .myList)), .loosening, "not a subset of mutuals")
        XCTAssertEqual(classify(.setAudience(.instagram, .stories, .closeFriends)), .loosening)
        XCTAssertEqual(classify(.setAudience(.instagram, .feed, .mutuals)), .neutral)
        ig = PlatformSettings(feedRules: FeedRules(feed: .everyone))
        XCTAssertEqual(classify(.setAudience(.instagram, .feed, .mutuals)), .tightening)
        XCTAssertEqual(classify(.setAudience(.instagram, .feed, .closeFriends)), .tightening)
    }

    func testWideningARuleWaitsNarrowingIsInstant() {
        guard case .queued = submit(.setAudience(.instagram, .feed, .everyone)) else { return XCTFail("widening") }
        XCTAssertEqual(ig.audience(.feed), .mutuals)
        clock.advance(policy.cooldown + 1)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(ig.audience(.feed), .everyone)
        XCTAssertEqual(submit(.setAudience(.instagram, .feed, .mutuals)), .applied(.tightening))
        XCTAssertEqual(ig.audience(.feed), .mutuals)
    }

    func testProfileStories() {
        XCTAssertEqual(classify(.setProfileStories(.instagram, true)), .neutral, "already on")
        XCTAssertEqual(submit(.setProfileStories(.instagram, false)), .applied(.tightening))
        guard case .queued = submit(.setProfileStories(.instagram, true)) else { return XCTFail("turning it on widens") }
    }

    func testRuleSwitches() {
        XCTAssertEqual(classify(.setToggle(.instagram, id: "ig.friendsOnly", on: false)), .loosening)
        XCTAssertEqual(classify(.setToggle(.instagram, id: "ig.forceFollowing", on: false)), .loosening)
    }

    // MARK: Ratchet: lists

    func testAlwaysShow() {
        XCTAssertEqual(classify(.addPerson(.instagram, .always, username: "brand")), .loosening)
        ig = PlatformSettings(feedRules: FeedRules(always: ["brand"]))
        XCTAssertEqual(classify(.removePerson(.instagram, .always, username: "brand")), .tightening)
        XCTAssertEqual(classify(.addPerson(.instagram, .always, username: "brand")), .neutral)
    }

    func testNeverShow() {
        XCTAssertEqual(submit(.addPerson(.instagram, .never, username: "alice")), .applied(.tightening))
        XCTAssertEqual(ig.feedRules.never, ["alice"])
        guard case .queued = submit(.removePerson(.instagram, .never, username: "alice")) else {
            return XCTFail("removing from never-show widens")
        }
        XCTAssertEqual(ig.feedRules.never, ["alice"])
    }

    func testMyListCountsOnlyWhileARuleUsesIt() {
        XCTAssertEqual(classify(.addPerson(.instagram, .myList, username: "dave")), .neutral, "rules use mutuals")
        XCTAssertEqual(classify(.addFriend(.instagram, username: "dave")), .neutral, "rev. 1 alias")
        ig = PlatformSettings(feedRules: FeedRules(stories: .myList))
        XCTAssertEqual(classify(.addPerson(.instagram, .myList, username: "dave")), .loosening)
        ig = PlatformSettings(friends: ["dave"], feedRules: FeedRules(feed: .myList))
        XCTAssertEqual(classify(.removePerson(.instagram, .myList, username: "dave")), .tightening,
                       "an empty My list shows nobody, so even the last removal narrows")
    }

    func testListEditsAreNeutralWhileRulesAreOff() {
        ig = PlatformSettings(toggles: ["ig.friendsOnly": false])
        XCTAssertEqual(classify(.addPerson(.instagram, .always, username: "x")), .neutral)
        XCTAssertEqual(classify(.setAudience(.instagram, .feed, .everyone)), .neutral)
        XCTAssertEqual(classify(.addPerson(.youtube, .always, username: "x")), .neutral, "no feed rules on YouTube")
    }

    func testANewerEditSupersedesAPendingOne() {
        _ = submit(.addPerson(.instagram, .always, username: "bob"))
        XCTAssertEqual(lock.pending.count, 1)
        XCTAssertEqual(submit(.removePerson(.instagram, .always, username: "bob")), .applied(.neutral))
        XCTAssertTrue(lock.pending.isEmpty, "cancels the wait")
    }

    func testClockForwardDoesNotSpeedUpAWidening() {
        _ = submit(.addPerson(.instagram, .always, username: "bob"))
        clock.jumpWall(policy.cooldown * 2)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(ig.feedRules.always, [])
    }

    func testHardLockHoldsBackWidenings() {
        _ = submit(.setHardLock(until: clock.wall.addingTimeInterval(7 * 86400)))
        XCTAssertEqual(submit(.addPerson(.instagram, .always, username: "bob")),
                       .rejectedHardLock(until: clock.wall.addingTimeInterval(7 * 86400)))
        XCTAssertEqual(submit(.addPerson(.instagram, .never, username: "bob")), .applied(.tightening))
    }

    func testInvalidNamesAndCapsAreRejected() {
        XCTAssertEqual(submit(.addPerson(.instagram, .never, username: "Not Valid")), .rejectedInvalid("invalid username"))
        ig = PlatformSettings(feedRules: FeedRules(never: (0..<Friends.maxCount).map { "u\($0)" }))
        XCTAssertEqual(submit(.addPerson(.instagram, .never, username: "one_more")),
                       .rejectedInvalid("at most \(Friends.maxCount) people per list"))
    }

    func testRev1PendingChangesStillLoad() throws {
        let p = PendingChange(id: UUID(), change: .addFriend(.instagram, username: "bob"), submittedAt: clock.wall,
                              creditedAtSubmit: 0, cooldown: 3600, estimatedDue: clock.wall)
        let back = try JSONDecoder().decode(PendingChange.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertEqual(PolicyChange.addFriend(.instagram, username: "bob").fieldKey,
                       PolicyChange.addPerson(.instagram, .myList, username: "bob").fieldKey)
    }

    // MARK: People data

    func testMutualsAndFollowingOnly() {
        XCTAssertEqual(Self.people.mutuals, ["alice", "bob.b", "carol"])
        XCTAssertEqual(Self.people.followingOnly, ["brand", "celeb"])
        XCTAssertTrue(Self.people.hasMutualsData)
    }

    func testAFullRefreshRemovesPeopleAtOnce() throws {
        var p = Self.people
        try p.replace(followers: ["alice"], following: ["alice", "brand"], closeFriends: nil, owner: "me", now: clock.wall)
        XCTAssertEqual(p.mutuals, ["alice"])
        XCTAssertEqual(p.closeFriends, ["alice"], "kept when the export had no close-friends file")
        XCTAssertEqual(p.source, .export)
        XCTAssertThrowsError(try p.replace(followers: ["a"], following: [], closeFriends: nil, owner: nil, now: clock.wall)) {
            XCTAssertEqual($0 as? PeopleData.ReplaceError, .noFollowing)
        }
        XCTAssertEqual(p.mutuals, ["alice"], "a rejected import changes nothing")
    }

    func testPartialReadsOnlyAdd() {
        var p = Self.people
        XCTAssertEqual(p.add(.followers, ["brand", "Alice", "bad name"], source: .manual, now: clock.wall), 1)
        XCTAssertEqual(p.mutuals, ["alice", "bob.b", "brand", "carol"])
    }

    func testFreshness() {
        var p = PeopleData()
        XCTAssertNil(p.daysSinceUpdate(now: clock.wall))
        XCTAssertFalse(p.isStale(now: clock.wall))
        p.updatedAt = clock.wall
        XCTAssertEqual(p.daysSinceUpdate(now: clock.wall.addingTimeInterval(3 * 86400 + 60)), 3)
        XCTAssertFalse(p.isStale(now: clock.wall.addingTimeInterval(29 * 86400)))
        XCTAssertTrue(p.isStale(now: clock.wall.addingTimeInterval(30 * 86400)))
    }

    // MARK: Export import

    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testImportTheExportZip() throws {
        let r = try ExportImporter.importFiles([("instagram-me-2026-10-01.zip", fixture("ig-export.zip"))])
        XCTAssertEqual(r.followers, ["alice", "bob.b", "carol", "fan"])
        XCTAssertEqual(r.following, ["alice", "bob.b", "carol", "brand"], "title, /_u/ href and plain href; junk skipped")
        XCTAssertEqual(r.closeFriends, ["alice"])
        XCTAssertEqual(r.owner, "me.myself")
        XCTAssertEqual(r.mutuals, ["alice", "bob.b", "carol"])
        XCTAssertFalse(r.filesRead.contains("pending_follow_requests.json"), "pending requests aren't connections")
        XCTAssertEqual(Set(r.filesRead), ["followers_1.json", "following.json", "close_friends.json"])
    }

    func testImportLooseJSONFiles() throws {
        let followers = #"[{"string_list_data":[{"href":"https://www.instagram.com/alice","value":"alice"}]}]"#
        let following = #"{"relationships_following":[{"title":"alice","string_list_data":[]},{"title":"brand"}]}"#
        let r = try ExportImporter.importFiles([("followers_1.json", Data(followers.utf8)), ("following.json", Data(following.utf8))])
        XCTAssertEqual(r.mutuals, ["alice"])
        XCTAssertNil(r.closeFriends)
    }

    func testRecognizesTheListByItsKeyWhenTheFileWasRenamed() throws {
        let following = #"{"relationships_following":[{"title":"alice"}]}"#
        XCTAssertEqual(try ExportImporter.importFiles([("download (3).json", Data(following.utf8))]).following, ["alice"])
    }

    func testHTMLExportsAreRejectedWithAClearReason() throws {
        XCTAssertThrowsError(try ExportImporter.importFiles([("export.zip", fixture("ig-export-html.zip"))])) {
            XCTAssertEqual($0 as? ExportImporter.Failure, .htmlExport)
        }
        XCTAssertThrowsError(try ExportImporter.importFiles([("following.html", Data("<html></html>".utf8))])) {
            XCTAssertEqual($0 as? ExportImporter.Failure, .htmlExport)
        }
    }

    func testMalformedInput() throws {
        XCTAssertThrowsError(try ExportImporter.importFiles([("followers_1.json", Data(#"[{"title":"alice"}]"#.utf8))])) {
            XCTAssertEqual($0 as? ExportImporter.Failure, .noFollowingList)
        }
        XCTAssertThrowsError(try ExportImporter.importFiles([("notes.json", Data(#"{"a":1}"#.utf8))])) {
            XCTAssertEqual($0 as? ExportImporter.Failure, .notAnExport)
        }
        XCTAssertThrowsError(try ExportImporter.importFiles([("following.json", Data("{not json".utf8))])) {
            XCTAssertEqual($0 as? ExportImporter.Failure, .notAnExport)
        }
        var zip = try fixture("ig-export.zip")
        zip = zip.prefix(zip.count / 2)
        XCTAssertThrowsError(try ExportImporter.importFiles([("cut.zip", zip)])) {
            XCTAssertEqual($0 as? ExportImporter.Failure, .unreadableArchive)
        }
        XCTAssertThrowsError(try ExportImporter.importFiles([("x.zip", Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3]))]))
    }

    func testThousandsOfAccountsImportQuickly() throws {
        func list(_ key: String, _ range: Range<Int>) -> Data {
            let items = range.map { #"{"title":"","string_list_data":[{"href":"https://www.instagram.com/user\#($0)","value":"user\#($0)","timestamp":1700000000}]}"# }
            return Data((key.isEmpty ? "[\(items.joined(separator: ","))]" : "{\"\(key)\":[\(items.joined(separator: ","))]}").utf8)
        }
        let start = Date()
        let r = try ExportImporter.importFiles([("followers_1.json", list("", 0..<9000)),
                                                ("following.json", list("relationships_following", 4000..<12000))])
        XCTAssertEqual(r.followers.count, 9000)
        XCTAssertEqual(r.following.count, 8000)
        XCTAssertEqual(r.mutuals.count, 5000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "17,000 accounts")
    }

    // MARK: Inflate and zip

    func testInflateFixedStoredAndDynamicBlocks() throws {
        XCTAssertEqual(try Inflate.inflate([203, 72, 205, 201, 201, 87, 200, 64, 39, 1], maxOutput: 100),
                       Array("hello hello hello hello".utf8))
        XCTAssertEqual(try Inflate.inflate([1, 3, 0, 252, 255, 97, 98, 99], maxOutput: 100), Array("abc".utf8))
        let packed = "bdO7CsJAEEDRX5GtLZyXr18REYuoCyGRJGIR8u+mdm633GoOszOXoWnvU+278VXf4+3Rt23/rd2znDeXuUx1apv1WT5jM+zKsv1LkpPmZDl5TpHTPqdDTsecTjAqjQ/zCwAEBAIEAYMAQkAhwBBwKDiU9gAOBYeCQ8Gh4FBwKDgUHAYOA4fRhwKHgcPAYeAwcBg4DBwODgeHg8PpMsDh4HBwODgcHA6OAEeAI8AR4Ag6cXAEOAIcAY5YHdflBw=="
        let source = #"{"relationships_following": ["# + (0..<60).map { #"{"title": "user\#($0)"}"# }.joined(separator: ",") + "]}"
        XCTAssertEqual(try Inflate.inflate([UInt8](try XCTUnwrap(Data(base64Encoded: packed))), maxOutput: 10_000),
                       Array(source.utf8))
    }

    func testInflateFailsSafely() {
        XCTAssertThrowsError(try Inflate.inflate([203, 72, 205], maxOutput: 100), "truncated")
        XCTAssertThrowsError(try Inflate.inflate([0xFF, 0xFF, 0xFF, 0xFF], maxOutput: 100), "bad block type")
        XCTAssertThrowsError(try Inflate.inflate([1, 3, 0, 0, 0, 97, 98, 99], maxOutput: 100), "length check")
        XCTAssertThrowsError(try Inflate.inflate([203, 72, 205, 201, 201, 87, 200, 64, 39, 1], maxOutput: 10)) {
            XCTAssertEqual($0 as? Inflate.Failure, .tooLarge, "capped output")
        }
    }

    func testZipReaderListsEntries() throws {
        let zip = try ZipReader(fixture("ig-export.zip"))
        XCTAssertEqual(zip.entries.count, 6)
        let photo = try XCTUnwrap(zip.entries.first { $0.name == "media/photo.jpg" })
        XCTAssertEqual(try zip.data(photo, maxSize: 10_000).count, 2002, "stored entry")
        XCTAssertThrowsError(try zip.data(photo, maxSize: 100))
        XCTAssertThrowsError(try ZipReader(Data("not a zip at all, sorry".utf8)))
    }

    // MARK: Auto-scroll sync

    func testSyncReadsBothListsAndReplacesThem() {
        var people = Self.people
        var s = SyncSession(owner: "me")
        s.begin(people: people)
        XCTAssertEqual(s.currentList, .followers)
        XCTAssertEqual(s.record(.followers, ["alice", "bob.b", "me", "newfan"], people: &people, now: clock.wall), .keepGoing)
        XCTAssertFalse(s.collected[.followers]!.contains("me"), "the owner isn't their own follower")
        XCTAssertEqual(s.record(.following, ["x"], people: &people, now: clock.wall), .keepGoing, "not the current list")
        XCTAssertEqual(s.reachedEnd(.followers, people: &people, now: clock.wall), .nextList(.following))
        XCTAssertEqual(people.followers, ["alice", "bob.b", "newfan"], "replaced: carol and fan unfollowed you")
        _ = s.record(.following, ["alice", "newfan", "brand"], people: &people, now: clock.wall)
        XCTAssertEqual(s.reachedEnd(.following, people: &people, now: clock.wall), .finished)
        XCTAssertEqual(people.mutuals, ["alice", "newfan"])
        XCTAssertEqual(people.source, .sync)
        XCTAssertFalse(s.running)
    }

    func testSyncStopsAtTheCapAndResumesWhereItLeftOff() {
        var people = PeopleData()
        var s = SyncSession(owner: "me", cap: 3)
        s.begin(people: people)
        XCTAssertEqual(s.record(.followers, ["a", "b"], people: &people, now: clock.wall), .keepGoing)
        XCTAssertEqual(s.record(.followers, ["b", "c", "d"], people: &people, now: clock.wall), .stop(.cap))
        XCTAssertEqual(people.followers, ["a", "b", "c"], "saved as it went, capped at 3 new")
        XCTAssertEqual(s.record(.followers, ["e"], people: &people, now: clock.wall), .keepGoing, "ignored while stopped")
        XCTAssertEqual(people.followers.count, 3)
        // Next session: scrolling from the top again; names already read don't count against the cap.
        s.begin(people: people)
        XCTAssertEqual(s.currentList, .followers)
        XCTAssertEqual(s.record(.followers, ["a", "b", "c", "d", "e"], people: &people, now: clock.wall), .keepGoing)
        XCTAssertEqual(s.newThisSession, 1, "only e is new: d was read but over the cap last time")
    }

    func testSyncStopsOnWarnings() {
        var people = Self.people
        var s = SyncSession(owner: "me")
        s.begin(people: people)
        _ = s.record(.followers, ["newfan"], people: &people, now: clock.wall)
        s.stop(.challenge)
        XCTAssertFalse(s.running)
        XCTAssertEqual(s.lastStop, .challenge)
        XCTAssertTrue(SyncStopReason.challenge.isWarning)
        XCTAssertTrue(SyncStopReason.login.isWarning)
        XCTAssertTrue(SyncStopReason.warning.isWarning)
        XCTAssertFalse(SyncStopReason.cap.isWarning)
        XCTAssertTrue(people.followers.contains("newfan"), "what was read is kept")
        XCTAssertTrue(people.followers.contains("fan"), "a stopped read never removes anyone")
        XCTAssertEqual(s.reachedEnd(.followers, people: &people, now: clock.wall), .keepGoing, "ignored after a stop")
    }

    func testAnEndThatLooksIncompleteOnlyAdds() {
        var people = PeopleData(followers: Set((0..<100).map { "f\($0)" }), following: ["f1"])
        var s = SyncSession(owner: "me")
        s.begin(people: people)
        _ = s.record(.followers, (0..<30).map { "f\($0)" }, people: &people, now: clock.wall)
        XCTAssertEqual(s.reachedEnd(.followers, people: &people, now: clock.wall), .nextList(.following))
        XCTAssertEqual(people.followers.count, 100, "30 of 100: probably a stall, so nobody is removed")
        XCTAssertEqual(s.incompleteLists, [.followers])
    }

    func testAFinishedPassStartsOver() {
        var people = PeopleData()
        var s = SyncSession(owner: "me", lists: [.following])
        s.begin(people: people)
        _ = s.record(.following, ["a"], people: &people, now: clock.wall)
        XCTAssertEqual(s.reachedEnd(.following, people: &people, now: clock.wall), .finished)
        s.begin(people: people)
        XCTAssertEqual(s.currentList, .following)
        XCTAssertTrue(s.collected.isEmpty)
    }

    func testPacing() {
        XCTAssertTrue(SyncPacing.default.isValid)
        XCTAssertFalse(SyncPacing(minStep: 0.2).isValid, "never faster than a screen a second")
        XCTAssertFalse(SyncPacing(minStep: 3, maxStep: 2).isValid)
        XCTAssertFalse(SyncPacing(minPause: 1).isValid, "pauses are longer than steps")
    }

    // MARK: Recipe

    func testBundledRecipeHasAValidFriendsFilter() throws {
        let r = try RecipeLibrary.bundled(.instagram)
        let f = try XCTUnwrap(r.friendsFilter)
        XCTAssertEqual(r.toggleDefault(f.toggle), true)
        XCTAssertEqual(f.feedPath(forceFollowing: true), "/?variant=following")
        XCTAssertEqual(try PathRegex(f.storyRoute).firstMatch("/stories/alice/1/")?["user"], "alice")
        XCTAssertEqual(try PathRegex(f.scanRoutes["followers"]!).firstMatch("/me/followers/")?["owner"], "me")
    }
}
