# breakZero architecture (DRAFT — Phase 0)

Status: draft written before any spike results. Sections marked **[spike]** will change once the
owner reports Phase 0 results from a real iPhone (see `docs/ON_DEVICE_CHECKLIST.md`).

## 1. Shape of the app

```
┌───────────────────────── breakZero.app (SwiftUI, iOS 17+) ─────────────────────────┐
│  TabView: [Instagram Lite] [YouTube Lite] … [Wall]                                  │
│     │                                   │                                           │
│     ▼                                   ▼                                           │
│  LiteWeb (WKWebView per platform)     Wall screens (policy, pending queue, passes,  │
│   ├─ WKContentRuleList  (layer 1)      diagnostics S1–S7, revocation screen)        │
│   ├─ navigation delegate (layer 2a)                                                 │
│   ├─ injected JS route guard (2b), CSS (3), heuristics (4), canaries (5)            │
│   └─ RuleEngine decisions (Core)                                                    │
│                                                                                     │
│  Core ─ WallPolicy / LockState / Ratchet / TrustedClock / PassLedger                │
│       ─ Recipe models + validation + RuleEngine + ContentRuleListBuilder            │
│       ─ NetworkPolicy (single choke point for every URLSession request)             │
│       ─ SharedStore (App Group, Codable JSON, file coordination)                    │
│  Shielding ─ protocols over ManagedSettings / DeviceActivity + real impls           │
└─────────────────────────────────────────────────────────────────────────────────────┘
        ▲ App Group container (same JSON truth for all processes)
        │
┌───────┴──────────────┬──────────────────────────┬───────────────────────────────┐
│ ShieldConfiguration  │ ShieldAction             │ DeviceActivityMonitor          │
│ custom shield copy   │ post local notification  │ re-shield after passes,        │
│                      │ that deep-links → .close │ apply due pending loosenings   │
└──────────────────────┴──────────────────────────┴───────────────────────────────┘
```

## 2. Repository layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and git-ignored. |
| `App/` | SwiftUI app target: entry point, tabs, Wall screens, Diagnostics, Info.plist, entitlements. |
| `Extensions/ShieldConfiguration/` | `ShieldConfigurationDataSource` subclass. |
| `Extensions/ShieldAction/` | `ShieldActionDelegate` subclass. |
| `Extensions/DeviceActivityMonitor/` | `DeviceActivityMonitor` subclass. |
| `Packages/BreakZeroKit/` | One local Swift package with three library products: `Core`, `LiteWeb`, `Shielding`. |
| `Packages/BreakZeroKit/Sources/Core/Resources/Recipes/` | Bundled recipe JSON (one file per platform). |
| `Packages/BreakZeroKit/Sources/LiteWeb/Resources/` | Injected JS/CSS (bundled code, never downloaded). |
| `jstests/` | Node tests for the injected scripts against HTML fixtures (dev-only, uses jsdom). |
| `docs/` | On-device checklist, QA checklist. |

### Why one package with three products (not three packages)
XcodeGen references one local package and links products per target. Fewer `Package.swift` files to
keep in sync, and `swift test` at one path runs every Linux-testable test.

### Building without Screen Time (`BZ_SCREEN_TIME`, generate time)
`project.yml` alone is the **lite app**: the app target and its tests, no Screen Time extensions, no
entitlements at all (a free Personal Team can sign it), and app code built without the
`BZ_SCREEN_TIME` Swift flag. `BZ_SCREEN_TIME=YES xcodegen generate` also includes
`project-screen-time.yml`, which adds:
- the three extension targets and the app's dependencies on them (so they're embedded);
- `CODE_SIGN_ENTITLEMENTS = App/breakZero.entitlements` (Family Controls Development + App Group);
- `BZ_SCREEN_TIME` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS`; app code gates every Screen Time call
  on it (`AppModel.reconcile`, `RevocationView`, Diagnostics S1/S5/S7 and the picker).

Why generate time, not a build setting: the first version was a `BZ_SCREEN_TIME` build setting that
kept the extension targets and left them out via `EXCLUDED_SOURCE_FILE_NAMES`. That did leave
`PlugIns` empty, but a free team still couldn't sign the app: its profile can't carry an App Group.
Removing the targets entirely is simpler and leaves nothing to sign but the app.

XcodeGen constraints behind the shape: an unset variable disables an include (no default syntax),
so unset means lite; and when merging, a scalar in `project.yml` wins over the include, so the
include only adds keys `project.yml` leaves unset (hence a positive `BZ_SCREEN_TIME` flag rather than
`BZ_NO_SCREEN_TIME`). The `BreakZeroKit` package is the same in both (packages don't see app
compilation conditions); in the lite app its Screen Time code is simply never called. Without the
App Group the app keeps its data in Application Support (`AppModel.init` fallback).

### Platform split (so logic is testable on Linux)
- `Core` imports only `Foundation`. No UIKit/WebKit/CryptoKit at all. Anything Apple-only that Core
  needs is a protocol (`SignatureVerifier`, `ClockSource`) implemented elsewhere.
- `LiteWeb` holds pure helpers (script assembly from a recipe) that compile everywhere, and the
  `WKWebView` controller inside `#if canImport(WebKit)`.
