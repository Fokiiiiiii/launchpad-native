#!/bin/sh
# Phase 8 part 4: builds a real, ad-hoc-signed copy of LaunchpadNative.app
# with a trivial, inert LaunchDaemon embedded, so
# PrivilegedHelperRegistrationProbe can prove (or disprove) whether
# SMAppService daemon registration works at all for a build with no paid
# Developer ID — this project is unsigned/unnotarized by explicit
# requirement, so this has to be checked on real hardware, not assumed.
#
# The embedded daemon (PrivilegedHelperProbe) does nothing but write one log
# line to /tmp and exit; it never touches app data. This script always
# produces a *release* build's bundle, since a LaunchDaemon under
# Contents/Library/LaunchDaemons is only meaningful in an assembled .app.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$HOME/.cache/launchpad-native/build"
APP="$SCRATCH/LaunchpadNative.app"
LABEL="com.launchpadnative.privilegedhelperprobe"

swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c release

# Reuses the same release .app bundle build-app.sh produces, then adds the
# daemon executable + its launchd plist on top — this is still the one
# real app bundle, not a separate throwaway copy, since SMAppService
# registration must be exercised against the actual shipping bundle shape.
"$ROOT/Scripts/build-app.sh" release

cp "$SCRATCH/release/PrivilegedHelperProbe" "$APP/Contents/MacOS/PrivilegedHelperProbe"
cp "$SCRATCH/release/PrivilegedHelperRegistrationProbe" "$APP/Contents/MacOS/PrivilegedHelperRegistrationProbe"

mkdir -p "$APP/Contents/Library/LaunchDaemons"
cat > "$APP/Contents/Library/LaunchDaemons/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/PrivilegedHelperProbe</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signing (no paid identity available) — the whole point of this
# probe is to find out whether SMAppService accepts this.
codesign --sign - --force --deep "$APP"

echo "Built ad-hoc-signed fixture at $APP"
echo "Run: $APP/Contents/MacOS/PrivilegedHelperRegistrationProbe"
