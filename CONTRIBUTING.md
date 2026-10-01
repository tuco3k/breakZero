# Contributing

Thanks! Read `BRIEF.md` (the spec) and `ARCHITECTURE.md` first.

Non-negotiables: no third-party dependencies in the app, no analytics/ads/StoreKit, no network
calls except through `NetworkPolicy`, subtractive filters only, never match visible text.

- Logic lives in `Packages/BreakZeroKit` and must build on Linux: `swift test` there.
- Filter script: `jstests/` (`npm ci && npm test`).
- App: `xcodegen generate`, never edit the `.pbxproj`.
- Broken filter? See `RECIPES.md`.
- Small, focused commits. Tests with every change.
