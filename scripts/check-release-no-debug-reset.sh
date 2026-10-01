#!/usr/bin/env bash
# Proves the Debug-only "Reset all breakZero data" is compiled out of Release builds
# (ARCHITECTURE.md §4e). Builds Release for the Simulator, unsigned, and fails if the reset's
# marker string or its Diagnostics label is in the app binary.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/release-check}"
xcodegen generate >/dev/null
xcodebuild -scheme breakZero -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$OUT" CODE_SIGNING_ALLOWED=NO build >/dev/null
APP=$(find "$OUT/Build/Products" -name breakZero.app -type d -path '*Release-iphonesimulator*' | head -1)
# Dump strings to a file first: `strings | grep -q` under pipefail fails on SIGPIPE when grep
# matches early, which would hide exactly the case we're checking for.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for f in "$APP"/breakZero "$APP"/*.dylib; do [ -f "$f" ] && strings "$f" >> "$TMP/release.txt"; done
for needle in BZ_DEBUG_RESET_MARKER "Reset all breakZero data"; do
  if grep -qF "$needle" "$TMP/release.txt"; then
    echo "FAIL: '$needle' found in the Release build ($APP)"; exit 1
  fi
done
# The same strings must be present in Debug, or this check proves nothing.
xcodebuild -scheme breakZero -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$OUT-debug" CODE_SIGNING_ALLOWED=NO build >/dev/null
DAPP=$(find "$OUT-debug/Build/Products" -name breakZero.app -type d -path '*Debug-iphonesimulator*' | head -1)
for f in "$DAPP"/breakZero "$DAPP"/*.dylib; do [ -f "$f" ] && strings "$f" >> "$TMP/debug.txt"; done
grep -qF BZ_DEBUG_RESET_MARKER "$TMP/debug.txt" || { echo "FAIL: marker missing from Debug too; check is broken"; exit 1; }
echo "OK: debug reset is in Debug and absent from Release"
