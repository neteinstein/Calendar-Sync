#!/usr/bin/env bash
# Builds "Calendar Sync.app" into ./build.
#
#   scripts/build-app.sh                       # ad-hoc signed, for your own Mac
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
#                                              # signed for sharing (then notarize, see README)
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Calendar Sync.app"
IDENTITY="${SIGN_IDENTITY:--}"

# UNIVERSAL=1 builds for Apple silicon and Intel (needs full Xcode, not just the command line tools).
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release --product CalendarSync ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release --product CalendarSync ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/CalendarSync"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CalendarSync"
cp Support/Info.plist "$APP/Contents/Info.plist"

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp \
    --entitlements Support/CalendarSync.entitlements \
    --sign "$IDENTITY" "$APP"
fi

echo "Built $APP"
