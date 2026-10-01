// UNVERIFIED: written on Linux, never compiled. Build on a Mac first (see PROGRESS.md).
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
