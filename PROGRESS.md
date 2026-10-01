# Progress

Claude Code keeps this file current. Read it first in every session.

## Status
Phase 0 code-complete. Mac build verified 2026-10-01 (Xcode 27, iOS 27 SDK): both variants
compile with no errors or source warnings, all tests pass, and the lite app signs with the owner's
free Personal Team. Waiting on owner: install on the iPhone + spike results.
Phase 1 in progress: recipes, rule engine, all five filter layers and their tests are written;
the WebKit glue compiles but hasn't run on a device.

Test status (Linux, Swift 6.0.3 + Node 22):
- `cd Packages/BreakZeroKit && swift test` → **62 tests pass** (Core, LiteWeb pure parts, Shielding with fakes).
- `cd jstests && npm ci && npm test` → **27 tests pass** (route vectors shared with Swift, DOM filters, guard, canaries, autoplay).

Test status (macOS, Xcode 27, iPhone 17 Pro Simulator iOS 26.2), `xcodebuild … CODE_SIGNING_ALLOWED=NO build test`:
- **63 tests pass**: CoreTests 50, LiteWebTests 7, ShieldingTests 5, breakZeroTests 1.

## Phase 0 task plan
- [x] P0.1 Read BRIEF/CLAUDE, draft `ARCHITECTURE.md`
- [x] P0.2 Swift toolchain on Linux (Ubuntu `swiftlang` 6.0.3 in a chroot; see Blockers)
- [x] P0.3 `Packages/BreakZeroKit`: Core / LiteWeb / Shielding products + tests
- [x] P0.4 `project.yml` (XcodeGen): App + ShieldConfiguration + ShieldAction + DeviceActivityMonitor, Development Family Controls entitlement, App Group — `xcodegen generate` (2.44.1, built from source on Linux) succeeds: 5 targets, package products linked, 3 extensions embedded, scheme runs package tests. Not yet opened/built in Xcode.
- [x] P0.5 App shell: tab bar, Wall tab, hidden Diagnostics (tap version 5×) with S1–S7 + shared log — UNVERIFIED
- [x] P0.6 Extensions that read the App Group, reconcile the wall and log — UNVERIFIED
- [x] P0.7 `docs/ON_DEVICE_CHECKLIST.md`
- [x] P0.8 README, LICENSE (MIT), PRIVACY, SECURITY_MODEL, RECIPES, CONTRIBUTING, docs/QA
- [x] P0.9 CI: Linux `swift test` + Node tests on push (green on GitHub Actions); macOS build manual-only (never run)
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
- [x] Downloads → Photos (add-only), state restore via `interactionState` after process kill (UNVERIFIED)
- [x] Unread counts on lite tabs from the page title's digits (parser tested; badge UNVERIFIED)
- [ ] Real (scrubbed) HTML fixtures from a device; nightly Playwright canary (Phase 4)
- [ ] Owner on-device acceptance (docs/ON_DEVICE_CHECKLIST.md §D, docs/QA.md)

Wall/Phase 2–3 logic already written and tested ahead of schedule (pure Core/Shielding):
ratchet + pending queue, Hard Lock, trusted elapsed clock, pass ledger, WallEnforcer reconcile.

## Build switch
- [x] `BZ_SCREEN_TIME` is a **generate-time** switch (QUESTIONS #21, #22). Plain `xcodegen generate`
  = lite app: no extension targets, no entitlements, Screen Time compiled out (no `BZ_SCREEN_TIME`
  Swift flag). `BZ_SCREEN_TIME=YES xcodegen generate` adds `project-screen-time.yml` (3 extensions,
  Family Controls + App Group, Swift flag).
  Verified 2026-10-01:
  - lite, Simulator: builds, tests pass, no `PlugIns`;
  - lite, device (`generic/platform=iOS`, `DEVELOPMENT_TEAM=7DTC6L573G` free Personal Team,
    `-allowProvisioningUpdates`): **signs and builds**, no `PlugIns`, entitlements = team defaults only;
  - full, Simulator unsigned: builds, `PlugIns` holds 3 `.appex`, `-DBZ_SCREEN_TIME` passed.
  The earlier build-setting version did leave `PlugIns` empty, but the free team rejected signing:
  its profile can't carry the App Group (`application-groups` came back empty). Hence the fallback.

## Owner feedback round 1 (2026-10-01, iPhone, lite build, free team)
- [x] 1. Tab bar hidden by default; show/hide button in a 32 pt header strip above each lite view
  (the web view sits below it and no longer extends under the tab bar, which covered Instagram's
  bottom navigation). Accounts section in the Wall tab: signed in/out per platform from cookie
  names (`SessionDetector`, tested), sign-out clears only that platform's cookies (`LiteSession`,
  UNVERIFIED). Files: `RootView.swift`, `WallView.swift`, `AppModel.swift`, `LiteSession.swift`.

