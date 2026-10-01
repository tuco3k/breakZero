# Progress

Claude Code keeps this file current. Read it first in every session.

## Status
Phase 0 code-complete. Mac build verified 2026-10-01 (Xcode 27, iOS 27 SDK): both variants
compile with no errors or source warnings, all tests pass, and the lite app signs with the owner's
free Personal Team. Waiting on owner: install on the iPhone + spike results.
Phase 1 in progress: recipes, rule engine, all five filter layers and their tests are written;
the WebKit glue compiles but hasn't run on a device.

Test status (macOS, 2026-10-01, after feed rules rev. 2): `npm test` (Node 26) → **119 pass**; `swift test` on
the macOS host → 174 pass (Core 154, LiteWeb 15, Shielding 5).

Test status (Linux, Swift 6.0.3 + Node 22):
- `cd Packages/BreakZeroKit && swift test` → **111 tests pass** (Core incl. limits with a fake clock, LiteWeb pure parts, Shielding with fakes).
- `cd jstests && npm ci && npm test` → **62 tests pass** (shared route vectors for guard and watchdog, DOM filters, canaries, autoplay, media diagnostics).

Test status (macOS, Xcode 27, iPhone 17 Pro Simulator iOS 26.2), `xcodebuild … CODE_SIGNING_ALLOWED=NO build test`:
- **177 tests pass** (2026-10-01, feed rules rev. 2; build has no warnings): CoreTests 154, LiteWebTests 15, ShieldingTests 5, breakZeroTests 3.
- `scripts/check-release-no-debug-reset.sh` → OK (debug reset in Debug, absent from Release).
- (Old Instagram rev. 1: 141.)
- (Round 1: 113 tests.): CoreTests 96, LiteWebTests 11, ShieldingTests 5, breakZeroTests 1.

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
- [x] YouTube autoplay guard (tested in JS); tap-to-play **removed** per owner (QUESTIONS #27): the video you open plays, chains stay blocked
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
  per video to Diagnostics. Tap-to-play then removed with the owner's approval (QUESTIONS #27,
  2026-10-01): the video you open plays without an extra tap; finishing it never advances
  (`PlaybackPolicy`, tested in Swift and Node).
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

## Old Instagram (2026-10-01, ARCHITECTURE.md §4c, QUESTIONS #37–45)
- [x] Design + open decisions logged.
- [x] Core: `Friends.swift` (normalize, story gate, `FriendsScanState` with mutuals/suggestions),
  `PlatformSettings.friends`, ratchet (`addFriend` loosening except the first, `removeFriend` instant
  except the last, neutral while off), recipe `friendsFilter` (v2) + validator. 25 Swift tests.
- [x] Story gate = generated route rule → enforced by every existing layer; shared route vectors run it
  in Swift and JS.
- [x] Page (`bz-filter.js`): default-deny feed posts and tray items (author = first profile href),
  viewer hidden until checked + skip to the next friend in tray order, "You're all caught up" that
  stops loading, forced Following feed (3 per 30 s then gives up), read-only setup scan (only while
  armed), friends canaries. 27 Node tests with fixtures.
- [x] App: Wall › Instagram › *Old Instagram* screen (toggles, search, add, swipe to remove,
  suggestions, Add all, pending adds, scan Followers/Following, Import Close Friends), scan armed for
  30 min, toast "Only friends' stories here." Diagnostics S9/S10 one-tap spikes.
- [x] Built, 141 tests pass, installed and launched on the owner's iPhone. In the Simulator: Friends
  screen renders, adding the first friend applies at once and Instagram still loads, no filter errors.
- [ ] Spikes S9 (`?variant=following`) and S10 (Close Friends) — owner, one tap each.
- [ ] Device markup unknown: post container (`main article`), tray links (`/stories/<user>/`), viewer
  header link. All recipe data; adjust after the first device report.

## Feed rules rev. 2 (2026-10-01, ARCHITECTURE.md §4c–4e, QUESTIONS #46–57)
- [x] Mutuals-only by default; show-only rules per surface (Everyone I follow / Mutuals / My list /
  Close Friends); Never/Always lists with precedence; Old Instagram is a preset; suggestions and
  ads always hidden. rev. 1 Friends list migrates to "My list" (no silent widening).
- [x] People data: Instagram export import (zip or JSON, pure-Swift zip + inflate, HTML rejected,
  17,000 accounts in about a second), auto-scroll sync (slow pace, 800/list/session cap, resume,
  stops on challenge/login/dialog/stall/leaving), manual scrolling as fallback, 30-day freshness.
- [x] Story gate as engine code: stories from a profile you open play one person only; profile
  stories setting; never bounced to the feed from a profile; staying put doesn't reload.
- [x] One-tap hide on posts and in the story strip; "Mutuals only · N hidden" pill with Hidden
  recently (Always / Never show).
- [x] Searchable collapsible lists with counts, multi-select bulk actions; app-wide coalesced toasts.
- [x] Limit modes: per app / all together / both, for daily time and short-form budgets; any 1–240 min.
- [x] Lock / Block deleting / Hard Lock confirm by press-and-hold; 10-minute undo countdown (clock
  tricks end it early only); undo window setting (shorten only).
- [x] Diagnostics: spike results PASS/FAIL/UNKNOWN with meanings (S9, S10 PASS from the owner);
  Debug-only reset, proven absent from Release.
- [x] Built (no warnings), 177 Xcode tests + 119 Node tests pass, installed and running on the iPhone.
  Simulator: migration to My list, Feed rules screen, import sheet, Lock hold + Undo all checked;
  app test imports a 3,000-account export end to end (800 mutuals, 0.14 s).
- [ ] Owner: a real export, a real auto-scroll run, and Instagram's real markup (post container,
  tray links, viewer header, hide button position) — see below.

## Next — what the owner should test on the phone (lite build is enough)
Installed 2026-10-01 (free team; reinstall after 7 days). Full steps: `docs/QA.md`.
1. **Import your real export** (Feed rules › Import): note the summary line and how long it took.
2. **Feed**: only mutuals; no ads or suggestions; "You're all caught up" after scrolling; the small
   *Hide* button on posts sits somewhere sensible (tell me if it covers anything).
3. **Stories**: tray only mutuals; fast tap-through never flashes anyone else; a non-mutual's ring
   on their profile plays only them; with the setting off you stay on their profile.
4. **Pill**: "Mutuals only · N hidden" → Hidden recently → Always / Never show.
5. **Auto-scroll (optional)**: run Re-sync on your account; report how far it got and whether
   Instagram showed anything.
6. **Limits**: try a typed value (e.g. 7 min) and Per app vs Both for Reels/Shorts.
7. **Lock**: hold to turn on, see the 10-minute Undo countdown, Undo.
8. **Still works**: DMs, search, profiles, posting, notifications.
From before: YouTube with VPN on/off, the 2-minute budget hard stop, Snapchat S8, checklist 1–17.

## Unverified
Everything compiles on macOS (lite build, 2026-10-01; full build last checked at `0ec5866`). The lite
app installs and launches on the owner's iPhone, but none of the new UI has been exercised on it yet:
header strip / hidden tab bar, Accounts + `LiteSession` sign-out, Wall explainer, Limits and
done-for-today, watchdog, YouTube RSS subscriptions, Diagnostics S8, and feed rules on Instagram's
real markup (post container, tray links, viewer header, the hide button's position, auto-scroll's
scroll container on the real Followers page). The export importer is tested against Python-made
zips and synthetic exports, not yet a real Instagram export. Never run on a device:
`ScreenTime.swift` and the three extensions (need the paid Screen Time build).
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
