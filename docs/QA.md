# Release QA checklist (on device)

Run before every release. Record device, iOS version, date, pass/fail per line.

## Instagram lite
- [ ] Log in (incl. 2FA / checkpoint) — session survives relaunch and a web-content-process kill
- [ ] DM: open thread, send text 20/20, send photo, send video, **start a new chat**, reply to a shared post
- [ ] Reel sent in a DM plays; swiping to the next reel bounces back to the thread
- [ ] No path reaches a scrollable Reels feed: tab bar, profile reels grid/tab, Explore link,
      search results, pasted `/reels/` URL, deep link, back/forward, in-page links, notifications page
- [ ] Home: no suggested posts / sponsored posts; stories from follows work
- [ ] Post a photo via the web composer; settings and activity pages work
- [ ] Cold start to usable inbox < 2 s (iPhone 12-class)

## YouTube lite
- [ ] `/` lands on Subscriptions; every `/shorts/ID` opens as a normal watch page
- [ ] No Shorts shelves/tabs; no home recommendations; no related/up-next; no end-screen cards
- [ ] A video you open starts playing without an extra tap (QUESTIONS #27)
- [ ] A finished video never auto-advances (also with the autoplay switch in the player turned on)
- [ ] Search, library, playlists, watch later, history, channel pages work; player untouched

## Shields & passes
- [ ] Opening a shielded app shows the breakZero shield; "Open lite version" reaches the lite tab in ≤ 2 taps
- [ ] Native pass: purpose, wait, unshield; re-shields within 1 min of expiry **with breakZero force-quit**
- [ ] Daily cap enforced; passes logged

## Wall
- [ ] Loosening change waits the cooldown, including across app kill and **reboot**
- [ ] Changing the date forward doesn't apply it early
- [ ] Hard Lock rejects loosening
- [ ] Revoking Screen Time access shows the revocation screen with the last-verified time

## Release
- [ ] App size < 25 MB; network capture shows only allowed hosts
- [ ] App Store privacy answers: Data Not Collected

## Limits, budgets and schedules: try to break them (on device)

Set short values first (Wall › Limits): Instagram 15 min a day, Reels/Shorts budget 5 min, and
schedules "Block Reels, Shorts and Spotlight" starting a minute from now and "All of Instagram"
starting two minutes from now. Turn the Lock on. For **every** line below, the expected result is a
hard stop: the forbidden page never stays on screen for more than about a second, media stops, a
short reason shows in the strip at the top, and Diagnostics › Log has a `watchdog` line.

Short-form budget (use it up first by watching Reels/Shorts for 5 minutes):
- [ ] Mid-reel when the budget hits zero: the reel stops and you're moved to the inbox
- [ ] Mid-Short on YouTube when it hits zero: the Short stops and opens as a normal watch page
- [ ] Reels tab / profile Reels tab / Explore link / a reel link in search results
- [ ] Swipe up to the next reel from a reel; swipe back with the edge gesture
- [ ] Browser back and forward buttons into a reel you watched earlier today
- [ ] Paste a `/reels/` or `/shorts/` URL (e.g. into a DM, then tap it)
- [ ] Deep link: open an instagram.com/reel/… link from Notes or Messages
- [ ] A reel someone sent you in a DM still plays once (the default wall); the next one bounces back
- [ ] Kill the app and reopen it on a reel: blocked within a second
- [ ] Background the app for 10 minutes: the budget doesn't go down while away
- [ ] Next day after midnight: Reels/Shorts work again for 5 minutes

Daily limit (Instagram 15 min):
- [ ] At 15 minutes the tab shows "That's Instagram for today" and audio stops
- [ ] Deep link into instagram.com while blocked: still the done screen
- [ ] Kill and reopen: still the done screen
- [ ] "Request a pass": purpose, wait, then the pass works for its minutes and the done screen
      comes back when it ends (also with the app killed during the pass)
- [ ] Passes stop at the daily cap

Schedules:
- [ ] At the start minute, an open reel is stopped (short-form schedule)
- [ ] At the start minute, all of Instagram shows "off right now" with the end time (platform schedule)
- [ ] Removing a schedule goes to "Waiting to apply"; adding one applies at once

Clock and time zone (all must change nothing):
- [ ] Settings › General › Date & Time: turn off *Set Automatically*, move the clock forward a day:
      limits don't reset, schedules don't end
- [ ] Move the clock back a few hours: no extra time, schedules don't restart early
- [ ] Change the time zone to one where it's already tomorrow: no early reset
- [ ] Reboot the phone: nothing resets early (a reset after a long power-off may come late; that's expected)

Ratchet:
- [ ] Lowering a limit or adding a schedule: instant
- [ ] Raising a limit, adding budget minutes, removing a schedule, turning the budget on: waits for the cooldown
