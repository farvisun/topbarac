#!/bin/bash
# Builds Topbarac.app into ./build. Usage: scripts/build-app.sh [debug|release] [--run]
# UNIVERSAL=1 builds for Apple silicon and Intel (the release workflow does).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Topbarac.app"

ARCHS=()
if [ "${UNIVERSAL:-0}" = 1 ]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product Topbarac
BIN_PATH="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH/Topbarac" "$APP/Contents/MacOS/Topbarac"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle (updates from the GitHub release appcast).
ditto "$BIN_PATH/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if [ "$CONFIG" = "release" ]; then strip -x "$APP/Contents/MacOS/Topbarac" || true; fi
# Sign inside out (no --deep, which would drop the Downloader's entitlements).
SIGN=(codesign --force --sign - --timestamp=none)
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${2:-}" = "--run" ]; then
  pkill -x Topbarac || true
  open "$APP"
fi
