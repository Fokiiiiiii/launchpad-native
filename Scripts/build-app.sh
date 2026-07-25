#!/bin/sh
# Builds AppHost via SwiftPM and assembles a proper LaunchpadNative.app bundle
# (LSUIElement, no Dock icon) without requiring the full Xcode.app IDE.
#
# The repo lives under ~/Documents, which is iCloud-synced; SwiftPM's build
# database gets disk I/O errors if .build is placed inside a synced folder,
# so the scratch path is redirected outside of iCloud's reach.
#
# The assembled bundle is also installed to ~/Applications — the raw
# $SCRATCH build output lives under ~/.cache, a dot-prefixed directory
# Finder hides by default, so an app that only ever existed there was
# real-world unfindable (a user had no way to locate or double-click it,
# and no way for a hot corner/hotkey trigger to do anything useful if the
# process was never running in the first place). ~/Applications is the
# same convention this project's own drag-and-drop-free, no-installer
# design already implies.
set -eu

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$HOME/.cache/launchpad-native/build"
APP="$SCRATCH/LaunchpadNative.app"
INSTALLED_APP="$HOME/Applications/LaunchpadNative.app"

swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c "$CONFIG"

BIN="$SCRATCH/$CONFIG/AppHost"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/AppHost"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# SwiftPM's default Bundle.module resolution checks Bundle.main.bundleURL
# (the .app's root) before falling back to an absolute build-dir path —
# neither matches Contents/Resources/, which is where a real .app actually
# needs this bundle. Localization/LocalizationBundle.swift checks
# Bundle.main.resourceURL first specifically so this copy is sufficient.
if [ -d "$SCRATCH/$CONFIG/LaunchpadNative_Localization.bundle" ]; then
    cp -R "$SCRATCH/$CONFIG/LaunchpadNative_Localization.bundle" "$APP/Contents/Resources/"
fi

echo "Built $APP"

pkill -f "Applications/LaunchpadNative.app/Contents/MacOS/AppHost" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED_APP"
cp -R "$APP" "$INSTALLED_APP"
# Finder/the Dock/LaunchServices cache icons aggressively by (bundle path,
# mtime); touching the bundle after install nudges LaunchServices to notice
# the icon changed rather than keep showing a stale generic-app glyph.
touch "$INSTALLED_APP"
echo "Installed $INSTALLED_APP — open it from Finder/Spotlight, or run: open \"$INSTALLED_APP\""
