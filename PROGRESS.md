# Progress

Claude Code keeps this file current. Read it first in every session.

## Status
Phase 0 code-complete on Linux (waiting on owner: build on a Mac + spike results).
Phase 1 in progress: recipes, rule engine, all five filter layers and their tests are written;
the WebKit glue is UNVERIFIED.

Test status (Linux, Swift 6.0.3 + Node 22):
- `cd Packages/BreakZeroKit && swift test` → **61 tests pass** (Core, LiteWeb pure parts, Shielding with fakes).
- `cd jstests && npm ci && npm test` → **27 tests pass** (route vectors shared with Swift, DOM filters, guard, canaries, autoplay).

## Phase 0 task plan
- [x] P0.1 Read BRIEF/CLAUDE, draft `ARCHITECTURE.md`
- [x] P0.2 Swift toolchain on Linux (Ubuntu `swiftlang` 6.0.3 in a chroot; see Blockers)
- [x] P0.3 `Packages/BreakZeroKit`: Core / LiteWeb / Shielding products + tests
- [x] P0.4 `project.yml` (XcodeGen): App + ShieldConfiguration + ShieldAction + DeviceActivityMonitor, Development Family Controls entitlement, App Group — UNVERIFIED (not generated on a Mac yet)
- [x] P0.5 App shell: tab bar, Wall tab, hidden Diagnostics (tap version 5×) with S1–S7 + shared log — UNVERIFIED
- [x] P0.6 Extensions that read the App Group, reconcile the wall and log — UNVERIFIED
- [x] P0.7 `docs/ON_DEVICE_CHECKLIST.md`
- [x] P0.8 README, LICENSE (MIT), PRIVACY, SECURITY_MODEL, RECIPES, CONTRIBUTING, docs/QA
- [x] P0.9 CI: Linux `swift test` + Node tests on push; macOS build manual-only
- [ ] P0.10 (owner) build on Mac, run spikes, report → then update ARCHITECTURE.md

## Phase 1 progress
- [x] Instagram + YouTube recipes (`Core/Resources/Recipes/*.json`), validated by tests
- [x] Layer 1: `ContentRuleListBuilder` (WebKit dialect translation, tested); compile/attach in `LiteWebController` (UNVERIFIED)
- [x] Layer 2: `RuleEngine` (native, tested) + JS route guard (pushState/replaceState/popstate, prototype patch; tested) + native URL-change backstop (UNVERIFIED)
- [x] Reel-from-DM `allowOnce` state machine (Swift + JS, shared vectors)
- [x] Layer 3: route-scoped CSS at document start (tested)
- [x] Layer 4: MutationObserver + rAF heuristics, structural-container safety (tested)
- [x] Layer 5: canaries → blur + "Filter needs an update" + Report (prefilled GitHub issue, ids only) (tested in JS; native report UNVERIFIED)
- [x] Allow zones (no DOM work in DMs/login/compose) (tested)
- [x] YouTube autoplay guard (tested in JS) + tap-to-play for YouTube media (UNVERIFIED)
- [x] Persistent per-platform `WKWebsiteDataStore(forIdentifier:)`, process-termination reload (UNVERIFIED)
- [ ] Downloads → Photos; state restore via `interactionState` after process kill
- [ ] Unread counts on lite tabs (notifications option A)
- [ ] Real (scrubbed) HTML fixtures from a device; nightly Playwright canary (Phase 4)
- [ ] Owner on-device acceptance (docs/ON_DEVICE_CHECKLIST.md §D, docs/QA.md)

Wall/Phase 2–3 logic already written and tested ahead of schedule (pure Core/Shielding):
ratchet + pending queue, Hard Lock, trusted elapsed clock, pass ledger, WallEnforcer reconcile.

## Next
1. Owner: `docs/ON_DEVICE_CHECKLIST.md` steps 1–14; report spike results.
2. Phase 1 remaining items above (downloads, interactionState restore, unread counts).
3. Phase 2: onboarding (authorization → per-platform app picker → notification permission), pass request UI with wait screen.
4. After S1–S7 results: revise ARCHITECTURE.md §7 decisions.

## Unverified (written but never compiled or run)
Build these first on the Mac, in this order:
1. `project.yml` (never run through XcodeGen on macOS)
2. `Packages/BreakZeroKit/Sources/LiteWeb/LiteWebController.swift`
3. `Packages/BreakZeroKit/Sources/LiteWeb/LiteWebView.swift`
4. `Packages/BreakZeroKit/Sources/Shielding/ScreenTime.swift` (iOS-only; also needs device testing)
5. `App/Sources/BreakZeroApp.swift`
6. `App/Sources/AppModel.swift`
7. `App/Sources/RootView.swift`
8. `App/Sources/Wall/WallView.swift`
9. `App/Sources/Wall/RevocationView.swift`
10. `App/Sources/Diagnostics/DiagnosticsView.swift`
11. `Extensions/ShieldConfiguration/ShieldConfigurationExtension.swift`
12. `Extensions/ShieldAction/ShieldActionExtension.swift`
13. `Extensions/DeviceActivityMonitor/DeviceActivityMonitorExtension.swift`
14. `AppTests/AppTests.swift`
15. `.github/workflows/ci.yml` (not yet seen running)

Compiled and tested on Linux (Darwin-only branches inside them are UNVERIFIED):
`Core/*` (except the `#if canImport(Darwin)` paths in `TrustedClock.swift` and `SharedStore.swift`),
`LiteWeb/LiteWeb.swift`, `Shielding/Shielding.swift`, `bz-filter.js`.

## Blockers / blocked commands (log)
- `download.swift.org` is denied by the session's egress policy (403). Swift was installed instead from
  Ubuntu's own `swiftlang` package (6.0.3, questing) inside a debootstrapped Ubuntu chroot at
  `/opt/swiftroot` (dev-only tooling, never shipped).
- Blocked by the permission classifier (not retried): switching that chroot's apt source to the
  `resolute` suite (for Swift 6.2); bind-mounting the repo into the chroot; `add_repo` with push access.
  Tests run by copying the repo into the chroot (`rsync`, no mounts) and running `swift test` there.
- Initial `git push` failed (403, no GitHub App access). Owner fixed access; pushes work now.
- Rule from owner: if a command gets blocked, don't try privileged workarounds (e.g. mounts) — log it
  here and move on.
