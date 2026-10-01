import Foundation
import XCTest
@testable import Core

/// Old Instagram (ARCHITECTURE.md §4c): Friends list, mutual detection, ratchet rules, story gate.
final class FriendsTests: XCTestCase {
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

    var friends: [String] { policy.settings(for: .instagram).friends }

    // MARK: Usernames

    func testNormalize() {
        XCTAssertEqual(Friends.normalize("@Alice.B "), "alice.b")
        XCTAssertEqual(Friends.normalize("bob_99"), "bob_99")
        XCTAssertNil(Friends.normalize(""))
        XCTAssertNil(Friends.normalize("has space"))
        XCTAssertNil(Friends.normalize("a/b"))
        XCTAssertNil(Friends.normalize("émile"), "Instagram usernames are ASCII")
        XCTAssertNil(Friends.normalize(String(repeating: "a", count: 31)))
        XCTAssertEqual(Friends.normalize(String(repeating: "a", count: 30))?.count, 30)
    }

    // MARK: Ratchet

    func testFirstFriendIsTighteningAndAppliesNow() {
        XCTAssertEqual(submit(.addFriend(.instagram, username: "alice")), .applied(.tightening),
                       "an empty list means the filter is off; the first friend switches it on")
        XCTAssertEqual(friends, ["alice"])
    }

    func testAddingMoreFriendsWaitsTheCooldown() {
        _ = submit(.addFriend(.instagram, username: "alice"))
        guard case .queued = submit(.addFriend(.instagram, username: "bob")) else { return XCTFail("adding is a loosening") }
        XCTAssertEqual(friends, ["alice"])
        clock.advance(policy.cooldown - 1)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(friends, ["alice"], "not before the cooldown")
        clock.advance(2)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(friends, ["alice", "bob"])
    }

    func testClockForwardDoesNotSpeedUpAnAdd() {
        _ = submit(.addFriend(.instagram, username: "alice"))
        _ = submit(.addFriend(.instagram, username: "bob"))
        clock.jumpWall(policy.cooldown * 2)
        ratchet.applyDue(policy: &policy, lock: &lock, at: clock.sample)
        XCTAssertEqual(friends, ["alice"])
    }

    func testRemovingIsInstantExceptTheLastFriend() {
        policy.platformSettings[.instagram] = PlatformSettings(friends: ["alice", "bob"])
        XCTAssertEqual(submit(.removeFriend(.instagram, username: "bob")), .applied(.tightening))
        XCTAssertEqual(friends, ["alice"])
        guard case .queued = submit(.removeFriend(.instagram, username: "alice")) else {
            return XCTFail("removing the last friend switches the filter off: a loosening")
        }
        XCTAssertEqual(friends, ["alice"])
    }

    func testListEditsAreNeutralWhileOldInstagramIsOff() {
        policy.platformSettings[.instagram] = PlatformSettings(toggles: ["ig.friendsOnly": false], friends: ["alice"])
        XCTAssertEqual(ratchet.classify(.addFriend(.instagram, username: "bob"), against: policy), .neutral)
        XCTAssertEqual(ratchet.classify(.removeFriend(.instagram, username: "alice"), against: policy), .neutral)
        XCTAssertEqual(ratchet.classify(.setToggle(.instagram, id: "ig.friendsOnly", on: true), against: policy), .tightening)
    }

    func testTurningOldInstagramOffIsALoosening() {
        XCTAssertEqual(ratchet.classify(.setToggle(.instagram, id: "ig.friendsOnly", on: false), against: policy), .loosening)
        XCTAssertEqual(ratchet.classify(.setToggle(.instagram, id: "ig.forceFollowing", on: false), against: policy), .loosening)
    }

    func testNoOpsAreNeutral() {
        policy.platformSettings[.instagram] = PlatformSettings(friends: ["alice"])
        XCTAssertEqual(ratchet.classify(.addFriend(.instagram, username: "alice"), against: policy), .neutral)
        XCTAssertEqual(ratchet.classify(.removeFriend(.instagram, username: "zed"), against: policy), .neutral)
        XCTAssertEqual(ratchet.classify(.addFriend(.youtube, username: "alice"), against: policy), .neutral,
                       "no friends filter on YouTube")
    }

    func testANewerEditSupersedesAPendingAdd() {
        _ = submit(.addFriend(.instagram, username: "alice"))
        _ = submit(.addFriend(.instagram, username: "bob"))
        XCTAssertEqual(lock.pending.count, 1)
        XCTAssertEqual(submit(.removeFriend(.instagram, username: "bob")), .applied(.neutral))
        XCTAssertTrue(lock.pending.isEmpty, "removing a pending friend cancels the wait")
    }

    func testInvalidUsernamesAndTheCapAreRejected() {
        XCTAssertEqual(submit(.addFriend(.instagram, username: "Not Valid")), .rejectedInvalid("invalid username"))
        policy.platformSettings[.instagram] = PlatformSettings(friends: (0..<Friends.maxCount).map { "u\($0)" })
        XCTAssertEqual(submit(.addFriend(.instagram, username: "one_more")), .rejectedInvalid("at most \(Friends.maxCount) friends"))
    }

