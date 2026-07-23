#!/bin/sh
# Builds a throwaway fixture app + its associated files so Phase 8's
# ownership evidence collector and removal planner can be exercised against
# real files on disk without ever touching a real installed app.
#
# The dummy .app bundle itself lives outside ~/Library, under
# ~/.cache/launchpad-native/fixtures/ (same out-of-iCloud cache root the rest
# of this project uses). Its *evidence* files (Application Support, Caches,
# LaunchAgents) are written into the real ~/Library, because
# OwnershipEvidenceCollector looks there — this is safe because the bundle
# identifier below (com.launchpadnative.uninstallfixture) is exclusive to
# this fixture and never used by any real app, so nothing pre-existing is
# ever touched, and this script's own removal (`rm -rf`) below cleans up
# anything from a previous run before creating fresh fixture data.
#
# Layout produced:
#   ~/.cache/launchpad-native/fixtures/UninstallFixture.app        — dummy bundle
#   ~/Library/Application Support/com.launchpadnative.uninstallfixture/
#     dummy.txt                                                    — "owned" evidence
#     com.launchpadnative.uninstallfixture.helpertool/               — nested sibling
#       dummy.txt                                                     data ⇒ "sharedRisk"
#   ~/Library/Caches/com.launchpadnative.uninstallfixture/dummy.txt
#   ~/Library/Containers/com.launchpadnative.uninstallfixture/dummy.txt
#   ~/Library/Saved Application State/com.launchpadnative.uninstallfixture.savedState/dummy.txt
#   ~/Library/Group Containers/group.com.launchpadnative.uninstallfixture/dummy.txt
#     — a Group Container is shared *by design*; RemovalPlanner must always
#       classify it sharedRisk regardless of the sibling-team-ID check.
#   ~/Library/LaunchAgents/com.launchpadnative.uninstallfixture.helper.plist
#     — a plain plist file only; never `launchctl load`ed, so nothing is
#       actually registered with launchd.
set -eu

BUNDLE_ID="com.launchpadnative.uninstallfixture"
SIBLING_BUNDLE_ID="com.launchpadnative.uninstallfixture.helpertool"
APP_ROOT="$HOME/.cache/launchpad-native/fixtures"
APP_SUPPORT="$HOME/Library/Application Support/$BUNDLE_ID"
CACHES="$HOME/Library/Caches/$BUNDLE_ID"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID"
SAVED_STATE="$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
GROUP_CONTAINER="$HOME/Library/Group Containers/group.$BUNDLE_ID"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.helper.plist"

rm -rf "$APP_ROOT" "$APP_SUPPORT" "$CACHES" "$CONTAINER" "$SAVED_STATE" "$GROUP_CONTAINER" "$LAUNCH_AGENT"
mkdir -p "$APP_ROOT/UninstallFixture.app/Contents/MacOS"

cat > "$APP_ROOT/UninstallFixture.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>UninstallFixture</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
</dict>
</plist>
PLIST
cp /usr/bin/true "$APP_ROOT/UninstallFixture.app/Contents/MacOS/UninstallFixture"

mkdir -p "$APP_SUPPORT/$SIBLING_BUNDLE_ID"
echo "owned fixture data" > "$APP_SUPPORT/dummy.txt"
echo "sibling fixture data" > "$APP_SUPPORT/$SIBLING_BUNDLE_ID/dummy.txt"

mkdir -p "$CACHES"
echo "cache fixture data" > "$CACHES/dummy.txt"

mkdir -p "$CONTAINER"
echo "container fixture data" > "$CONTAINER/dummy.txt"

mkdir -p "$SAVED_STATE"
echo "saved state fixture data" > "$SAVED_STATE/dummy.txt"

mkdir -p "$GROUP_CONTAINER"
echo "group container fixture data" > "$GROUP_CONTAINER/dummy.txt"

cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID.helper</string>
</dict>
</plist>
PLIST

echo "Built fixture app at $APP_ROOT/UninstallFixture.app"
echo "Fixture evidence under ~/Library/{Application Support,Caches,Containers,Saved Application State,Group Containers,LaunchAgents}/$BUNDLE_ID*"
