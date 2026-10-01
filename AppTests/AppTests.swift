// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
import Core
import XCTest
@testable import breakZero

final class AppTests: XCTestCase {
    /// Every recipe toggle needs a human title; raw ids must never reach the UI.
    func testEveryToggleHasATitle() throws {
        for p in Platform.allCases {
            let recipe = try RecipeLibrary.bundled(p)
            for t in recipe.toggles {
                XCTAssertNotEqual(ToggleTitles.title(t.id), t.id, "missing title for \(t.id)")
            }
            for key in recipe.landing.options.keys {
                XCTAssertNotEqual(ToggleTitles.landing(key), key, "missing landing title for \(key)")
            }
        }
    }
}

/// The import path a user hits from the Feed rules screen, end to end in the app: a real export
/// zip (3,000 accounts) → people data → active feed rules for the Instagram view.
@MainActor
final class ImportFlowTests: XCTestCase {
    func testImportingAnExportTurnsOnTheMutualsRule() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ig-export-3000", withExtension: "zip"))
        let model = AppModel(launchedAt: Date())
        let start = Date()
        let summary = try await model.importExport([url])
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(summary, .init(mutuals: 800, following: 1900, followers: 1800, closeFriends: nil))
        XCTAssertEqual(model.people.mutuals.count, 800)
        XCTAssertEqual(model.people.source, .export)
        XCTAssertEqual(model.people.daysSinceUpdate(now: Date()), 0)
        // With the rule on Mutuals, the Instagram view now filters by those 800.
        if model.igSettings.audience(.feed) != .mutuals { model.submit([.setAudience(.instagram, .feed, .mutuals)]) }
        let friends = try XCTUnwrap(model.activeRecipe(.instagram)?.friends)
        XCTAssertEqual(friends.feed?.count, 800 + model.igSettings.feedRules.always.count)
        XCTAssertTrue(friends.allows(.feed, "user_1500"), "followed and following back")
        XCTAssertFalse(friends.allows(.feed, "user_2500"), "followed only")
    }

    func testAnHTMLExportIsExplainedPlainly() {
        XCTAssertTrue(ImportExportView.describe(ExportImporter.Failure.htmlExport).contains("JSON"))
    }
}
