import Foundation
import XCTest
@testable import Core

/// Instagram search modes (QUESTIONS #58–60).
final class SearchModeTests: XCTestCase {
    func active(_ s: PlatformSettings) throws -> ActiveRecipe {
        try ActiveRecipe(recipe: RecipeLibrary.bundled(.instagram), settings: s)
    }

    func testNormalIsTheDefault() throws {
        XCTAssertEqual(PlatformSettings().search, .normal)
        let a = try active(PlatformSettings())
        XCTAssertEqual(a.searchMode, .normal)
        XCTAssertTrue(a.recipe.routes.contains { $0.id == "ig.search.root" && $0.to == "/explore/search/" })
        XCTAssertFalse(a.recipe.hide.contains { $0.id == "ig.hide.exploreTab" }, "the search entry stays")
        XCTAssertFalse(a.recipe.heuristics.contains { $0.id == "ig.heur.exploreLinks" })
        XCTAssertTrue(a.recipe.heuristics.contains { $0.id == "ig.search.grid" })
        XCTAssertTrue(a.recipe.canaries.contains { $0.id.hasPrefix("ig.search.gridCanary") })
    }

    func testOffIsTheOldBehavior() throws {
        let a = try active(PlatformSettings(searchMode: .off))
        XCTAssertEqual(a.searchMode, .off)
        XCTAssertFalse(a.recipe.routes.contains { $0.id == "ig.search.root" })
        XCTAssertTrue(a.recipe.hide.contains { $0.id == "ig.hide.exploreTab" })
        let engine = try RuleEngine(active: a)
        var s = NavigationState()
        XCTAssertEqual(engine.decide(url: URL(string: "https://www.instagram.com/explore/")!, from: nil, state: &s),
                       .redirect(to: "/direct/inbox/", reason: .blocked(ruleID: "ig.route.explore")))
    }

    func testModesDontApplyWithExploreUnblocked() throws {
        let a = try active(PlatformSettings(toggles: ["ig.blockExplore": false], searchMode: .off))
        XCTAssertNil(a.searchMode)
        XCTAssertFalse(a.recipe.routes.contains { $0.id.hasPrefix("ig.search") })
    }

    func testCooldownOrderOffMatchingNormal() {
        let ratchet = Ratchet(recipes: [try! RecipeLibrary.bundled(.instagram)])
        var policy = WallPolicy(lockEnabled: true)
        XCTAssertEqual(ratchet.classify(.setSearchMode(.instagram, .matching), against: policy), .tightening)
        XCTAssertEqual(ratchet.classify(.setSearchMode(.instagram, .off), against: policy), .tightening)
        XCTAssertEqual(ratchet.classify(.setSearchMode(.instagram, .normal), against: policy), .neutral)
        policy.platformSettings[.instagram] = PlatformSettings(searchMode: .off)
        XCTAssertEqual(ratchet.classify(.setSearchMode(.instagram, .matching), against: policy), .loosening)
        XCTAssertEqual(ratchet.classify(.setSearchMode(.instagram, .normal), against: policy), .loosening)
        var lock = LockState()
        let clock = FakeClock()
        lock.ledger.record(clock.sample)
        guard case .queued = ratchet.submit([.setSearchMode(.instagram, .normal)], policy: &policy, lock: &lock, at: clock.sample)[0] else {
            return XCTFail("opening search up waits the cooldown")
        }
        XCTAssertEqual(policy.settings(for: .instagram).search, .off)
    }

    func testSavedSettingsWithoutSearchModeLoadAsNormal() throws {
        let s = try JSONDecoder().decode(PlatformSettings.self, from: Data(#"{"toggles":{}}"#.utf8))
        XCTAssertEqual(s.search, .normal)
    }
}
