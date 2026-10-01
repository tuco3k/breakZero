# breakZero — working rules for Claude Code

`BRIEF.md` is the spec and the source of truth. This file is the short list of rules that must survive every context compaction.

## Start of every session (and after any compaction)
1. Read `PROGRESS.md`, then `QUESTIONS.md`, then the parts of `BRIEF.md` relevant to the next task.
2. Continue from the "Next" list in `PROGRESS.md`. Don't redo finished work.

## While working
- The owner may be asleep. Don't stop to ask. Log the question and the default you chose in `QUESTIONS.md`, then continue.
- After each milestone (a target builds, a module's tests pass, a phase item is done): update `PROGRESS.md`, make a small commit with a clear message, and push.
- Anything that needs the owner's iPhone, Apple Developer account, or signing goes into `docs/ON_DEVICE_CHECKLIST.md` as a numbered step. Then move on.
- Never add third-party dependencies to the app, StoreKit, ads, analytics, crash SDKs, or network calls to hosts not allowed in `BRIEF.md` §2. Dev-only tooling that never ships in the app (XcodeGen, a JS DOM library for tests) is fine; note each one in `QUESTIONS.md`.
- If a command gets blocked (permission classifier, egress policy), don't try privileged workarounds such as mounts. Log it in `PROGRESS.md` under Blockers and move on.
- Subtractive filters only: hide, redirect, block. Never rewrite a site's DMs, composer, upload, or login UI.

## Verifying work (pick the case that matches the machine)

**macOS with Xcode** (`xcodebuild -version` works):
- Generate the project with XcodeGen (`xcodegen generate`); never hand-edit `.pbxproj`.
- Build and test for the Simulator with signing off, e.g. `xcodebuild -scheme breakZero -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO build test` (pick a simulator that `xcrun simctl list devices available` shows).
- A milestone isn't done until the build and its tests pass.

**Linux / cloud session** (no Xcode):
- You cannot build the iOS app here. Don't try to install Xcode.
- Keep pure logic (RuleEngine, recipe models, WallPolicy/LockState ratchet math, NetworkPolicy) in Swift package targets with no Apple-only imports, and put UIKit/WebKit/FamilyControls/CryptoKit code behind `#if canImport(...)` or protocols, so the logic can be tested with `swift test` on Linux.
- If a Swift toolchain isn't installed, try to install one for up to ~10 minutes. If that fails, keep writing code and tests anyway.
- Mark every file that hasn't been compiled as **UNVERIFIED** in `PROGRESS.md`, so the owner knows what to build first on the Mac.
- Write the injected JS/CSS filter scripts so they can also be tested with Node (no browser-only globals at module top level), and test them with Node against HTML fixtures where you can.

## Commits
- Small, focused commits. Never force-push. Never commit secrets, signing certificates, or provisioning profiles.
