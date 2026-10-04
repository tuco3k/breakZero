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

## Feed rules (mutuals only): try to break it (on device)

**Import a real export** (recommended setup)
- [ ] Wall › Instagram › Feed rules › *Import Instagram data*: follow the in-app steps (JSON, only
      "Followers and following"). Import the .zip from Files. The summary reads like
      "412 mutuals, 1,830 following, 960 followers" and appears within a few seconds
- [ ] Import the same export as HTML: a plain message says to request JSON
- [ ] Import only `followers_1.json`: it says the following list is missing; nothing changes
- [ ] "Mutuals last updated today"; the pill says "Mutuals only · N hidden"

**Auto-scroll sync on a large account** (optional path)
- [ ] Re-sync: read the warning, type your username, Start. Your Followers opens and scrolls by
      itself slowly (a screen every 2–4 s, longer pauses), then Following
- [ ] It stops by itself after 800 new names per list; *Continue* later carries on
- [ ] Tap away to another page while it runs: it stops ("the list was closed")
- [ ] If Instagram shows any warning, challenge or login: it stops at once and says so
- [ ] After both lists finish: mutual counts match the export within a few people

**Feed and stories by rule**
- [ ] Feed: only mutuals' posts; no brands, creators, suggested posts or ads. Scroll 2–3 minutes:
      never a non-mutual post, not even for a moment; then "You're all caught up"
- [ ] Each shown post has a small *Hide* button: tap it, the post disappears, the toast says
      "Hidden @name"; hide three quickly: one toast "Hidden 3 accounts"
- [ ] Tap the pill: *Hidden recently* lists who was hidden; *Always show* waits the cooldown (Lock
      on), *Never show* is instant
- [ ] Feed shows / Stories show: try Everyone I follow, My list, Close Friends. Narrowing is
      instant; widening waits the cooldown (Lock on)
- [ ] Stories tray: only allowed people. Tap through fast to the end: never a flash of someone
      else; it skips to the next allowed person or closes
- [ ] A non-mutual's profile: it opens. Tap their story ring: it plays, only them; it never moves
      on to someone else (back on their profile)
- [ ] Turn *Play stories from profiles I open* off: tapping the ring keeps you on their profile with
      a short message, no reload, never the feed
- [ ] Never show someone who is mutual: their posts and stories are gone, their profile still opens
- [ ] While a story plays, the strip offers "Hide @name"

**Still works with feed rules on**: DMs (send, photo, new chat, reply to a story), search, any
profile, posting, notifications, settings, log out and in.

## Limit modes (on device)
- [ ] Daily time: Per app / All apps together / Both. Set 7 minutes (type it): applies at once
      (lowering); raising to 9 waits the cooldown (Lock on)
- [ ] Reels/Shorts: Per app (Instagram 2 min, YouTube 5 min), One budget for all, Both. At 2:00
      Reels stop within about a second while Shorts keep working; with Both, the first to run out wins

## Accidental activation (on device)
- [ ] Turn the Lock on: a sheet explains what gets locked and the cooldown; a single tap does
      nothing, press and hold turns it on
- [ ] The Wall tab shows "The Lock is on · You can undo it for 9:59" counting down; *Undo* turns it
      off instantly
- [ ] After 10 minutes the Undo is gone and turning the Lock off waits the cooldown
- [ ] Move the clock forward or back during the 10 minutes: the Undo ends early, never later
- [ ] Undo window setting: shortening is instant, lengthening waits
- [ ] Block deleting breakZero and Hard Lock also need press and hold
- [ ] Debug build: Diagnostics › *Reset all breakZero data* clears everything (you're signed out)
      and closes the app. Not present in release builds (`scripts/check-release-no-debug-reset.sh`)

## Toasts (on device)
- [ ] Only ever one toast, at the top; it never blocks a tap and disappears after about 2 s

## Instagram search (on device)
- [ ] Default (Normal): the search icon is in Instagram's bottom bar; tapping it opens the search box
      straight away, never the Explore grid of posts
- [ ] Search finds anyone, including people you don't follow; opening any of them shows their
      profile normally
- [ ] No grid of posts or reels appears on the search page, before or after typing; tapping a
      hashtag or place goes back (those pages stay blocked)
- [ ] Wall › Instagram › Search › *Only accounts that match my feed rules*: applies at once;
      results now show only people your feed rule allows (others are simply missing)
- [ ] *Off*: applies at once; the search icon disappears
- [ ] With the Lock on, going from Off back to Normal waits the cooldown

## Home feed never flashes (on device)
- [ ] Open the feed and scroll fast for 2 minutes, up and down: no post ever appears and then
      vanishes, not even briefly; the feed doesn't jump or stutter
- [ ] Pull to refresh, then scroll again: same
- [ ] Go Home → a profile → Back, and Home → a story → close: no flash on returning
- [ ] While many posts in a row are hidden, a small "Finding posts from your people…" shows, then
      "You're all caught up" at the end
- [ ] Stories tray: no circle of someone outside your rules ever appears, even for a moment
- [ ] Wall › version 5× › Diagnostics › *F1 · Feed never flashes* › *Watch the feed for flashes*:
      scroll for 30 s; the result is 0 and Spike results shows F1 PASS. If not, also tap *Report what
      the feed is made of* and send both log lines

## What is the Wall? (on device)
- [ ] First time on the Wall tab it opens by itself; afterwards from *What is the Wall?*
- [ ] It uses your real cooldown and undo time (change the cooldown, reopen: the text changes)
- [ ] "What it can't stop" fits this version (free build: deleting the app removes the Lock; the real
      apps and Safari aren't blocked)
- [ ] Turning the Lock on shows the short version (what's locked, how long changes wait) above the
      hold-to-turn-on button
- [ ] Every Wall setting has one plain line underneath; nowhere does it say "loosen", "tighten",
      "ratchet" or explain things with the word "wall"