- [x] 2. YouTube. Every page the owner listed (search, library `/feed/you`, playlists, watch later,
  history, channel pages incl. `/channel/`, `/c/`, `/user/`, `/@x/videos|playlists|streams`) is
  allowed by both engines (shared route vectors); no route-level over-blocking found. Signed out
  (no `LOGIN_INFO`/`SID`/`__Secure-3PSID` cookie) the tab lands on Search (`/results?search_query=`).
  Playback: a test proves no content rule can match googlevideo/ytimg/ggpht/player requests;
  passive media listeners log `error` (with MediaError name), first `stalled` and first `playing`
  per video to Diagnostics. Tap-to-play left unchanged (QUESTIONS #27 asks the owner).
  **S2 result recorded**: Google warned "browser didn't seem trustworthy", two sign-ins needed, VPN
  on (SECURITY_MODEL.md "Spike results"). Login-free fallback built: Takeout CSV import + RSS feeds
  (`YouTubeSubscriptions.swift`, `NetworkPolicy.youtubeFeed`, tested) and a native list sheet from
  the header strip's list button (`YouTubeSubscriptionsView.swift`, UNVERIFIED).

- [x] 3. Wall explainer (`WallExplainerView.swift`, UNVERIFIED): opens by itself the first time the
  Wall tab is shown, then from a "What is the wall?" row. Covers what it does, instant tightening vs
  cooldown, Hard Lock, passes, what it can't stop (matches SECURITY_MODEL.md), and — in the free
  build — which features are off and why. Replaces the old inline "can and can't stop" paragraph.

## Next
1. Owner: `docs/ON_DEVICE_CHECKLIST.md` steps 1–14; report spike results.
2. Phase 1 remaining items above (downloads, interactionState restore, unread counts).
3. Phase 2: onboarding (authorization → per-platform app picker → notification permission), pass request UI with wait screen.
4. After S1–S7 results: revise ARCHITECTURE.md §7 decisions.

## Unverified
Every Swift file now compiles on macOS (items 1–14 of the old list; the extensions in the full variant
only). Still never **run** on a device:
- `LiteWebController.swift`, `LiteWebView.swift` (whole WebKit glue: rule lists, scripts, downloads,
  restore, badges) — owner checklist §D, works with the free-team lite build;
- `ScreenTime.swift`, `RevocationView`, Diagnostics S1/S5/S7, the three extensions — need a paid team
  with Family Controls (full build);
- `AppModel`, `RootView`, `WallView`, `BreakZeroApp`: ran only as far as the 1 app unit test.

Compiled and tested on Linux and macOS: `Core/*`, `LiteWeb/LiteWeb.swift`, `Shielding/Shielding.swift`,
`bz-filter.js`.

## Blockers / blocked commands (log)
- `download.swift.org` is denied by the session's egress policy (403). Swift was installed instead from
  Ubuntu's own `swiftlang` package (6.0.3, questing) inside a debootstrapped Ubuntu chroot at
  `/opt/swiftroot` (dev-only tooling, never shipped).
- Blocked by the permission classifier (not retried): switching that chroot's apt source to the
  `resolute` suite (for Swift 6.2); bind-mounting the repo into the chroot; `add_repo` with push access.
  Tests run by copying the repo into the chroot (`rsync`, no mounts) and running `swift test` there.
- Initial `git push` failed (403, no GitHub App access). Owner fixed access; pushes work now.
- After a container restart the chroot had no `/proc` (Foundation tools crash with SIGILL). Re-ran the
  chroot's original setup step `mount -t proc proc /opt/swiftroot/proc` (not blocked; part of the
  original setup, not a workaround for a block).
- Rule from owner: if a command gets blocked, don't try privileged workarounds (e.g. mounts) — log it
  here and move on.
