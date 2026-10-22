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
# Launch agent for the background publisher (registered from Settings).
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Config/com.reelmanager.app.publisher.plist "$APP/Contents/Library/LaunchAgents/"
plutil -lint "$APP/Contents/Library/LaunchAgents/com.reelmanager.app.publisher.plist"

# App icon: draw it, then pack every size into an .icns.
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$OUT/AppIcon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$OUT/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: not notarized, but required for arm64 and keeps the
# Keychain and URL-scheme handling happy.
codesign --force --deep --sign - "$APP"

ditto -c -k --keepParent "$APP" "$OUT/ReelManager.zip"
echo "Built $OUT/ReelManager.zip"
