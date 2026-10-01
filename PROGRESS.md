# Progress

Claude Code keeps this file current. Read it first in every session.

## Status
Phase 0 code-complete. Mac build verified 2026-10-01 (Xcode 27, iOS 27 SDK): both variants
compile with no errors or source warnings, all tests pass, and the lite app signs with the owner's
free Personal Team. Waiting on owner: install on the iPhone + spike results.
Phase 1 in progress: recipes, rule engine, all five filter layers and their tests are written;
the WebKit glue compiles but hasn't run on a device.

Test status (Linux, Swift 6.0.3 + Node 22):
- `cd Packages/BreakZeroKit && swift test` → **111 tests pass** (Core incl. limits with a fake clock, LiteWeb pure parts, Shielding with fakes).
- `cd jstests && npm ci && npm test` → **62 tests pass** (shared route vectors for guard and watchdog, DOM filters, canaries, autoplay, media diagnostics).

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

- [x] 4. Limits (all off by default). Core (tested on Linux with a fake clock): `Limits.swift` —
  `LimitsPolicy` in `WallPolicy`, `UsageState` (own trusted ledger + trusted day, pinned time zone,
  ≥ 20 h days), `LimitEvaluator`, `ShortFormMode` applied by `ActiveRecipe`; recipes mark
  `shortForm` rules and `shortFormRoutes`; ratchet rules for limits/budget/schedules. App
  (UNVERIFIED): 1 s usage meter while a lite tab is on screen in the foreground (`AppModel`),
  "done for today" screen with the pass path (`DoneForTodayView.swift`), Wall › Limits and
  Schedules (`LimitsSection.swift`), remaining minutes in the header strip.

- [x] 5. Enforcement watchdog. In page (`bz-filter.js`, tested in Node): `watchdogCheck` runs
  every 1 s and on hashchange/pageshow/focus/visibility; an unseen URL change or a page that's no
  longer allowed (rules changed, budget ran out, platform blocked) → stop, pause media, go to the
  safe page, post `violation`; 2 s debounce; `__bzUpdate` lets native push new rules/limits without
  a reload. Native (UNVERIFIED): `RuleEngine.check` (tested, same shared vectors as JS) on a 1 s
  timer in `LiteWebController`, acting only on a URL that's been showing a full tick; violations →
  toast in the header strip + Diagnostics log (`AppModel.handleViolation`).

- [x] 6. Snapchat. Can't spike from Linux, so: Diagnostics › *S8 · Snapchat web chat* (load
  web.snapchat.com with WebKit / desktop Safari / mobile Safari UA, list cookie names) and checklist
  step 18. **Draft** recipe `snapchat.json` (chat on web.snapchat.com kept; Spotlight, Discover,
  Explore, Stories browsing blocked; Spotlight in the shared short-form budget; desktop Safari UA),
  validated and covered by shared route vectors in Swift and JS; **off by default** (Wall ›
  Platforms). Outcome rule written down in ARCHITECTURE.md §7: if S8 fails, Spotlight can only be
  blocked by shielding the native app in the paid build. Roadmap: Snapchat moved to v1.1, ahead of
  Reddit/X/Facebook (BRIEF.md §4.1, §12).

- [x] 7. Reliability: fake-clock tests for limits (midnight rollover, clock forward/back, time
  zone, app closed overnight, reboot, background, kill-and-reopen, budget running out mid-video);
  Node watchdog tests on the shared route vectors (Swift `RuleEngine.check` runs the same vectors);
  `docs/QA.md` › *Limits, budgets and schedules: try to break them*; SECURITY_MODEL.md residual risks.

## Next — what the owner should test on the phone (lite build is enough)
Build first: `xcodegen generate`, then build on the Mac. New Swift files since the Mac build are
UNVERIFIED (list below); expect a round of compile fixes.
1. **Layout** (item 1): our tab bar is hidden; the button at the top right of the strip shows/hides
   it; nothing of ours covers Instagram's bottom navigation or YouTube's controls, with the tab bar
   shown or hidden.
2. **Accounts** (item 1): Wall › Accounts shows Instagram/YouTube signed in or out; *Sign out* on
   one platform signs out only that one (the other stays signed in).
3. **YouTube** (item 2): signed out, the tab opens on Search (check the page offers a search box);
   signed in, on Subscriptions. Library, playlists, Watch later, history and channel pages open. Play
   a few videos; if one won't play, send Diagnostics › Log (look for `video error code …`). Try the
   sign-in once without the VPN and say whether the "browser didn't seem trustworthy" warning stays.
4. **No-sign-in Subscriptions** (item 2): from Google Takeout get `subscriptions.csv` (YouTube →
   subscriptions), tap the list button in the YouTube strip, Import, then open a video from the list.
5. **Wall explainer** (item 3): appears the first time you open the Wall tab; "What is the wall?" brings
   it back; the free-build section is correct.
6. **Limits** (item 4) and **watchdog** (item 5): run the new *Limits, budgets and schedules* section
   of `docs/QA.md` end to end. Every path must hard-stop within about a second.
7. **Snapchat spike S8** (item 6): `docs/ON_DEVICE_CHECKLIST.md` step 18.
8. Answer QUESTIONS.md **#27** (may YouTube tap-to-play be relaxed if it's what blocks playback?).
Still open from before: checklist steps 1–17 (spikes S1, S3–S7 need the paid Screen Time build).

## Unverified
Never compiled (written on Linux after the Mac build of 2026-10-01). Build these first:
- `App/Sources/RootView.swift` (header strip, hidden tab bar, done-for-today, remaining minutes)
- `App/Sources/AppModel.swift` (sessions, sign-out, usage meter, limits, watchdog wiring, RSS)
- `App/Sources/Wall/WallView.swift` (Accounts, Limits, Platforms, explainer)
- `App/Sources/Wall/WallExplainerView.swift`
- `App/Sources/Limits/DoneForTodayView.swift`, `App/Sources/Limits/LimitsSection.swift`
- `App/Sources/YouTube/YouTubeSubscriptionsView.swift`
- `App/Sources/Diagnostics/DiagnosticsView.swift` (S8 section, desktop UA probe)
- `App/Sources/BreakZeroApp.swift` (foreground → meter/watchdog)
- `Packages/BreakZeroKit/Sources/LiteWeb/LiteWebController.swift` (watchdog, limits push, cookies,
  media pause, recipe UA/landing host), `LiteSession.swift` (new)
Compiled on macOS 2026-10-01 but never run on a device: the rest of the WebKit glue, `ScreenTime.swift`,
the three extensions.
Compiled and tested on Linux (CI: swift 6.0 + latest) and in Node: everything in `Core`, the pure parts
of `LiteWeb` and `Shielding`, and `bz-filter.js`.

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
- CI "Swift package tests (Linux)" was red from run 9 (my item 2 commit, not the Mac session's:
  run 6 for 0ec5866 was green). Cause: `YouTubeFeedParser` trusted `XMLParser.parse()`, and the
  swift:6.0 image's older libxml2 reports a truncated document as success (my local libxml2 and
  Apple's parser reject it). Fixed by checking well-formedness ourselves (root `<feed>`, every
  element closed, no parse error). Not a Swift-version issue (CI and local are both 6.0.3); CI now
  also runs the package tests on `swift:latest` to catch newer-compiler (Mac/Xcode) errors.
- Rule from owner: if a command gets blocked, don't try privileged workarounds (e.g. mounts) — log it
  here and move on.