- `Shielding` holds protocols + pure coordinators (pass expiry, re-shield decisions) that compile
  everywhere, and the ManagedSettings/DeviceActivity/FamilyControls implementations inside
  `#if canImport(ManagedSettings)` etc.

## 3. Rule engine (Phase 1)

Recipe = versioned JSON, one per platform (see `RECIPES.md`). Every rule has a stable `id` so the
user's toggle state (part of `WallPolicy`) can refer to it.

Layers, applied in order:
1. **WKContentRuleList** — `ContentRuleListBuilder` converts `block` routes (and explicit
   `resourceBlocks`) into WebKit's JSON. WebKit's regex dialect is a subset (no `|`, no `{n}`, no
   named groups); patterns that can't be converted are skipped here and still enforced by layer 2.
2. **Navigation policy** — `RuleEngine.decide(url:context:)` returns `allow`, `block`,
   `redirect(url)`, `openExternally(url)`. Used by `WKNavigationDelegate` for full loads and by the
   injected route guard (which hooks `history.pushState/replaceState` and `popstate`) for SPA
   navigation. The JS route guard evaluates the same recipe patterns (ICU and JS regex share the
   subset we allow: validated at recipe load).
3. **CSS** — hide selectors injected at `documentStart`, scoped per route by toggling a
   `data-bz-route` attribute on `<html>` from the route guard.
4. **Heuristics** — `MutationObserver` + `requestAnimationFrame` throttle; href / ARIA / structure
   based (never visible text).
5. **Canaries** — after load and on each route change assert forbidden things are absent; if not,
   blur + "Filter needs an update" overlay with a report button (prefilled GitHub issue opened in
   Safari, no telemetry).

**Allow zones** (`allowZones` regexes: DMs, compose, settings, login, checkpoints): layers 3–5 do
nothing there. Only route-level rules (1–2) run. A bug in a forbidden-surface filter can't break DMs.

**Reel-from-DM ("allowOnce" scope `fromThread`)**: `RuleEngine` keeps a tiny state machine per tab:
navigating from an allow zone thread to `/reel/{id}` admits that id once; any navigation to a different
reel id while in that state bounces back to the originating thread. Reels reached any other way
redirect to the landing page.

**Fail safe & scoped**: every heuristic and canary runs inside its own `try/catch`; a thrown error in
one filter marks that filter "unhealthy" (→ overlay on the forbidden surface) and never propagates.

## 4. The Wall (Phase 3, models in Phase 0/1)

- `WallPolicy`: every restriction setting (rule toggles, platform enablement, shielded selection blob,
  pass duration/wait/cap, cooldown, custom blocks).
- `PolicyChange`: one field-level edit. `Ratchet.classify(change, against: policy)` → `.tightening`,
  `.loosening` or `.neutral`.
- `Ratchet.submit(changes)`: tightening/neutral apply now; loosening goes to `LockState.pending` with a
  due time = cooldown measured by `TrustedClock`. Hard Lock rejects loosening until its end.
- `TrustedClock` / elapsed ledger: credited elapsed time between check-ins is the *minimum* of wall-clock
  delta and monotonic (sleep-inclusive) uptime delta within one boot; across a reboot only the new boot's
  uptime plus a small capped gap is credited. Forward clock jumps therefore never shorten a cooldown.
  Residual risks go in `SECURITY_MODEL.md`.
- Pending loosenings are applied by the DeviceActivityMonitor extension at their due time (a
  DeviceActivity schedule starting then) and reconciled on every app launch.
- Named `ManagedSettingsStore`s: `wall.base` (shields), `wall.pass` (unused by design: passes *remove*
  shields from base, see below **[spike S7]**), `wall.schedule`.

