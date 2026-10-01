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
- [ ] A finished video never auto-advances
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
