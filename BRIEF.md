# Build brief: breakZero — free, open-source "lite" social media with a wall you can't climb

> This is the source of truth for the project. `CLAUDE.md` holds the standing working rules; `PROGRESS.md` and `QUESTIONS.md` are the running logs.

---

## Unattended run (overrides anything below that says to stop and ask)

I'm away until morning. Don't wait for answers:
- Use the defaults in §13. Write every question you would have asked, plus the default you chose, to `QUESTIONS.md`, and keep going.
- Work through Phase 0, then as far into Phase 1 as you can. Skip anything that needs my iPhone or my Apple Developer account and add it to `docs/ON_DEVICE_CHECKLIST.md` instead of stopping.
- After each milestone: update `PROGRESS.md`, commit, and push.
- Where you'd otherwise "ask me before" something in this brief, don't do it — log it in `QUESTIONS.md` and pick the most conservative option.

---

## 0. How to work on this (read first)

- You are building a native iOS app from an empty repo. Read this entire brief and `CLAUDE.md`, write a draft `ARCHITECTURE.md` and a Phase 0 task plan into `PROGRESS.md`, then build Phase 0.
- **Screen Time APIs (FamilyControls, ManagedSettings, DeviceActivity) do not work in the Simulator.** Anything touching them must be verified by me on a physical iPhone. When you need that, add a short numbered step to `docs/ON_DEVICE_CHECKLIST.md` and move on to work you can verify. Never claim a Screen Time behavior works because it compiled.
- Ask me before: adding any third-party dependency, adding any network call to a host other than the social sites the user opens, weakening any wall rule, or anything that costs money.
- Prefer boring, well-documented Apple APIs over clever hacks. Every hack you do use gets a comment explaining why, what breaks it, and how we'd notice.

---

## 1. Mission

Let people use social platforms for the parts they choose — messages, people they follow, posting — while the parts engineered to hook them (short-form video feeds, algorithmic recommendations, explore pages, autoplay chains) sit behind a wall that the person in a weak moment can't undo.

**Benchmark: SocialLite** (App Store id 6757661674). Same core idea: load the web versions of the platforms with addictive surfaces removed, and shield the native apps with Screen Time so taps redirect into the lite version. It's popular and well rated. We beat it on three axes:

1. **Free in every way.** SocialLite is free to download but has a ladder of Pro/Family subscriptions and its privacy label lists identifiers used for tracking. We ship: no in-app purchases, no subscriptions, no ads, no analytics or crash SDKs, no account, no backend. Open source. App Privacy label "Data Not Collected" — and it must be literally true.
2. **Reliability.** The things users keep must just work. SocialLite reviews complain about: DMs that never load, being unable to start a new chat, missing posting features (video posts, stories, close friends, music), no DM notifications once native apps are blocked, slowness, and a ~150 MB download. When a platform changes its site, our filters must fail safe and be fixable without an App Store release.
3. **A real wall.** Commitment features designed so loosening restrictions is slow and deliberate, plus guided setup for the strongest OS-level protection iOS allows.

---

## 2. Non-negotiables

