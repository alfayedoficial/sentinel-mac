#!/bin/bash
# Builds Sentinel.app (+ privileged helper), ad-hoc signs it and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Sentinel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp .build/release/Sentinel "$APP/Contents/MacOS/Sentinel"
cp .build/release/SentinelHelper "$APP/Contents/MacOS/SentinelHelper"
cp Info.plist "$APP/Contents/Info.plist"
cp LaunchDaemons/com.afapps.sentinel.helper.plist "$APP/Contents/Library/LaunchDaemons/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# sign the helper first with its own identifier, then the app bundle
codesign --force --sign - --identifier com.afapps.sentinel.helper "$APP/Contents/MacOS/SentinelHelper"
codesign --force --sign - --identifier com.afapps.sentinel "$APP"
mkdir -p ~/Applications
pkill -x Sentinel 2>/dev/null || true
rm -rf ~/Applications/Sentinel.app
cp -R "$APP" ~/Applications/Sentinel.app
echo "Installed ~/Applications/Sentinel.app"
