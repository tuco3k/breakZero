# Security model of the wall

Threat: **you, in a weak moment**, with your own unlocked phone. Not a remote attacker. The goal is
to make loosening slow and deliberate, and to be honest about what can't be prevented.

Status: **nothing below has been tested on a device yet.** Each row gets a result and a test date
from Spike S5 (`docs/ON_DEVICE_CHECKLIST.md` step 12). Until then, rows are hypotheses from BRIEF §3.

## Escape hatches

| # | Path | iOS < 26.4 | iOS 26.4+ with Screen Time passcode | Tested (date, iOS) |
|---|---|---|---|---|
| 1 | Settings › Screen Time › Apps with Screen Time Access › breakZero off | Face ID / device passcode is enough → wall down | Screen Time passcode required | — |
| 2 | Settings › Apps › breakZero › Screen Time toggle | Face ID enough | Reported to still ask only for Face ID on 26.4 — must test | — |
| 3 | Delete breakZero | Blocked by `denyAppRemoval` while authorized (not guaranteed under `.individual`) | Same | — |
| 4 | Forgot Screen Time passcode → reset with Apple Account | n/a | Works for whoever owns the recovery Apple Account → have a trusted person use **their** account | — |
| 5 | Change date/time forward to end a cooldown | Doesn't work: cooldowns use trusted elapsed time (below) | Same; check whether the passcode locks "Set Automatically" | — |
| 6 | Reboot to reset uptime | Gains at most 1 hour per reboot (below) | Same | — |
| 7 | Use Safari / another browser for the platforms | Not blocked unless web domains are shielded (max 50 tokens) | Same | — |
| 8 | Use another device | Not preventable | Same | — |

When the wall comes down (1, 2), iOS lifts all shields immediately and breakZero isn't told while
in the background. On next launch (and in every extension callback) breakZero re-checks
authorization, records when the wall was last verified intact, and shows a calm screen offering to
rebuild it. No shaming, no partner notifications (that would need a server).

## Spike results

| Spike | Date, device | Result |
|---|---|---|
| S2 YouTube sign-in (WebKit default UA, lite build, free team, **VPN on**) | 2026-10-01, owner's iPhone | Google warned that the browser "didn't seem trustworthy" and made the owner sign in **twice**; after that, signed-in YouTube worked and landed on Subscriptions. Signed out, Subscriptions is a dead page. Whether the VPN triggered the warning is unknown (retest without it). Safari UA not yet tried. |

What S2 means here: Google's embedded-browser check is outside our control and may tighten. So
signed-in web YouTube stays an option, and the login-free fallback (BRIEF §6 S2) now exists: a
native Subscriptions list from public channel RSS feeds, channels imported from a Google Takeout
CSV, videos opened signed-out in the YouTube lite view. Signed out, the YouTube tab lands on Search.
We don't spoof the user agent for login without the owner's go-ahead (BRIEF §6).

## Cooldowns and the clock
Loosening changes wait for the cooldown, measured as **trusted elapsed time**
(`Core/TrustedClock.swift`), recorded at every check-in (app launch/foreground, every extension
callback):

- Within one boot: credit `min(wall-clock delta, monotonic uptime delta)`. Uptime includes sleep
  (`CLOCK_MONOTONIC` on Darwin) and can't be changed by the user, so moving the clock forward
  credits nothing; moving it back only slows you down.
- Across a reboot: uptime restarts and the gap before the reboot is unknowable. We credit at most
  the new boot's uptime **plus 1 hour**. Residual risk: an attacker gains ≤ 1 hour per reboot; a
  legitimate user may wait up to (gap − 1 h) longer than the cooldown after a reboot.
- Every detected jump is logged locally (`ElapsedLedger.tamperEvents`).
- Hard Lock ends only when **both** the wall clock passes its date **and** trusted time has elapsed.
- A native pass ends at its wall-clock end **or** when its duration of trusted time has passed,
  whichever is first, so setting the clock back can't stretch it. The daily cap counts passes
  "started today" plus any whose start is in the future.

## Time limits, short-form budget and schedules
- Usage counts only while a lite tab is on screen in the foreground, in trusted time (same rule as
  cooldowns), at most 30 s per tick, saved every 5 s. Killing the app loses at most ~5 s of counted
  use; time while killed or in the background is never counted.
- The day resets at local midnight of a trusted clock estimate, in the time zone pinned when the day
  started, and a day is at least 20 h. Clock and time-zone changes can't reset or extend anything
  early. Residual: a reset comes **late** after a long power-off (the reboot gap is credited at most
  1 h) or after flying east.
- Raising a limit, adding budget minutes, turning the budget on and removing a schedule wait for the
  cooldown; extra time only through a pass (purpose, wait, daily cap, logged).
- The watchdog runs in the page and natively, each every second. The page part is in the page's own
  JavaScript world (needed to hook navigation), so the site could in principle call `__bzUpdate`
  and loosen the page's copy of the rules; the native watchdog doesn't trust the page and enforces
  independently.
- **Free (lite) build:** deleting the app deletes the usage, the limits and the wall itself. Only the
  Screen Time build can block deleting breakZero (`denyAppRemoval`).

## Feed rules (mutuals only)
- Widening what you see (a broader rule, Always show, removing from Never show, profile stories
  on, rules off) waits the cooldown; narrowing is instant. Refreshing who is mutual (import,
  re-sync, manual) is data, not a rule change: no cooldown. A newly mutual person appears after a
  refresh; an import with no following list is rejected, so the data can't be emptied to switch
  the rules off.
- The story gate is engine code run by every layer (navigation delegate, page guard, native
  backstop, both watchdogs). The feed is default-deny in CSS: if the script can't run, the feed is
  empty rather than unfiltered.
- Residual: the feed filter runs only in the page (native can't see the DOM). A site change that
  renders posts outside `article` shows them; the canary blurs them and asks for a report. Story
  tray items without a link can't be checked (the gate still stops them playing).
- Residual: a stories session opened from a profile is remembered in the page's navigation state;
  the periodic watchdog, which has no "came from", closes to the feed instead of the profile.
- The page script runs in the page's world, so the site could post fake names while a scan or
  sync runs (they become data: mutuals widen only if both lists contain them), or a fake "hide"
  (only ever a narrowing).

## Turning the Lock on by accident
- Press-and-hold confirmation for the Lock, Block deleting and Hard Lock.
- 10-minute undo window (setting can only be shortened). It ends at the earliest of wall clock,
  uptime, a reboot or the clock moving back, so clock tricks can only end it early. A Hard Lock
  still blocks the undo.

## Defense in depth
- Pending changes apply from the DeviceActivityMonitor extension at their due time, so they land
  without the app; every launch reconciles too.
- A corrupt settings file never reads as "no wall": updates fail instead of resetting.
- Separate named `ManagedSettingsStore`s; Diagnostics uses its own store.

## Recommended setup ("Lock it in", Phase 3)
1. Keep Date & Time on *Set Automatically*.
2. Have a trusted person set the Screen Time passcode and enter **their own** Apple Account for
   recovery.
3. Turn on *Block deleting breakZero*.