- **Free:** no StoreKit, no ads, no analytics/telemetry/crash SDKs (Apple's own App Store Connect crash reports only), no login, no server.
- **Private:** network traffic only to (a) platform sites loaded in our web views and (b) one optional, user-toggleable static URL for filter-rule updates. Enforce with a single `NetworkPolicy` choke point plus a unit test. Nothing read from a page ever leaves the device.
- **Subtractive only:** we hide, redirect, or block. We never rewrite a site's functional UI (DM threads, composer, upload flow, login). This is the main reliability lever.
- **Language-independent:** match on URLs, hrefs, ARIA roles, and DOM structure — never on visible English text. (SocialLite had to force the IG UI into English to make blocking work.)
- **Fail safe, scoped:** if a filter can't confirm a forbidden surface is gone, cover it (blur + "filter needs an update"). A failure in a forbidden-surface filter must never break an allowed surface.
- **Honest:** in-app copy and docs state exactly what the wall can and can't stop.
- **Small & fast:** app < 25 MB; cold start to a usable IG inbox < 2 s on an iPhone 12-class device.

---

## 3. Platform reality (researched Oct 2026 — re-verify each on device)

Treat these as hypotheses to confirm in Phase 0, not facts.

**Authorization & the wall**
- `AuthorizationCenter.shared.requestAuthorization(for: .individual)` (iOS 16+) lets a person restrict their own device. The user can revoke it in Settings; when they do, the system lifts all ManagedSettings restrictions immediately and the app is not notified while backgrounded. `authorizationStatus` has been reported stale after revocation — always re-check on launch and in every extension callback.
- **iOS 26.4+:** with a Screen Time passcode set, that passcode (not Face ID) is required to turn off an app's Screen Time access. Before 26.4, Face ID or the device passcode is enough. There are reports that on 26.4 the toggle under **Settings > Apps > breakZero** still only asks for Face ID — test every path on the newest iOS and record results in `SECURITY_MODEL.md`.
- The Screen Time passcode can be reset via "Forgot Passcode" using an Apple Account. If a trusted person sets the passcode, they should enter **their own** Apple Account for recovery.
- `ManagedSettingsStore().application.denyAppRemoval = true` blocks deleting our app, but Apple says it isn't guaranteed under `.individual` since authorization can be revoked.

**Shielding**
- App/category/web-domain tokens come only from `FamilyActivityPicker`; you cannot shield an app by bundle ID. Onboarding must have the user pick Instagram, YouTube, etc.
- Shielding an app also silences its notifications and Live Activities (compact Dynamic Island activities reportedly leak through). This is our biggest functionality cost — see §8.
- Shielding an app token can also shield that service's website (e.g. the YouTube app token → youtube.com). **Must verify whether this blocks our own WKWebView** (Spike S1).
- Category shields override individual-app allowances.
- `shield.webDomains` holds at most 50 tokens. `webContent.blockedByFilter` blocks domains in every browser but its blocked page can't be customized.
- Shields have been reported to persist after the app is uninstalled. Always clear our stores when the user legitimately unlocks, and document recovery steps.
- ShieldAction extensions can't open apps directly. Standard pattern: post a local notification that deep-links into our app, then return `.close`.
- DeviceActivity schedules reportedly require intervals ≥ 15 minutes; short passes need a workaround (backdated interval start, or a `DeviceActivityEvent` usage threshold). Verify.

**Web**
- Google blocks OAuth sign-in inside embedded WKWebViews (`disallowed_useragent`). YouTube login is at risk (Spike S2).
- WKWebView doesn't support Web Push, so lite tabs can't receive site push notifications.

**Distribution**
- The **Family Controls (Distribution)** entitlement requires Apple approval via the request form at developer.apple.com/contact/request/family-controls-distribution. Approval is now team-scoped. Waits range from a day to weeks — I should submit on day 1. The Development entitlement is enough for on-device testing. A paid Apple Developer Program membership is required to ship.
- App Store guideline 2.5.2 forbids downloading executable code. Remote rule updates must be declarative data interpreted by bundled code — never downloaded JS.

---

## 4. Product

### 4.1 Shell
Native SwiftUI app with a bottom tab bar: one tab per enabled platform + a **Wall** tab (settings, lock, passes, diagnostics). Each platform tab hosts one persistent, warm WKWebView ("Lite view"). Native back/forward swipe, pull-to-refresh, haptics. Dark mode. Dynamic Type for native UI. VoiceOver labels on all native controls.

**v1 platforms:** Instagram, YouTube. **v1.1:** Snapchat web chat (spike S8 first; owner moved it ahead, 2026-10-01). **v1.2:** Reddit, X, Facebook. **TikTok:** block wholesale (the product *is* the feed); DMs-only lite view only if it proves reliable.

**Custom blocks (all versions):** any app via the picker, any website via picker or filter, and per-platform advanced rules (URL pattern block, CSS hide) in the Lite views.

### 4.2 Default recipes (each item is a user toggle, default ON)

**Instagram**
- Landing page (user choice): Direct inbox `/direct/inbox/` or the Following feed (`/?variant=following`).
- Blocked routes: the Reels feed, Explore, Shop. Reels tab/entry points hidden.
- A reel someone sent you plays — that one reel only. Any swipe/next/navigation to a different reel ID bounces back to the thread it came from.
- Home feed: hide suggested posts, "suggested for you" carousels, sponsored posts. Option: hide the feed entirely (stories + DMs only).
- Keep working: DMs (open, send, **start a new chat**, photos/videos, reply to shared posts), profiles you navigate to, stories from people you follow, activity/notifications page, posting via the web composer, settings, login/2FA/checkpoint flows.

**YouTube**
- Land on Subscriptions (`/feed/subscriptions`); `/` redirects there.
- `/shorts/{id}` rewrites to `/watch?v={id}` (plays as a normal video, no swipe feed). Shorts shelves and tabs hidden.
- Hide: home recommendations, up-next/related, end-screen cards. Force autoplay off. Option: hide comments.
- Keep: search, subscriptions, library, playlists, watch later, history, channel pages, the player.
- **Do not touch the video player or its ads** — it's fragile, actively defended, and an App Review/ToS risk. No background playback in v1.

### 4.3 Native apps
- Onboarding: picker → user selects native apps to shield (suggest Instagram, YouTube, TikTok, Facebook, X, Reddit, Snapchat).
- Custom shield (ShieldConfiguration): "Instagram is behind the wall — use the lite version." Primary button → ShieldAction posts a local notification that deep-links to the matching Lite tab, then `.close`. Secondary button → "Request a native pass" (deep-links to the pass screen).
- **Native pass** (for things the web can't do: music on stories, close-friends posting, etc.):
  - Requested in-app with a typed purpose, then a wait screen (default 30 s; a wall setting).
  - Unshields that one app for N minutes (default 5). Re-shielding must happen in the DeviceActivityMonitor extension so it fires even if our app is killed. Belt-and-braces: re-apply on next launch and on every extension callback.
  - Daily cap (default 2). Every pass logged locally with its purpose.

---

## 5. The Wall

State: `WallPolicy` (every restriction setting) + `LockState` (mode, pending changes, pass log, last-verified timestamps). Stored in the App Group so all extensions read the same truth.

- **Ratchet.** Tightening applies instantly. Loosening — disabling a rule, unshielding an app, longer/more passes, shorter wait, turning the lock off — goes into a pending queue and applies only after the cooldown (default 24 h; options 1 h–7 d). Shortening the cooldown is itself a loosening change. Pending loosenings can be cancelled anytime.
- Pending changes apply via a DeviceActivity schedule so they land on time without the app open; the app reconciles on launch.
- **Hard Lock** (optional): until a chosen date, no loosening at all; native passes limited to the cap set before locking.
- **Clock tampering:** don't rely on wall-clock time alone for expiries. Cross-check against elapsed uptime and reboot detection; refuse early unlocks when the clock jumps forward. Recommend keeping Date & Time on "Set Automatically" and verify whether the Screen Time passcode locks that toggle. Document residual risk.
- **OS hardening while locked:** `denyAppRemoval = true`. A guided "Lock it in" flow, tailored to the device's iOS version: have a trusted person set the Screen Time passcode and use their own Apple Account for recovery (strong on 26.4+; show the weaker reality on older iOS).
- **Revocation handling:** on every launch and extension callback, check authorization. If the wall came down, show a calm screen stating when it was last verified intact and offer to rebuild it. No shaming. No partner notifications in v1 (would need a server).
- Lite-view rules obey the ratchet too.

---

## 6. Phase 0 spikes (results decide the architecture)

Build a hidden **Diagnostics** screen with one button per test and a log view. I'll run these on my iPhone and report.

- **S1 — Shield bleed:** shield native Instagram and YouTube via picker tokens. Do instagram.com / youtube.com still load in our WKWebView? In Safari? If our web view gets blocked, find a workaround (separate named stores, web-domain exceptions, etc.) or report and stop.
- **S2 — YouTube login:** WKWebView with (a) default UA, (b) the device's real mobile-Safari UA. Does Google sign-in complete? Does the session survive relaunch? Don't ship a UA-spoof login without telling me — it can break any day and may violate Google policy. Fallbacks to evaluate: logged-out YouTube Lite; a native "Subscriptions" list built from public channel RSS feeds (`/feeds/videos.xml?channel_id=…`) with channels imported from a Google Takeout subscriptions CSV — no login at all.
- **S3 — Instagram DMs:** inbox, open thread, send text/photo, **start a new chat**, open a reel from a DM, reply. Default UA vs Safari UA. Session persistence across relaunch and after the web content process is killed.
- **S4 — Notifications:** confirm shielded apps' notifications are suppressed; confirm an unshielded app's still arrive during a pass.
- **S5 — Wall:** `denyAppRemoval` works; with a Screen Time passcode on the newest iOS, try every revocation path (Screen Time > Apps with Screen Time Access; Settings > Apps > breakZero; delete app; Date & Time change). Record each result.
- **S6 — Performance:** memory with two warm web views; recovery from `webViewWebContentProcessDidTerminate`; cold-start timing.
- **S7 — Pass timing:** confirm the DeviceActivity minimum interval and that a 5-minute pass re-shields on time with the app force-quit.

---

## 7. Rule engine & reliability

**Recipe format** — one versioned JSON file per platform, roughly:
```json
{
  "platform": "instagram",
  "version": 12,
  "minEngine": 1,
  "hosts": ["instagram.com", "www.instagram.com"],
  "landing": {"default": "/direct/inbox/"},
  "routes": [
    {"pattern": "^/reels/?$", "action": "redirect", "to": "/direct/inbox/"},
    {"pattern": "^/explore", "action": "block"},
    {"pattern": "^/reels?/(?<id>[^/]+)", "action": "allowOnce", "scope": "fromThread"}
  ],
  "hide": [{"selector": "…", "routes": ["^/$"]}],
  "heuristics": [{"type": "anchorHref", "pattern": "/reels/", "hideAncestor": 2}],
  "allowZones": ["^/direct/", "^/accounts/", "^/challenge/", "^/create/"],
  "canaries": [{"route": "^/$", "mustNotExist": {"anchorHref": "/reels/"}}]
}
```

**Layers, in order:**
1. `WKContentRuleList` compiled from the recipe — blocks navigations/resources by URL; survives DOM changes.
2. `WKNavigationDelegate` policy for full loads + an injected route guard hooking `history.pushState`/`replaceState`/`popstate` for SPA navigation → redirect or bounce.
3. CSS hide stylesheet injected at `documentStart` (no flash of forbidden content).
4. `MutationObserver` heuristics (href/ARIA/structure-based), throttled with `requestAnimationFrame`.
5. **Canaries:** after load and on every route change, assert forbidden things are absent. If present → blur the region (or full overlay) with "Filter needs an update" and a one-tap report that opens a prefilled GitHub issue in Safari. No telemetry.

**Allow zones** (DMs, compose, settings, login, checkpoints): only route-level rules run there — no DOM heuristics. This protects core functionality from our own bugs.

**Rule updates without App Store review:** bundled recipes always ship. Optional daily fetch of signed recipes from one static URL (GitHub Pages/raw): Ed25519 signature verified with an embedded public key (CryptoKit), schema-validated, rejected if `minEngine` > current, last-good kept on failure. Data only — never JS.

**WKWebView hygiene:** persistent `WKWebsiteDataStore` (iOS 17+ identifiers to enable multi-account later); UA chosen per Spike S2/S3; inline media playback; file uploads with photo/camera usage strings; downloads saved to Photos; process-termination recovery with state restore; external links open in `SFSafariViewController` unless they belong to the same platform; never block login/2FA/checkpoint routes.

---

## 8. Notifications (needs my decision after S4)

Shielded apps go silent — that's iOS. Options:
- **A (v1 default):** accept and disclose clearly in onboarding; Lite tabs show unread counts when opened.
- **B (research, behind a flag):** on-device `BGAppRefreshTask` that checks the inbox using the existing web session and posts a local notification. iOS runs these rarely and unpredictably, and it could trip platform anti-automation. Prototype only if A proves to be a dealbreaker.
- **Never:** server-side polling that holds user sessions.

---

## 9. Architecture

- Swift 6, SwiftUI, **iOS 17.0 minimum**; wall hardening lights up on 26.4+.
- **XcodeGen** `project.yml` — no hand-edited `.pbxproj`.
- Targets: `App`; `ShieldConfiguration` extension; `ShieldAction` extension; `DeviceActivityMonitor` extension. Later: Safari Web Extension (reuses recipes), `DeviceActivityReport` extension for on-device usage stats.
- Swift packages: `Core` (WallPolicy, LockState, Recipe models, RuleEngine, NetworkPolicy, App Group storage), `LiteWeb` (WKWebView controller + bundled JS/CSS), `Shielding` (ManagedSettings/DeviceActivity wrappers behind protocols so logic is unit-testable with fakes).
- App Group storage: Codable JSON with file coordination (not just UserDefaults), shared by app and extensions.
- Separate named `ManagedSettingsStore`s (e.g. `wall.base`, `wall.pass`, `wall.schedule`) so passes and schedules can't clobber the base wall.
- Zero third-party dependencies unless I approve.

---

## 10. Testing

- **Unit:** RuleEngine URL classification/redirects (table-driven), WallPolicy ratchet/cooldown/Hard Lock with an injected clock, recipe decoding + signature verification, NetworkPolicy allowlist.
- **WebKit tests (Simulator OK):** load saved, scrubbed HTML fixtures into WKWebView, run the injected scripts, assert what's hidden/visible and that route guards fire.
- **Nightly canary (GitHub Actions, free for public repos):** Playwright WebKit with iPhone emulation against logged-out public pages (YouTube home, a `/shorts/` URL, a public IG profile) to detect selector rot; open an issue on failure.
- **On-device QA checklist** (`docs/QA.md`) run before every release: login, DM send, new chat, photo post, reel-from-DM, Shorts rewrite, shield → Lite redirect, pass re-lock with app force-quit, ratchet delay across reboot, revocation screen.
- **CI:** build + unit tests on every push.

---

## 11. Repo & docs

`README.md` (what, why, install, honest limits), `ARCHITECTURE.md`, `SECURITY_MODEL.md` (threat model for the wall: every known escape hatch by iOS version, with test date), `PRIVACY.md`, `RECIPES.md` (how anyone fixes a broken filter in 10 minutes), `docs/QA.md`, `CONTRIBUTING.md`, `LICENSE` (MIT unless I say otherwise). No telemetry, ever.

---

## 12. Phases & acceptance criteria

**Phase 0 — Skeleton + spikes.** Project builds via XcodeGen; all targets present with Development entitlement; Diagnostics screen with S1–S7; a checklist for me (entitlement request, App Group, signing). *Exit:* I report spike results; you update ARCHITECTURE.md.

**Phase 1 — Lite views (no Screen Time yet).** Instagram + YouTube recipes, rule engine layers 1–5, allow zones, persistent sessions.
- Cold start → usable IG inbox < 2 s; DM send succeeds 20/20; new chat works.
- No path in IG Lite reaches a scrollable Reels feed. Test at least: tab bar, profile reels grid, Explore link, swipe from a DM'd reel, search results, pasted URL, deep link, back/forward, in-page links, notifications page.
- YouTube: every `/shorts/` URL plays as a standard watch page; home never shows recommendations; autoplay never advances.

**Phase 2 — Shields & passes.** Onboarding picker, custom shields, notification deep-link, native pass with wait, cap, and log.
- Shield → Lite tab in ≤ 2 taps.
- Pass re-shields within 1 minute of expiry with the app force-quit.

**Phase 3 — The Wall.** Ratchet, pending queue, Hard Lock, `denyAppRemoval`, "Lock it in" guide, revocation screen, clock-tamper checks.
- A loosening change never applies before its cooldown, including across app kill and reboot.

**Phase 4 — Ship-ready.** Signed recipe updates, canaries + report flow, CI + nightly canary, all docs, TestFlight build, App Store privacy answers = Data Not Collected.
- App < 25 MB; network capture shows only allowed hosts.

**Phase 5 — Next.** v1.1 platform (Snapchat), then v1.2 (Reddit, X, Facebook), Safari Web Extension, schedules/sleep mode, on-device usage stats, multi-account.

---

## 13. Decisions (defaults until I say otherwise)

| Decision | Default |
|---|---|
| App name | `breakZero` |
| License | MIT |
| v1 platforms | Instagram + YouTube |
| Notifications | Option A (disclose) |
| YouTube login | Decide after Spike S2 |
| Cooldown default | 24 h |
| Native pass | 5 min, 30 s wait, 2/day |
| Min iOS | 17.0 |
