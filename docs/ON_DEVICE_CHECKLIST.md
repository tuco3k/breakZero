# On-device checklist (for the owner)

Things only you can do: they need your iPhone, your Apple Developer account, or signing.
Work top to bottom. Each step says what to report back (paste into a GitHub issue or the chat).

Nothing here has been built yet: this repo was written in a Linux session with no Xcode. Every
Swift file outside `Packages/BreakZeroKit/Sources/Core` and the pure parts of `LiteWeb`/`Shielding`
is **UNVERIFIED** (see `PROGRESS.md`). Expect a round of compile fixes in step 4.

## A. Accounts and entitlements (do these first — they have lead time)

1. **Request the Family Controls (Distribution) entitlement** at
   https://developer.apple.com/contact/request/family-controls-distribution — approval is
   team-scoped and can take a day to weeks. Not needed for on-device testing (Development works).
   Requires a paid Apple Developer Program membership (BRIEF §3).
2. **Pick identifiers.** Defaults in `project.yml`: bundle ID `com.tuco3k.breakzero`, App Group
   `group.com.tuco3k.breakzero`. If you change either, also change `AppGroup.appGroupID` in
   `Packages/BreakZeroKit/Sources/Core/SharedStore.swift` (QUESTIONS.md Q2).
3. **Register the App Group** in Certificates, Identifiers & Profiles (or let Xcode's automatic
   signing do it), and enable the *Family Controls* capability on the app ID and all three
   extension IDs (`.ShieldConfiguration`, `.ShieldAction`, `.DeviceActivityMonitor`).

## B. Build

4. On the Mac: `brew install xcodegen`, then in the repo root `xcodegen generate`.
   Set `DEVELOPMENT_TEAM` in `project.yml` (top-level `settings.base`) or in Xcode's Signing tab.
   - First: `cd Packages/BreakZeroKit && swift test` (should pass; it already passes on Linux).
   - Then: `xcodebuild -scheme breakZero -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO build test`
   - Fix compile errors in the UNVERIFIED files (start with `LiteWebController.swift`,
     `ScreenTime.swift`, then `App/`, then `Extensions/`). Report anything structural.
   - **No Family Controls entitlement yet** (or signing trouble with the extensions)? Set
     `BZ_SCREEN_TIME: NO` in `project.yml` (or pass `BZ_SCREEN_TIME=NO` to `xcodebuild`). That
     build has no Family Controls entitlement, leaves the three Screen Time extensions out of the
     app, and compiles out every Screen Time call, so you can run the lite views (section D)
     right away. Spikes S1 shielding, S5 and S7 need `YES`. To confirm the switch works, run the
     CI workflow manually with *ios_build* ticked (it checks 3 extensions embedded vs 0), or look
     inside the built `breakZero.app/PlugIns`.
5. Run on your iPhone (Debug, Development signing). In the app, open **Wall** and tap the
   version line at the bottom **5 times** to open **Diagnostics**.
6. Diagnostics → **Request Screen Time authorization**. Report: did the system sheet appear and
   what status is shown afterwards?
7. Diagnostics → **Pick apps for spikes** → choose Instagram and YouTube (and TikTok if
   installed). Diagnostics → **Ask for notification permission** → Allow.

## C. Spikes (BRIEF §6). Use the Log section's share button to send me the log after each.

8. **S1 Shield bleed.** Tap *Shield picked apps*. Open native Instagram/YouTube: you should see
   the breakZero shield. Then tap each *Load … in a test web view* button (shared store and named
   store) and the *Open … in Safari* buttons. Report for each: loads / blocked / error code.
   Finally tap *Clear diagnostics shields*.
9. **S2 YouTube login.** Tap *YouTube sign-in · WebKit UA*, try to sign in. Then *Safari UA*.
   Report: does Google show `disallowed_useragent`? Does sign-in complete? Force-quit, relaunch,
   tap *Check YouTube session*: present/absent?
10. **S3 Instagram DMs.** Tap *Instagram inbox · WebKit UA*, log in. Test: open a thread, send text,
    send a photo, **start a new chat**, open a reel someone sent you, reply. Repeat with Safari UA if
    anything fails. Force-quit, relaunch, *Check Instagram session*. Report each item pass/fail.
11. **S4 Notifications.** With Instagram shielded (step 8), have someone DM you. Did a notification
    arrive? Then start an S7 pass (step 14) and repeat. Also tap *Post a test local notification*,
    background the app, tap the notification: does it open the Instagram tab?
12. **S5 Wall.** Set a Screen Time passcode (ideally someone else enters it, with *their* Apple
    Account for recovery). Tap *Set denyAppRemoval*. Try every path listed in the S5 section and tap
    *Held* or *Bypassed* for each. Note your exact iOS version (the log records it). Then
    *Clear denyAppRemoval*.
13. **S6 Performance.** Tap *Warm both lite views, log memory in 10 s*. Force-quit, relaunch, wait
    for the Instagram tab to load, then read the `S6 first load` line in the log.
14. **S7 Pass timing.** Re-shield (step 8). Tap *Start 5-min pass (backdated interval)*, confirm
    Instagram opens normally, **force-quit breakZero**, wait ~6 minutes, open Instagram again: is it
    shielded? Report the `S7 intervalDidEnd … s after expected` log line. Then try the
    *exact interval* buttons: does the 5-minute one fail with an error (15-minute minimum)?

## D. Lite views (Phase 1, no Screen Time needed)

15. Instagram tab: log in. Walk the Phase 1 list in `docs/QA.md` (tab bar, profile reels grid,
    Explore link, swipe from a DM'd reel, search, pasted URL, back/forward, notifications page).
    Report any path that reaches a scrollable Reels feed, and anything that broke DMs.
16. YouTube tab: open a `/shorts/…` link (e.g. paste one in the search box or open one from
    Subscriptions): it should open as a normal watch page. Let a video finish: autoplay must not
    advance. Report whether the subscriptions page shows any Shorts.
17. If any page shows a **"Filter needs an update"** banner, tap *Report* and paste the issue link.
