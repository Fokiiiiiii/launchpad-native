#!/bin/sh
# Builds AppHost via SwiftPM and assembles a proper LaunchpadNative.app bundle
# (LSUIElement, no Dock icon) without requiring the full Xcode.app IDE.
#
# The repo lives under ~/Documents, which is iCloud-synced; SwiftPM's build
# database gets disk I/O errors if .build is placed inside a synced folder,
# so the scratch path is redirected outside of iCloud's reach.
set -eu

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$HOME/.cache/launchpad-native/build"
APP="$SCRATCH/LaunchpadNative.app"

swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c "$CONFIG"

BIN="$SCRATCH/$CONFIG/AppHost"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/AppHost"

echo "Built $APP"