> Open question for S1/S7: ManagedSettings merges stores by "most restrictive wins", so a pass can't
> un-shield an app that another store shields. A pass therefore has to edit `wall.base` itself, and
> the extension must restore it. This is why every extension callback re-applies the base wall from
> `WallPolicy` (idempotent) rather than trusting what is currently set.

## 4a. Time limits, short-form budget, schedules (design, 2026-10-01)

All OFF by default. Settings live in `WallPolicy.limits` (`LimitsPolicy`), so every change goes
through the ratchet. State lives in a separate `usage.json` (`UsageState`), written every few
seconds while a lite tab is on screen.

**Settings** (`Core/Limits.swift`)
- `dailyMinutes[platform]` — nil = no limit.
- `shortFormMinutes` — one budget shared by Reels, Shorts and Spotlight. 0 = off.
- `schedules` — `ScheduleRule { target: .shortForm | .platform(p), start, end (minutes after
  local midnight, may wrap), weekdays? }`.

**Which rules are "short-form"**: recipes mark rules with `"shortForm": true` (routes, hide rules,
heuristics, canaries) and list `shortFormRoutes` (path regexes whose time counts against the
budget). `ActiveRecipe` takes a `ShortFormMode`:
- `.togglesDecide` — today's behavior (budget off, no schedule active);
- `.budgetAllowed` — budget left: short-form rules are dropped, so Reels/Shorts work;
- `.forcedBlocked` — budget used up or a short-form schedule is on: short-form rules run even if
  their toggle was turned off.
"Blocked" means back to the default wall, not stricter (a reel sent in a DM still plays once).

**Counting** (`UsageMeter`): the app ticks once a second while a lite tab is on screen and the
app is in the foreground. Each tick credits *trusted* time — the same rule as `ElapsedLedger`:
`min(wall delta, uptime delta)`, capped at 30 s per tick, nothing across a reboot or while
backgrounded (the meter is stopped). Seconds go to that platform's daily total, and to the
short-form total when the current path matches `shortFormRoutes`. Written to disk every 5 s and on
backgrounding, so killing the app loses at most ~5 s.

**The day** (`UsageState.trustedNow`, `dayEndsAt`): a trusted clock estimate advanced only by
credited time, never by the wall clock directly. When it passes `dayEndsAt` the counters reset and
the next `dayEndsAt` is the next local midnight — computed in the time zone pinned at the start of
the day, and never less than 20 h after the reset. So changing the clock or the time zone can't
reset or extend anything early; at worst a reset comes late (after the phone was off a long time,
or after flying east). Schedules are also evaluated in the pinned time zone.

**Ratchet** (`Ratchet.classify`):
| Change | Tightening | Loosening |
|---|---|---|
| Daily limit | lower, or none → some | raise, or some → none |
| Short-form budget | allowance goes down for every platform | allowance goes up for any platform |
| Schedule | add | remove |
Allowance per platform = budget if budget > 0, else 0 when that platform's short-form toggles are
all on, else unlimited. So turning the budget *on* is a loosening (Reels go from never to X min).

**Extra time**: only through the native-pass rules — the "done for today" screen offers *Request a
pass* (typed purpose, wait, daily cap, logged in the same `PassLedger`, token `lite:<platform>`).
An active pass lifts that platform's daily limit and schedule block for its duration. No
"5 more minutes" button.

**Evaluation** (`LimitEvaluator.evaluate`) is a pure function of policy + usage + passes + trusted
now → `LimitStatus { platformBlock[p]: reason?, shortForm: ShortFormMode, remaining… }`.
Everything above is in Core and tested on Linux with a fake clock.

## 4b. Enforcement watchdog (design, 2026-10-01)

On top of the route guard (which acts *before* a navigation), a watchdog checks the *current*
state, so anything that slips past the guard (a router we didn't hook, a swipe, a budget that ran
out mid-video) is caught within about a second.

- **In page** (`bz-filter.js`): `watchdogCheck(compiled, location, state, limits)` runs every
  1 s and on every navigation event (`pushState`/`replaceState`/`popstate`/`hashchange`/
  `pageshow`/`visibilitychange`). It re-runs the route decision without side effects (a granted
  DM reel stays allowed), checks canaries, and checks the `limits` block native injected.
