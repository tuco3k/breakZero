import Foundation
import XCTest
@testable import Core

final class RecipeTests: XCTestCase {
    func testBundledRecipesDecodeAndValidate() throws {
        for platform in Platform.allCases {
            let recipe = try RecipeLibrary.bundled(platform)
            XCTAssertEqual(recipe.platform, platform.rawValue)
            XCTAssertLessThanOrEqual(recipe.minEngine, recipeEngineVersion)
        }
    }

    func testEveryToggleIsUsed() throws {
        for platform in Platform.allCases {
            let r = try RecipeLibrary.bundled(platform)
            let used = Set(r.routes.map(\.toggle) + r.hide.map(\.toggle) + r.heuristics.map(\.toggle)
                + r.behaviors.map(\.toggle) + r.canaries.map(\.toggle) + r.resourceBlocks.map(\.toggle))
            for t in r.toggles {
                XCTAssertTrue(used.contains(t.id), "\(platform): toggle \(t.id) controls nothing")
            }
        }
    }

    func testValidatorRejectsBadRecipes() throws {
        let good = try RecipeLibrary.bundled(.instagram)

        var r = good
        r.minEngine = recipeEngineVersion + 1
        XCTAssertThrowsError(try RecipeValidator.validate(r))

        r = good
        r.routes.append(.init(id: "x", toggle: "ig.blockReels", pattern: "^/(?i)reels", action: .block))
        XCTAssertThrowsError(try RecipeValidator.validate(r))

        r = good
        r.routes.append(.init(id: "x", toggle: "nope", pattern: "^/a", action: .block))
        XCTAssertThrowsError(try RecipeValidator.validate(r))

        r = good
        r.routes.append(.init(id: "x", toggle: "ig.blockReels", pattern: "/unanchored", action: .block))
        XCTAssertThrowsError(try RecipeValidator.validate(r))

        r = good
        r.routes.append(.init(id: "x", toggle: "ig.blockReels", pattern: "^/a/(?<id>[0-9]+)", action: .redirect, to: "/b/{other}"))
        XCTAssertThrowsError(try RecipeValidator.validate(r))

        r = good
        r.routes.append(.init(id: "x", toggle: "ig.blockReels", pattern: "^/a/(", action: .block))
        XCTAssertThrowsError(try RecipeValidator.validate(r))

        r = good
        r.hide.append(.init(id: "x", toggle: "ig.hideFeed", selector: "a{color:red} b"))
        XCTAssertThrowsError(try RecipeValidator.validate(r))

        r = good
        r.hosts = ["Evil.COM"]
        XCTAssertThrowsError(try RecipeValidator.validate(r))

        r = good
        r.routes.append(r.routes[0])
        XCTAssertThrowsError(try RecipeValidator.validate(r), "duplicate ids")
    }

    func testDecodingDefaultsOptionalArrays() throws {
        let json = #"{"platform":"x","version":1,"minEngine":1,"hosts":["x.com"],"landing":{"default":"a","options":{"a":"/"}}}"#
        let r = try RecipeLibrary.decode(Data(json.utf8))
        XCTAssertTrue(r.routes.isEmpty)
        XCTAssertNoThrow(try RecipeValidator.validate(r))
    }

    func testBestPrefersNewerValidDownload() throws {
        let bundled = try RecipeLibrary.bundled(.youtube)
        var newer = bundled
        newer.version += 1
        XCTAssertEqual(RecipeLibrary.best(bundled: bundled, downloaded: newer).version, bundled.version + 1)

        var older = bundled
        older.version -= 1
        XCTAssertEqual(RecipeLibrary.best(bundled: bundled, downloaded: older), bundled)

        var broken = newer
        broken.hosts = []
        XCTAssertEqual(RecipeLibrary.best(bundled: bundled, downloaded: broken), bundled)

        var other = newer
        other.platform = "instagram"
        XCTAssertEqual(RecipeLibrary.best(bundled: bundled, downloaded: other), bundled)
    }

    func testActiveRecipeFiltersToggles() throws {
        let recipe = try RecipeLibrary.bundled(.youtube)
        let defaults = try ActiveRecipe(recipe: recipe)
        XCTAssertFalse(defaults.recipe.hide.contains { $0.id == "yt.hide.comments" }, "hide comments is opt-in")
        let withComments = try ActiveRecipe(recipe: recipe, settings: .init(toggles: ["yt.hideComments": true]))
        XCTAssertTrue(withComments.recipe.hide.contains { $0.id == "yt.hide.comments" })
        let noShorts = try ActiveRecipe(recipe: recipe, settings: .init(toggles: ["yt.hideShorts": false]))
        XCTAssertFalse(noShorts.recipe.canaries.contains { $0.id == "yt.canary.shortsLinks" },
                       "a canary must switch off with the rule it verifies")
    }

