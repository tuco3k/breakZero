import Foundation
import XCTest
@testable import Core

final class NetworkPolicyTests: XCTestCase {
    func policy(updates: Bool) throws -> NetworkPolicy {
        NetworkPolicy(recipes: [try RecipeLibrary.bundled(.instagram), try RecipeLibrary.bundled(.youtube)],
                      recipeUpdatesEnabled: updates)
    }

    func testWebNavigationAllowlist() throws {
        let p = try policy(updates: false)
        XCTAssertTrue(p.allows(URL(string: "https://www.instagram.com/direct/inbox/")!, for: .webNavigation))
        XCTAssertTrue(p.allows(URL(string: "https://m.youtube.com/")!, for: .webNavigation))
        XCTAssertTrue(p.allows(URL(string: "https://accounts.google.com/x")!, for: .webNavigation))
        XCTAssertFalse(p.allows(URL(string: "http://www.instagram.com/")!, for: .webNavigation), "https only")
        XCTAssertFalse(p.allows(URL(string: "https://example.com/")!, for: .webNavigation))
        XCTAssertFalse(p.allows(URL(string: "https://instagram.com.evil.com/")!, for: .webNavigation))
    }

    func testRecipeUpdatesOffByDefaultAndScopedToPrefix() throws {
        let off = try policy(updates: false)
        let base = NetworkPolicy.defaultRecipeUpdateBase
        XCTAssertFalse(off.allows(base.appendingPathComponent("instagram.json"), for: .recipeUpdate))

        let on = try policy(updates: true)
        XCTAssertTrue(on.allows(base.appendingPathComponent("instagram.json"), for: .recipeUpdate))
        XCTAssertFalse(on.allows(URL(string: "https://tuco3k.github.io/other/x.json")!, for: .recipeUpdate))
        XCTAssertFalse(on.allows(URL(string: "https://tuco3k.github.io/breakZero/recipes/../../x")!, for: .recipeUpdate))
        XCTAssertFalse(on.allows(URL(string: "https://evil.example/breakZero/recipes/x.json")!, for: .recipeUpdate))
        XCTAssertFalse(on.allows(URL(string: "https://www.instagram.com/")!, for: .recipeUpdate),
                       "platform hosts are for web views only")
    }

    func testFetchRefusesDisallowedURLWithoutNetwork() async throws {
        let off = try policy(updates: false)
        do {
            _ = try await off.fetchRecipeData(from: URL(string: "https://example.com/x.json")!)
            XCTFail("should refuse")
        } catch let e as NetworkPolicy.Denied {
            XCTAssertEqual(e, .notAllowed("https://example.com/x.json"))
        }
    }

    /// Enforces the single choke point: no other source file may touch networking APIs.
    func testNoNetworkingOutsideNetworkPolicy() throws {
        let root = repoRoot()
        let forbidden = ["URLSession", "NSURLConnection", "import Network", "CFNetwork", "URLSessionWebSocketTask",
                         "NWConnection", "CFStream"]
        let scanDirs = ["App", "Extensions", "Packages/BreakZeroKit/Sources"].map { root.appendingPathComponent($0) }
        var scanned = 0
        var offenders: [String] = []
        for dir in scanDirs {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                scanned += 1
                if url.lastPathComponent == "NetworkPolicy.swift" { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for word in forbidden where text.contains(word) {
                    offenders.append("\(url.path): \(word)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 5, "scanner found no sources; is the repo layout intact?")
        XCTAssertEqual(offenders, [])
    }

    func repoRoot() -> URL {
        // .../Packages/BreakZeroKit/Tests/CoreTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}

final class SharedStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bz-store-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReadMissingIsNil() throws {
        let s = SharedStore(directory: dir)
        XCTAssertNil(try s.read(WallPolicy.self, AppGroup.File.policy))
    }

    func testWriteReadUpdate() throws {
        let s = SharedStore(directory: dir)
        var p = WallPolicy()
        p.cooldown = 7200
        try s.write(p, AppGroup.File.policy)
        XCTAssertEqual(try s.read(WallPolicy.self, AppGroup.File.policy), p)
        let r = try s.update(AppGroup.File.policy, default: WallPolicy()) { (p: inout WallPolicy) -> Int in
            p.pass.dailyCap = 1
            return 42
        }
        XCTAssertEqual(r, 42)
        XCTAssertEqual(try s.read(WallPolicy.self, AppGroup.File.policy)?.pass.dailyCap, 1)
    }

    func testConcurrentUpdatesDontLoseWrites() throws {
        let s = SharedStore(directory: dir)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            try? s.update("counter.json", default: 0) { (n: inout Int) in n += 1 }
        }
        XCTAssertEqual(try s.read(Int.self, "counter.json"), 50)
    }

    func testDiagnosticsLogIsCapped() {
        let s = SharedStore(directory: dir)
        for i in 0..<(DiagnosticsLog.maxEntries + 5) {
            DiagnosticsLog.append(s, source: "test", "m\(i)")
        }
        let e = DiagnosticsLog.entries(s)
        XCTAssertEqual(e.count, DiagnosticsLog.maxEntries)
        XCTAssertEqual(e.last?.message, "m\(DiagnosticsLog.maxEntries + 4)")
        DiagnosticsLog.clear(s)
        XCTAssertTrue(DiagnosticsLog.entries(s).isEmpty)
    }
}
