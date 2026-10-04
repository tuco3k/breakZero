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

/// "What is the Wall?" (QUESTIONS #63): plain words, built from real settings and the build.
final class WallExplainerTests: XCTestCase {
    let jargon = ["loosen", "tighten", "ratchet", "managedsettings", "familycontrols", "shield"]

    func facts(screenTime: Bool, iOS: (Int, Int) = (26, 2), cooldown: TimeInterval = 86400, grace: TimeInterval = 600) -> WallExplainer.Facts {
        .init(cooldown: cooldown, grace: grace, lockOn: false, pass: PassRules(), screenTimeBuild: screenTime, iOS: iOS)
    }

    func testNoJargonAndWallOnlyAsTheName() {
        for st in [false, true] {
            let e = WallExplainer.make(facts(screenTime: st))
            for line in e.allText + WallExplainer.confirmation(facts(screenTime: st)) {
                let lower = line.lowercased()
                for word in jargon { XCTAssertFalse(lower.contains(word), "\(word) in: \(line)") }
                let withoutName = line.replacingOccurrences(of: "the Wall", with: "").replacingOccurrences(of: "The Wall", with: "")
                XCTAssertFalse(withoutName.lowercased().contains("wall"), "explains with \"wall\": \(line)")
            }
        }
    }

    func testUsesTheRealCooldownAndUndoTime() {
        let e = WallExplainer.make(facts(screenTime: false, cooldown: 3 * 86400, grace: 300))
        let text = e.allText.joined(separator: " ")
        XCTAssertTrue(text.contains(WallExplainer.duration(3 * 86400)), text)
        XCTAssertTrue(text.contains(WallExplainer.duration(300)))
        let noUndo = WallExplainer.make(facts(screenTime: false, grace: 0)).allText.joined(separator: " ")
        XCTAssertTrue(noUndo.contains("can't be undone instantly"))
        XCTAssertTrue(WallExplainer.confirmation(facts(screenTime: false, cooldown: 3600)).joined().contains(WallExplainer.duration(3600)))
    }

    func testCantStopMatchesTheBuildAndIOS() {
        let lite = WallExplainer.make(facts(screenTime: false)).allText.joined(separator: " ")
        XCTAssertTrue(lite.contains("deleting breakZero removes the Lock"))
        XCTAssertFalse(lite.contains("Face ID"))
        let oldIOS = WallExplainer.make(facts(screenTime: true, iOS: (26, 2))).allText.joined(separator: " ")
        XCTAssertTrue(oldIOS.contains("iOS 26.2"))
        XCTAssertTrue(oldIOS.contains("Face ID or your passcode"))
        XCTAssertFalse(oldIOS.contains("deleting breakZero removes"))
        let newIOS = WallExplainer.make(facts(screenTime: true, iOS: (26, 4))).allText.joined(separator: " ")
        XCTAssertTrue(newIOS.contains("Screen Time passcode"))
    }

    func testEveryToggleHasAPlainDescription() throws {
        for p in Platform.allCases {
            for t in try RecipeLibrary.bundled(p).toggles {
                XCTAssertFalse(ToggleTitles.detail(t.id).isEmpty, "missing description for \(t.id)")
            }
        }
    }
}
