import Foundation
import XCTest
@testable import Core

struct RouteVectors: Decodable {
    struct Sequence: Decodable {
        var name: String
        var platform: String
        var settings: PlatformSettings?
        var signedIn: Bool?
        var shortForm: ShortFormMode?
        var steps: [Step]
    }

    struct Step: Decodable {
        var url: String
        var expect: String
        var fresh: Bool?
    }

    var sequences: [Sequence]

    static func load() throws -> RouteVectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "route-vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(RouteVectors.self, from: Data(contentsOf: url))
    }
}

final class RuleEngineTests: XCTestCase {
    func testSharedRouteVectors() throws {
        let vectors = try RouteVectors.load()
        XCTAssertFalse(vectors.sequences.isEmpty)
        for seq in vectors.sequences {
            let platform = try XCTUnwrap(Platform(rawValue: seq.platform))
            let active = try ActiveRecipe(recipe: RecipeLibrary.bundled(platform), settings: seq.settings ?? .default,
                                          signedIn: seq.signedIn ?? true, shortForm: seq.shortForm ?? .togglesDecide)
            let engine = try RuleEngine(active: active)
            var state = NavigationState()
            var current: URL?
            for (i, step) in seq.steps.enumerated() {
                let url = try XCTUnwrap(URL(string: step.url), step.url)
                if step.fresh == true { current = nil; state = NavigationState() }
                let decision = engine.decide(url: url, from: current, state: &state)
                let got: String
                switch decision {
                case .allow:
                    got = "allow"
                    current = url
                case let .redirect(to, _):
                    got = "redirect:" + to
                    var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    let parts = to.split(separator: "?", maxSplits: 1).map(String.init)
                    c.percentEncodedPath = parts[0]
                    c.percentEncodedQuery = parts.count > 1 ? parts[1] : nil
                    current = c.url
                case .openExternally:
                    got = "external"
                }
                XCTAssertEqual(got, step.expect, "\(seq.name) step \(i): \(step.url)")
            }
        }
    }

    func testRedirectNeverTargetsCurrentPage() throws {
        // A recipe whose block lands on itself must not loop.
        var recipe = try RecipeLibrary.bundled(.instagram)
        recipe.routes.insert(.init(id: "loop", toggle: "ig.blockReels", pattern: "^/direct/inbox/$", action: .block), at: 0)
        let engine = try RuleEngine(active: ActiveRecipe(recipe: recipe))
        var state = NavigationState()
        XCTAssertEqual(engine.decide(url: URL(string: "https://www.instagram.com/direct/inbox/")!, from: nil, state: &state), .allow)
    }

    func testAllowZones() throws {
        let engine = try RuleEngine(active: ActiveRecipe(recipe: RecipeLibrary.bundled(.instagram)))
        XCTAssertTrue(engine.isAllowZone(path: "/direct/t/123/"))
        XCTAssertTrue(engine.isAllowZone(path: "/accounts/login/"))
        XCTAssertTrue(engine.isAllowZone(path: "/challenge/abc/"))
        XCTAssertFalse(engine.isAllowZone(path: "/"))
        XCTAssertFalse(engine.isAllowZone(path: "/someone/"))
    }

    func testCaptureEncoding() {
        XCTAssertEqual(RuleEngine.encodeComponent("abc-_.~@"), "abc-_.~@")
        XCTAssertEqual(RuleEngine.encodeComponent("a&b=c"), "a%26b%3Dc")
    }

    func testBounceReasonsAreReported() throws {
        let engine = try RuleEngine(active: ActiveRecipe(recipe: RecipeLibrary.bundled(.instagram)))
        var state = NavigationState()
        let thread = URL(string: "https://www.instagram.com/direct/t/1/")!
        let a = URL(string: "https://www.instagram.com/reel/A/")!
        let b = URL(string: "https://www.instagram.com/reel/B/")!
        XCTAssertEqual(engine.decide(url: a, from: thread, state: &state), .allow)
        XCTAssertEqual(state.grant?.key, "A")
        XCTAssertEqual(engine.decide(url: b, from: a, state: &state),
                       .redirect(to: "/direct/t/1/", reason: .bounced(ruleID: "ig.route.reelOnce")))
        XCTAssertNil(state.grant)
    }
}
