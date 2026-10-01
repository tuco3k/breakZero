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

    func testUnreadBadge() {
        XCTAssertEqual(UnreadBadge.count(fromTitle: "(3) Instagram"), 3)
        XCTAssertEqual(UnreadBadge.count(fromTitle: "(99+) Instagram"), 99)
        XCTAssertNil(UnreadBadge.count(fromTitle: "Instagram"))
        XCTAssertNil(UnreadBadge.count(fromTitle: "(Beta) Instagram"))
        XCTAssertNil(UnreadBadge.count(fromTitle: nil))
    }

    func testMediaMessages() {
        XCTAssertEqual(LiteMessage.parse(["type": "media", "event": "error", "kind": "video", "code": 2, "source": "blob"]),
                       .media(event: "error", kind: "video", code: 2, source: "blob"))
        XCTAssertNil(LiteMessage.parse(["type": "media", "event": "seeked"]), "only the three diagnostic events")
        XCTAssertEqual(LiteMessage.parse(["type": "media", "event": "playing", "source": "https://x"]),
                       .media(event: "playing", kind: "video", code: nil, source: "none"), "never a URL")
        XCTAssertEqual(MediaDiagnostics.describe(event: "error", kind: "video", code: 2, source: "blob"),
                       "video error code 2 (MEDIA_ERR_NETWORK: network error while loading (VPN, blocked host, offline)) source=blob")
    }

    func testViolationMessages() {
        XCTAssertEqual(LiteMessage.parse(["type": "violation", "reason": "outOfScope", "ruleID": "ig.route.reelOnce"]),
                       .violation(.init(reason: "outOfScope", detail: nil, ruleID: "ig.route.reelOnce", source: .page)))
        XCTAssertEqual(LiteMessage.parse(["type": "violation", "reason": "limit", "detail": "dailyLimit"]),
                       .violation(.init(reason: "limit", detail: "dailyLimit", ruleID: nil, source: .page)))
        XCTAssertEqual(LiteMessage.parse(["type": "violation", "reason": "limit", "detail": "<b>"]),
                       .violation(.init(reason: "limit", detail: nil, ruleID: nil, source: .page)), "unknown detail dropped")
        XCTAssertNil(LiteMessage.parse(["type": "violation", "reason": "whatever"]))
    }

    func testLimitsReachThePage() throws {
        let active = try ActiveRecipe(recipe: RecipeLibrary.bundled(.instagram))
        let json = try LiteScriptBuilder.configJSON(active: active, state: .init(), strings: strings, previousHref: nil,
                                                    limits: .init(blocked: "schedule"))
        XCTAssertTrue(json.contains(#""limits":{"blocked":"schedule"}"#))
        let update = try LiteScriptBuilder.updateScript(active: active, limits: .none)
        XCTAssertTrue(update.hasPrefix("window.__bzUpdate && window.__bzUpdate({"))
        XCTAssertTrue(update.contains(#""limits":{}"#) || update.contains(#""limits":{"blocked":null}"#))
    }

    /// QUESTIONS #27: the video you open may play (no extra tap), but chains stay blocked: the
    /// default YouTube recipe still carries the autoplay guard. (Its behavior — finishing a video
    /// never advances — is tested in jstests/watchdog.test.js and dom.test.js.)
    func testChosenVideoPlaysButAutoplayChainsStayBlocked() throws {
        for p in Platform.allCases {
            XCTAssertFalse(PlaybackPolicy.requiresUserGesture(p), "\(p): a video you open must be able to play")
        }
        let active = try ActiveRecipe(recipe: RecipeLibrary.bundled(.youtube))
        let guardRule = try XCTUnwrap(active.recipe.behaviors.first { $0.type == .blockAutoAdvance },
                                      "the autoplay guard is on by default")
        XCTAssertEqual(guardRule.toggle, "yt.autoplayOff")
        XCTAssertEqual(guardRule.param, "v")
        XCTAssertEqual(guardRule.routes, ["^/watch"])
        // The guard ships inside the script the page gets.
        let script = try LiteScriptBuilder.userScript(filterSource: "", active: active, state: .init(),
                                                      strings: strings, previousHref: nil)
        XCTAssertTrue(script.contains(#""type":"blockAutoAdvance""#))
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
