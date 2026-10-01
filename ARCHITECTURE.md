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

### Building without Screen Time (`BZ_SCREEN_TIME`)
One build setting in `project.yml`. `YES` (default) is the full app. `NO`:
- `CODE_SIGN_ENTITLEMENTS` → `App/breakZero-NoScreenTime.entitlements` (App Group only, no Family Controls);
- `EXCLUDED_SOURCE_FILE_NAMES` lists the three `.appex` bundles, so they aren't embedded in the app;
  the extension targets still compile (they're target dependencies) but with `CODE_SIGNING_ALLOWED = NO`;
- `SWIFT_ACTIVE_COMPILATION_CONDITIONS` gains `BZ_NO_SCREEN_TIME`; app code gates every Screen Time
  call on it (`AppModel.reconcile`, `RevocationView`, Diagnostics S1/S5/S7 and the picker).
The `BreakZeroKit` package is unaffected (packages don't see app compilation conditions); its Screen
Time code is simply never called. Both entitlements files are checked in; the app target has no
XcodeGen `entitlements:` key because that would pin `CODE_SIGN_ENTITLEMENTS` to one file.

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