- **Native** (`LiteWebController` + `AppModel`): a 1 s timer, independent of the page, reads
  `webView.url`, runs `RuleEngine.check` (non-mutating `decide`), and checks `LimitStatus`.
  When limits change (budget runs out), native rebuilds the active recipe and pushes the new
  config into the page (`__bzUpdate`).
- **On a violation** (either side): stop loading, pause every `<video>`/`<audio>`, go to the
  platform's landing page (or the "done for today" screen when the whole platform is blocked),
  show a short toast with the reason, and log it in Diagnostics. A 2 s debounce stops repeats
  while the landing page loads.
- Shared vectors: `route-vectors.json` drives both `RuleEngine.check` (Swift) and
  `watchdogCheck` (Node): every step the guard redirects must also be a watchdog violation if the
  page somehow got there, and every allowed step must pass.

## 4c. Feed rules: mutuals-only feed and stories (design rev. 2, 2026-10-01)

Revision of "Old Instagram" after owner testing. The normal Instagram feed (Following variant) and
stories row work as usual, except people outside a **rule** are hidden. "Old Instagram" is now a
preset of these rules. The manual list is for exceptions only.

**Rules** (`PlatformSettings.feedRules`, in `WallPolicy`, so they go through the ratchet)
- *Show only*, separately for the feed and for stories: `everyone` (everyone I follow) / `mutuals`
  (default) / `myList` / `closeFriends`.
- `never` (hide everywhere) and `always` (show even if the rule doesn't match) lists.
- Precedence: never > always > show-only rule. Suggestions and ads are always hidden.
- `profileStories` (default ON): a story opened from that person's profile plays (one person, no
  auto-advance into someone else). OFF: you stay on their profile with a short message. Never-show
  beats it. Profiles you open on purpose always load; the gate never bounces you to the feed from a
  profile.
- The old `friends` list becomes `myList`. An existing non-empty list keeps the rule on `myList` (no
  silent widening); fresh setups default to `mutuals`.

| Change | Kind |
|---|---|
| Rule → `everyone`, or between `mutuals`/`myList`/`closeFriends` | widening (cooldown) |
| Rule `everyone` → anything narrower | narrowing (instant) |
| Add to `always`, remove from `never`, add to `myList` (when a rule uses it), profile stories ON | widening |
| The opposite of each | narrowing |
| Feed rules off (`ig.friendsOnly`), Following feed off | widening |
| Import / re-sync / re-import mutuals | data, not a rule change: no cooldown |

**People data** (`PeopleData`, own file `ig-people.json`, never in the policy, never leaves the
phone): followers, following, close friends, owner, `updatedAt`, source. Mutuals = followers ∩
following. A full refresh replaces the lists, so people removed disappear at once; newly mutual
people appear only after a refresh. Until there is data, a rule that needs it (mutuals, close
friends) isn't applied (the screen says so); an import with no following list is rejected, so data
never goes back to empty.

How it's filled (no hidden API requests of our own):
1. **Instagram data export** (recommended): in-app steps (Accounts Center › Your information and
   permissions › Download your information › only "Followers and following", JSON). Import the
   `.zip` or the `.json` files from Files. `ExportImporter` reads zip entries itself (central
   directory + a small pure-Swift inflate, so it runs on Linux too), takes only
   `followers*.json`, `following.json` and `close_friends.json`, and pulls usernames from
   `string_list_data[].value`, `title` or the `href`. Tolerant of format drift; rejects HTML exports
   with a clear message.
