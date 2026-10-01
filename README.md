# breakZero

Free, open-source "lite" Instagram and YouTube for iPhone, with a wall you can't easily climb.

Use the parts you choose — messages, people you follow, posting, your subscriptions — while the
parts built to hook you (Reels, Shorts, Explore, recommendations, autoplay chains) are hidden or
blocked. Optionally shield the native apps with Screen Time so tapping them sends you to the lite
version, and lock your settings so loosening them takes a day.

> **Status: early development.** Nothing has been released. See `PROGRESS.md`.

## Free in every way
No in-app purchases, no subscriptions, no ads, no analytics, no crash SDKs, no account, no server.
App Privacy: **Data Not Collected** — see [PRIVACY.md](PRIVACY.md).

## How it works
- Each platform opens in its own web view with five filter layers: URL blocking, a route guard,
  CSS hiding, structure-based heuristics and "canaries" that cover anything a filter missed with a
  *Filter needs an update* banner. Filters never touch DMs, the composer, uploads or login.
- Filters are plain JSON **recipes** ([RECIPES.md](RECIPES.md)), so a broken filter can be fixed in
  minutes, by anyone.
- **The wall:** tightening a setting applies instantly; loosening it waits for a cooldown (24 h by
  default), measured in a way that changing the clock doesn't speed up.

## Honest limits
- Anyone who can turn off breakZero's Screen Time access can take the wall down. A Screen Time
  passcode set by someone you trust makes that much harder (strongest on iOS 26.4+). See
  [SECURITY_MODEL.md](SECURITY_MODEL.md) for every known escape hatch.
- Shielded apps can't send notifications. Lite tabs show unread counts when you open them.
- breakZero can't stop you using another browser or another device.
- Some features need the native app (music on stories, close friends). Use a short, logged
  *native pass* for those.

## Build
See `docs/ON_DEVICE_CHECKLIST.md`. In short: `xcodegen generate`, open `breakZero.xcodeproj`,
set your team. Logic tests: `cd Packages/BreakZeroKit && swift test`. Filter script tests:
`cd jstests && npm ci && npm test`.

## Docs
[ARCHITECTURE.md](ARCHITECTURE.md) · [SECURITY_MODEL.md](SECURITY_MODEL.md) · [PRIVACY.md](PRIVACY.md) ·
[RECIPES.md](RECIPES.md) · [CONTRIBUTING.md](CONTRIBUTING.md) · [docs/QA.md](docs/QA.md)

MIT licensed.
