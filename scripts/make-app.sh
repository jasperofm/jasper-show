#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) ReelManager.app and zips it.
# Usage: scripts/make-app.sh [output-dir]
set -euo pipefail
OUT="${1:-dist}"
APP="$OUT/ReelManager.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ReelManager"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReelManager"
cp Config/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: not notarized, but required for arm64 and keeps the
# Keychain and URL-scheme handling happy.
codesign --force --deep --sign - "$APP"

ditto -c -k --keepParent "$APP" "$OUT/ReelManager.zip"
echo "Built $OUT/ReelManager.zip"