2. **Auto-scroll sync** (on the user's tap): the Instagram tab visibly scrolls the user's own
   Followers, then Following, at a slow pace (one screen every 2–4 s, a longer pause every ~12
   screens), reading usernames from profile links as they load. At most 800 new names per list per
   session; progress is saved and the next session continues. Stops at once on a challenge, login,
   checkpoint or any dialog without the list, and when nothing new loads (stalled). `SyncSession`
   (Core) owns the plan, caps, resume and stop reasons; the page only scrolls and reports.
3. **Manual scrolling**: the old armed scan, kept as a last resort.
Freshness: "Mutuals last updated N days ago"; after 30 days a reminder with *Re-sync* / *Re-import*.

**Enforcement** (what changed from rev. 1)
- `ActiveRecipe.friends` now carries per-surface allowed sets (`feed`, `stories`: nil = no
  audience filter), the `never` set and `profileStories`. Native computes them:
  `(base(rule) ∪ always) − never`.
- The story gate is engine code instead of a generated regex (it needs context: the profile you came
  from). Same algorithm in `RuleEngine` and `bz-filter.js`, checked by shared route vectors:
  allowed user → allow; came from `/<user>/` with profile stories on → allow and remember the user
  (`NavigationState.storyUser`); a later move to someone else → back to that user's profile; from a
  profile with profile stories off, or never-shown → stay on the profile; from the feed → close (the
  page first tries the next allowed person in the tray).
- Feed: default-deny CSS as before; a post shows once its author is allowed. Each shown post gets a
  small "hide" button (our own element over the post's corner) that adds the author to `never`
  (narrowing, instant). In the story viewer the header strip offers "Hide @user".
- The page reports hidden authors (names only, to native, never logged); the Instagram strip shows a
  pill "Mutuals only · 12 hidden" that opens the recently hidden list with *Always show* / *Never
  show*.

**Unchanged:** allow zones, search, profiles, `/p/…`, notifications, canaries, caught-up card,
forced Following feed (S9 PASS on device), Close Friends page readable (S10 PASS on device).

## 4d. Limit modes (2026-10-01)
Minutes are any value 1–240 (stepper), not presets. Short-form: a shared budget across platforms,
a budget per platform (Reels / Shorts / Spotlight), or both. Daily time: per app, an overall cap
across apps, or both. Every limit that is set applies; the tightest wins. Ratchet as before:
lowering or adding a limit is instant, raising or removing waits. `LimitStatus.shortForm` becomes
per platform.

## 4e. Accidental wall activation (2026-10-01)
- Turning on the Lock, a Hard Lock or Block-deleting asks first: plain words on what gets locked,
  the cooldown, that loosening will take that long (and, in the Screen Time build, that the app
  can't be deleted). Confirm by press-and-hold.
- **Grace period** (default 10 min, setting can only be shortened): right after the Lock goes on,
  the Wall tab shows a countdown with *Undo*, which turns the Lock off instantly. It ends at the
  earliest of: wall-clock elapsed, uptime elapsed, a reboot, or the clock moving back.
- Debug builds only: Diagnostics › *Reset all breakZero data* (policy, lock, lists, limits, ledgers,
  web data), then the app closes. `#if DEBUG`; `scripts/check-release-no-debug-reset.sh` builds
  Release and fails if the reset's marker string is in the binary.

## 5. Network policy

`NetworkPolicy` is the only type allowed to create `URLRequest`s for `URLSession`. A unit test scans
the source tree and fails if `URLSession` appears outside `NetworkPolicy.swift`. Allowed hosts:
platform hosts from enabled recipes (`hosts` + `relatedHosts`) for web views, and exactly one optional
recipe-update host when the user enables updates. Web views can only *navigate* top-level to platform
hosts; anything else is opened in `SFSafariViewController` (not our traffic).

## 6. Storage

`SharedStore` writes one Codable JSON file per document (`wall-policy.json`, `lock-state.json`,
`pass-log.json`, `recipe-cache/…`) into the App Group container, wrapped in `NSFileCoordinator` on
Darwin so the app and extensions never read a torn write. Writes are atomic (`.atomic`).

## 7. Decisions pending spikes

| Area | Default until results | Spike |
|---|---|---|
| Our WKWebView vs shielded web domains | Use default persistent data store; fall back to named store if bled | S1 |
| YouTube login | Logged-out YouTube Lite + RSS subscriptions fallback stays possible | S2 |
| User agent | WebKit default UA | S2/S3 |
| Pass mechanism | Edit base store + DeviceActivity interval for re-shield | S7 |
| Notifications | Option A (disclose) | S4 |
| Snapchat | Draft recipe, off by default, desktop Safari UA | S8 |

**S8 outcomes (decided in advance, 2026-10-01).** If web.snapchat.com loads and chat works in our
web view: finish the draft recipe (chat kept; Spotlight and Discover blocked; Spotlight counted in
the shared short-form budget) and turn the tab on by default. If it doesn't: drop the lite tab, and
say plainly in the app and docs that **Spotlight can only be blocked by shielding the native
Snapchat app, which needs the paid (Screen Time) build** — the free build can't touch it.

**Recorded results**
- S2 (2026-10-01, owner's iPhone, WebKit UA, VPN on): Google warned the browser "didn't seem
  trustworthy" and required two sign-ins; signed-in YouTube then worked. Decision: keep signed-in
  web YouTube as an option; build the login-free RSS fallback (done); land on Search when signed out.