    func testCustomRulesAreValidated() throws {
        let recipe = try RecipeLibrary.bundled(.instagram)
        XCTAssertThrowsError(try ActiveRecipe(recipe: recipe, settings: .init(customBlocks: ["/(unclosed"])))
        let ok = try ActiveRecipe(recipe: recipe, settings: .init(customBlocks: ["/stories/"], customHides: ["div.x"]))
        XCTAssertEqual(ok.recipe.routes.first?.pattern, "^/stories/")
        XCTAssertEqual(ok.recipe.hide.last?.selector, "div.x")
    }

    func testHostPattern() {
        XCTAssertTrue(HostPattern.matches("youtube.com", host: "YouTube.com"))
        XCTAssertFalse(HostPattern.matches("youtube.com", host: "m.youtube.com"))
        XCTAssertTrue(HostPattern.matches("*.youtube.com", host: "m.youtube.com"))
        XCTAssertFalse(HostPattern.matches("*.youtube.com", host: "youtube.com"))
        XCTAssertFalse(HostPattern.matches("*.youtube.com", host: "evilyoutube.com"))
        XCTAssertFalse(HostPattern.isValid("*"))
        XCTAssertFalse(HostPattern.isValid("localhost"))
    }

    func testNamedGroups() {
        XCTAssertEqual(PathRegex.namedGroups(in: #"^/(?<a>x)/\(?<no>/(?<b>y)"#), ["a", "b"])
    }
}

final class ContentRuleListTests: XCTestCase {
    func testTranslatesBlockRoutes() throws {
        let active = try ActiveRecipe(recipe: RecipeLibrary.bundled(.instagram))
        let rules = ContentRuleListBuilder.rules(for: active)
        let filters = rules.map(\.trigger.urlFilter)
        XCTAssertTrue(filters.contains(#"^https?://www\.instagram\.com/explore(/|$)"#) == false, "alternation must be skipped")
        XCTAssertTrue(filters.contains(#"^https?://www\.instagram\.com/reels/audio/"#))
        for rule in rules {
            XCTAssertTrue(ContentRuleListBuilder.isWebKitCompatible(rule.trigger.urlFilter), rule.trigger.urlFilter)
            XCTAssertEqual(rule.trigger.resourceType, ["document"])
        }
    }

    func testUrlFilterTranslation() {
        XCTAssertEqual(ContentRuleListBuilder.urlFilter(forPathPattern: "^/shorts/?$", host: "m.youtube.com"),
                       #"^https?://m\.youtube\.com/shorts/?([?#].*)?$"#)
        XCTAssertEqual(ContentRuleListBuilder.urlFilter(forPathPattern: "^/a/(?<id>[a-z]+)", host: "*.x.com"),
                       #"^https?://[^/]*\.x\.com/a/([a-z]+)"#)
        XCTAssertNil(ContentRuleListBuilder.urlFilter(forPathPattern: "^/(a|b)", host: "x.com"))
        XCTAssertNil(ContentRuleListBuilder.urlFilter(forPathPattern: "^/a{2}", host: "x.com"))
    }

    func testJSONIsNeverEmpty() throws {
        var recipe = try RecipeLibrary.bundled(.youtube)
        recipe.routes.removeAll { $0.action == .block }
        let json = try ContentRuleListBuilder.json(for: ActiveRecipe(recipe: recipe))
        XCTAssertTrue(json.contains("bz-inert"))
        let full = try ContentRuleListBuilder.json(for: ActiveRecipe(recipe: RecipeLibrary.bundled(.youtube)))
        XCTAssertTrue(full.contains(#""url-filter""#))
        XCTAssertTrue(full.contains(#""resource-type":["document"]"#))
    }
}

final class SessionDetectorTests: XCTestCase {
    func testInstagramSession() throws {
        let r = try RecipeLibrary.bundled(.instagram)
        XCTAssertTrue(SessionDetector.isSignedIn(r, cookies: [.init(name: "sessionid", domain: ".instagram.com")]))
        XCTAssertFalse(SessionDetector.isSignedIn(r, cookies: [.init(name: "csrftoken", domain: ".instagram.com")]))
        XCTAssertFalse(SessionDetector.isSignedIn(r, cookies: [.init(name: "sessionid", domain: ".example.com")]))
        XCTAssertFalse(SessionDetector.isSignedIn(r, cookies: [.init(name: "sessionid", domain: "com")]), "a bare TLD never matches")
        XCTAssertFalse(SessionDetector.isSignedIn(r, cookies: []))
    }

    func testYouTubeSessionViaGoogleOrYouTubeCookie() throws {
        let r = try RecipeLibrary.bundled(.youtube)
        XCTAssertTrue(SessionDetector.isSignedIn(r, cookies: [.init(name: "LOGIN_INFO", domain: ".youtube.com")]))
        XCTAssertTrue(SessionDetector.isSignedIn(r, cookies: [.init(name: "SID", domain: ".google.com")]), "accounts.google.com is an auth host")
        XCTAssertFalse(SessionDetector.isSignedIn(r, cookies: [.init(name: "VISITOR_INFO1_LIVE", domain: ".youtube.com")]))
    }
}
