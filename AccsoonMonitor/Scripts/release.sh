#!/bin/bash
# Builds a universal (Apple silicon + Intel) app and zips it for a GitHub release.
# Output: dist/Accsoon-Monitor-<version>.zip
#
# The app is ad-hoc signed, not notarised (that needs a paid Apple Developer
# account), so macOS asks people to confirm the first launch.
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build.sh
ARCH=arm64 Scripts/build.sh 2>/dev/null || true   # no-op on Apple silicon; cross-build on Intel
ARCH=x86_64 Scripts/build.sh

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Scripts/Info.plist)
app="dist/Accsoon Monitor.app"
rm -rf dist
mkdir -p dist
cp -R build/AccsoonMonitor.app "$app"

host=$(uname -m)
other=$([ "$host" = arm64 ] && echo x86_64 || echo arm64)
lipo -create .build/manual/AccsoonMonitor ".build/manual-$other/AccsoonMonitor" -output "$app/Contents/MacOS/AccsoonMonitor"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

zip="dist/Accsoon-Monitor-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
echo "built $zip ($(lipo -archs "$app/Contents/MacOS/AccsoonMonitor"))"
