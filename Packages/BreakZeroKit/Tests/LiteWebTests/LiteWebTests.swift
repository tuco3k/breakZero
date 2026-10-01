import Core
import Foundation
import XCTest
@testable import LiteWeb

final class LiteScriptBuilderTests: XCTestCase {
    let strings = LiteStrings(needsUpdate: "Filter needs an update", report: "Report")

    func testFilterScriptIsBundled() throws {
        let src = try LiteScriptBuilder.filterSource()
        XCTAssertTrue(src.contains("function install(win, config, hooks)"))
        XCTAssertTrue(src.contains("ENGINE = \(recipeEngineVersion)"), "script engine version must match Core")
    }

    func testUserScriptEmbedsConfigAndGuardsInstall() throws {
        let active = try ActiveRecipe(recipe: RecipeLibrary.bundled(.instagram))
        let state = NavigationState(grant: .init(ruleID: "ig.route.reelOnce", key: "A", returnTo: "/direct/t/1/"))
        let src = try LiteScriptBuilder.userScript(filterSource: "/*filter*/", active: active, state: state,
                                                   strings: strings, previousHref: "https://www.instagram.com/direct/t/1/")
        XCTAssertTrue(src.contains("/*filter*/"))
        XCTAssertTrue(src.contains("window.__bzFilter.install(window, {"))
        XCTAssertTrue(src.contains("window.__bzInstalled"))
        XCTAssertTrue(src.contains(#""landingPath":"/direct/inbox/""#))
        XCTAssertTrue(src.contains(#""returnTo":"/direct/t/1/""#))
    }

    func testConfigJSONEscapesScriptBreakers() throws {
        var recipe = try RecipeLibrary.bundled(.youtube)
        recipe.platform = "youtube"
        let active = try ActiveRecipe(recipe: recipe)
        let s = LiteStrings(needsUpdate: "a</script>b\u{2028}c", report: "r")
        let json = try LiteScriptBuilder.configJSON(active: active, state: .init(), strings: s, previousHref: nil)
        XCTAssertFalse(json.contains("</script>"))
        XCTAssertFalse(json.contains("\u{2028}"))
        XCTAssertTrue(json.contains("a<\\/script>b\\u2028c"))
    }

    func testReportURLCarriesOnlyIDsAndVersions() throws {
        let url = try XCTUnwrap(LiteScriptBuilder.reportURL(platform: "instagram", recipeVersion: 3,
                                                            canaryIDs: ["ig.canary.reelsTab", "<script>"], appVersion: "0.1", osVersion: "26.4"))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://github.com/tuco3k/breakZero/issues/new?"))
        XCTAssertTrue(s.contains("ig.canary.reelsTab"))
        XCTAssertFalse(s.contains("<script>"))
        XCTAssertFalse(s.contains("%3Cscript"))
    }

    func testStableHash() {
        XCTAssertEqual(LiteScriptBuilder.stableHash(""), "cbf29ce484222325")
        XCTAssertEqual(LiteScriptBuilder.stableHash("a"), "af63dc4c8601ec8c")
    }

    func testMessageParsingValidates() {
        XCTAssertEqual(LiteMessage.parse(["type": "route", "href": "https://www.instagram.com/x/", "state": ["grant": NSNull()]]),
                       .route(href: "https://www.instagram.com/x/", state: NavigationState(grant: nil)))
        XCTAssertEqual(LiteMessage.parse(["type": "route", "href": "h",
                                          "state": ["grant": ["ruleID": "r", "key": "k", "returnTo": "https://evil.example/"]]]),
                       .route(href: "h", state: NavigationState(grant: nil)), "returnTo must be a path")
        XCTAssertEqual(LiteMessage.parse(["type": "report", "ids": ["a", 3, "b"]]), .report(ids: ["a", "b"]))
        XCTAssertNil(LiteMessage.parse(["type": "openURL", "url": "https://evil.example/"]))
        XCTAssertNil(LiteMessage.parse("nope"))
    }
}
