#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Sentinel.app, signs it locally and zips it for download.
# Output: build/Sentinel.zip and build/Sentinel.zip.sha256
set -e
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
APP=build/Sentinel.app
rm -rf "$APP" build/Sentinel.zip build/Sentinel.zip.sha256
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/Sentinel" "$APP/Contents/MacOS/Sentinel"
cp "$BIN/SentinelHelper" "$APP/Contents/MacOS/SentinelHelper"
cp Info.plist "$APP/Contents/Info.plist"
cp LaunchDaemons/com.afapps.sentinel.helper.plist "$APP/Contents/Library/LaunchDaemons/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.afapps.sentinel.helper "$APP/Contents/MacOS/SentinelHelper"
codesign --force --sign - --identifier com.afapps.sentinel "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" build/Sentinel.zip
(cd build && shasum -a 256 Sentinel.zip > Sentinel.zip.sha256)
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/Sentinel")"
cat build/Sentinel.zip.sha256