    func testHardLockHoldsBackAdds() {
        _ = submit(.addFriend(.instagram, username: "alice"))
        _ = submit(.setHardLock(until: clock.wall.addingTimeInterval(7 * 86400)))
        XCTAssertEqual(submit(.addFriend(.instagram, username: "bob")),
                       .rejectedHardLock(until: clock.wall.addingTimeInterval(7 * 86400)))
    }

    func testPolicyWithFriendsRoundTripsAndOldPoliciesLoad() throws {
        policy.platformSettings[.instagram] = PlatformSettings(friends: ["alice"])
        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(WallPolicy.self, from: data), policy)
        let old = #"{"platformSettings":{"instagram":{"toggles":{},"customBlocks":[],"customHides":[]}}}"#
        XCTAssertEqual(try JSONDecoder().decode(WallPolicy.self, from: Data(old.utf8)).settings(for: .instagram).friends, [])
    }

    // MARK: ActiveRecipe + story gate

    func active(_ settings: PlatformSettings) throws -> ActiveRecipe {
        try ActiveRecipe(recipe: RecipeLibrary.bundled(.instagram), settings: settings)
    }

    func testOffWithAnEmptyList() throws {
        let a = try active(.default)
        XCTAssertNil(a.friends)
        XCTAssertFalse(a.recipe.routes.contains { $0.id == Friends.storyGateID })
    }

    func testOnAsSoonAsTheListHasAFriend() throws {
        let a = try active(PlatformSettings(friends: ["alice", "bob.b"]))
        XCTAssertEqual(a.friends, ActiveFriends(usernames: ["alice", "bob.b"], forceFollowing: true))
        let gate = try XCTUnwrap(a.recipe.routes.first { $0.id == Friends.storyGateID })
        XCTAssertEqual(gate.action, .redirect)
        XCTAssertEqual(gate.to, "/?variant=following")
        XCTAssertNil(try active(PlatformSettings(toggles: ["ig.friendsOnly": false], friends: ["alice"])).friends)
        let noForce = try active(PlatformSettings(toggles: ["ig.forceFollowing": false], friends: ["alice"]))
        XCTAssertEqual(noForce.friends?.forceFollowing, false)
        XCTAssertEqual(noForce.recipe.routes.first { $0.id == Friends.storyGateID }?.to, "/")
    }

    func testSuggestionsAndSponsoredAreForcedOnWhileActive() throws {
        let off = PlatformSettings(toggles: ["ig.hideSuggested": false, "ig.hideSponsored": false])
        XCTAssertFalse(try active(off).recipe.heuristics.contains { $0.id == "ig.heur.suggestedPeople" })
        var on = off
        on.friends = ["alice"]
        let a = try active(on)
        XCTAssertTrue(a.recipe.heuristics.contains { $0.id == "ig.heur.suggestedPeople" })
        XCTAssertTrue(a.recipe.hide.contains { $0.id == "ig.hide.sponsored" })
    }

    func testStoryGateDecisions() throws {
        let engine = try RuleEngine(active: active(PlatformSettings(friends: ["alice", "bob.b"])))
        func decide(_ path: String) -> NavigationDecision {
            var s = NavigationState()
            return engine.decide(url: URL(string: "https://www.instagram.com" + path)!, from: nil, state: &s)
        }
        XCTAssertEqual(decide("/stories/alice/123/"), .allow)
        XCTAssertEqual(decide("/stories/alice/"), .allow)
        XCTAssertEqual(decide("/stories/bob.b/9/"), .allow)
        XCTAssertEqual(decide("/stories/highlights/1789/"), .allow, "highlights: checked by the viewer's author")
        let closed = NavigationDecision.redirect(to: "/?variant=following", reason: .redirected(ruleID: Friends.storyGateID))
        XCTAssertEqual(decide("/stories/stranger/1/"), closed)
        XCTAssertEqual(decide("/stories/stranger"), closed, "no trailing slash")
        XCTAssertEqual(decide("/stories/alicex/1/"), closed, "a friend's name as a prefix doesn't count")
        XCTAssertEqual(decide("/stories/bobxb/1/"), closed, "the dot is escaped")
        XCTAssertEqual(decide("/stories/ali/1/"), closed)
        XCTAssertEqual(decide("/stranger/"), .allow, "profiles you tap stay open")
        XCTAssertEqual(decide("/direct/t/1/"), .allow)
        XCTAssertEqual(decide("/p/ABC/"), .allow)
    }

    func testGatePatternMatchesTheJavaScriptMirror() {
        // Same literal as jstests/friends.test.js "Swift and JS build the same story gate".
        XCTAssertEqual(Friends.storyGatePattern(friends: ["bob.b", "alice"], exempt: ["highlights"]),
                       #"^/stories/(?!(?:alice|bob\.b|highlights)(?:/|$))[^/]+(?:/|$)"#)
    }

    func testTheNativeWatchdogSeesTheGateToo() throws {
        let engine = try RuleEngine(active: active(PlatformSettings(friends: ["alice"])))
        let d = engine.check(url: URL(string: "https://www.instagram.com/stories/brand/5/")!, state: NavigationState())
        XCTAssertEqual(d, .redirect(to: "/?variant=following", reason: .redirected(ruleID: Friends.storyGateID)))
    }

    func testGateWithTheMaximumListStillValidates() throws {
        let many = (0..<Friends.maxCount).map { "user.\($0)" }
        let a = try active(PlatformSettings(friends: many))
        let engine = try RuleEngine(active: a)
        var s = NavigationState()
        XCTAssertEqual(engine.decide(url: URL(string: "https://www.instagram.com/stories/user.1999/1/")!, from: nil, state: &s), .allow)
    }

    // MARK: Scan state (setup)

    func testMutualsAreSuggestions() {
        var scan = FriendsScanState()
        scan.merge(.followers, owner: "Me", usernames: ["alice", "bob", "brand", "me"], now: clock.wall)
        scan.merge(.following, owner: "me", usernames: ["alice", "bob", "celebrity"], now: clock.wall)
        XCTAssertEqual(scan.owner, "me")
        XCTAssertEqual(scan.followers, ["alice", "bob", "brand"], "the owner isn't their own follower")
        XCTAssertEqual(scan.mutuals, ["alice", "bob"])
        XCTAssertEqual(scan.suggestions(excluding: ["alice"]), ["bob"])
    }

    func testCloseFriendsAreSuggestionsToo() {
        var scan = FriendsScanState()
        scan.merge(.closeFriends, owner: nil, usernames: ["carol"], now: clock.wall)
        XCTAssertEqual(scan.suggestions(excluding: []), ["carol"])
    }

    func testAnotherOwnersListStartsOver() {
        var scan = FriendsScanState()
        scan.merge(.followers, owner: "me", usernames: ["alice"], now: clock.wall)
        scan.merge(.following, owner: "me", usernames: ["alice"], now: clock.wall)
        scan.merge(.followers, owner: "celebrity", usernames: ["x"], now: clock.wall)
        XCTAssertEqual(scan.owner, "celebrity")
        XCTAssertTrue(scan.mutuals.isEmpty, "never mix two accounts' lists into mutuals")
    }

    func testMergeDropsBadNamesCountsNewOnesAndCaps() {
        var scan = FriendsScanState()
        XCTAssertEqual(scan.merge(.followers, owner: "me", usernames: ["a", "a", "B", "no way", ""], now: clock.wall), 2)
        XCTAssertEqual(scan.merge(.followers, owner: "me", usernames: ["a"], now: clock.wall), 0)
        XCTAssertEqual(scan.merge(.followers, owner: nil, usernames: ["c"], now: clock.wall), 0, "followers need an owner")
        scan.followers = Set((0..<FriendsScanState.maxPerList).map { "u\($0)" })
        XCTAssertEqual(scan.merge(.followers, owner: "me", usernames: ["new"], now: clock.wall), 0)
    }

    // MARK: Recipe

    func testBundledRecipeHasAValidFriendsFilter() throws {
        let r = try RecipeLibrary.bundled(.instagram)
        let f = try XCTUnwrap(r.friendsFilter)
        XCTAssertEqual(r.toggleDefault(f.toggle), true, "on by default once there's a list")
        XCTAssertEqual(f.feedPath(forceFollowing: true), "/?variant=following")
        let profile = try PathRegex(f.profileLink)
        XCTAssertEqual(profile.firstMatch("/alice/")?["user"], "alice")
        XCTAssertNil(profile.firstMatch("/alice/followers/"))
        XCTAssertTrue(f.reservedPaths.contains("explore"))
        XCTAssertEqual(try PathRegex(f.scanRoutes["followers"]!).firstMatch("/me/followers/")?["owner"], "me")
        XCTAssertNotNil(try PathRegex(f.scanRoutes["closeFriends"]!).firstMatch("/accounts/close_friends/"))
    }

    func testValidatorRejectsABrokenFriendsFilter() throws {
        var r = try RecipeLibrary.bundled(.instagram)
        r.friendsFilter?.toggle = "nope"
        r.friendsFilter?.storyRoute = "^/stories/[^/]+/"
        r.friendsFilter?.post = "article{}"
        r.friendsFilter?.caughtUpAfter = 0
        XCTAssertThrowsError(try RecipeValidator.validate(r)) { e in
            let problems = (e as? RecipeValidationError)?.problems ?? []
            XCTAssertTrue(problems.contains { $0.contains("unknown toggle nope") })
            XCTAssertTrue(problems.contains { $0.contains("storyRoute needs a `user` group") })
            XCTAssertTrue(problems.contains { $0.contains("post: invalid selector") })
            XCTAssertTrue(problems.contains { $0.contains("caughtUpAfter") })
        }
    }
}
