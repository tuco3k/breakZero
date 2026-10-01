# Progress

Claude Code keeps this file current. Read it first in every session.

## Status
Phase 0 in progress (Linux cloud session, no Xcode).

## Phase 0 task plan
- [x] P0.1 Read BRIEF/CLAUDE, draft `ARCHITECTURE.md`
- [ ] P0.2 Swift toolchain on Linux (for `swift test` of Core)
- [ ] P0.3 `Packages/BreakZeroKit` skeleton: Core / LiteWeb / Shielding products + tests
- [ ] P0.4 `project.yml` (XcodeGen): App + ShieldConfiguration + ShieldAction + DeviceActivityMonitor, Development Family Controls entitlement, App Group
- [ ] P0.5 App shell: tab bar, Wall tab, hidden Diagnostics screen with S1–S7 buttons + log view
- [ ] P0.6 Extension stubs that read the App Group and log to the diagnostics log
- [ ] P0.7 `docs/ON_DEVICE_CHECKLIST.md`: entitlement request, App Group, signing, how to run S1–S7
- [ ] P0.8 Repo docs skeleton: README, LICENSE (MIT), PRIVACY, SECURITY_MODEL, RECIPES, CONTRIBUTING, docs/QA
- [ ] P0.9 CI workflow (Linux `swift test` + Node script tests)

## Done
- (nothing yet)

## Next
1. P0.2 → P0.9 above, in order.
2. Then Phase 1: recipes, RuleEngine, content rule list builder, injected JS (route guard, CSS, heuristics, canaries) with Node tests, LiteWeb controller.

## Unverified (written but never compiled or run)
- (none yet)

## Blockers
- (none yet)
