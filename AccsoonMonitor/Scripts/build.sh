#!/bin/bash
# Builds AccsoonMonitor.app and the cineeye-replay tool with swiftc alone, so it
# works with only the Command Line Tools installed (no Xcode, no SwiftPM).
# Also runs the protocol checks. With a working SwiftPM, Package.swift builds the same targets.
set -euo pipefail
cd "$(dirname "$0")/.."

# Use an SDK that matches the installed compiler if the default one does not.
if [ -z "${SDKROOT:-}" ]; then
  major=$(sw_vers -productVersion | cut -d. -f1)
  for sdk in "/Library/Developer/CommandLineTools/SDKs/MacOSX${major}.sdk" "$(xcrun --show-sdk-path 2>/dev/null)"; do
    if [ -d "$sdk" ]; then export SDKROOT="$sdk"; break; fi
  done
fi

# ARCH=x86_64 (or arm64) cross-compiles just the app binary for that architecture;
# Scripts/release.sh uses this to make a universal app.
host=$(uname -m)
arch="${ARCH:-$host}"
out=.build/manual
if [ "$arch" != "$host" ]; then out=".build/manual-$arch"; fi
mkdir -p "$out"
flags=(-O -target "$arch-apple-macos14.0" -I "$out" -L "$out")

lib() {
  local name=$1
  swiftc "${flags[@]}" -parse-as-library -emit-module -emit-library -static -module-name "$name" \
    -emit-module-path "$out/$name.swiftmodule" -o "$out/lib$name.a" Sources/"$name"/*.swift
}

lib CineEyeProtocol
lib CineEyeVideo
if [ "$arch" = "$host" ]; then
  swiftc "${flags[@]}" -lCineEyeProtocol -lCineEyeVideo -o "$out/protocol-check" Sources/protocol-check/*.swift
  "$out/protocol-check"
  swiftc "${flags[@]}" -lCineEyeProtocol -lCineEyeVideo -o "$out/cineeye-replay" Sources/cineeye-replay/*.swift
fi
swiftc "${flags[@]}" -parse-as-library -lCineEyeProtocol -lCineEyeVideo -o "$out/AccsoonMonitor" Sources/AccsoonMonitor/*.swift

if [ "$arch" != "$host" ]; then
  echo "built $out/AccsoonMonitor ($arch)"
  exit 0
fi

app=build/AccsoonMonitor.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$out/AccsoonMonitor" "$app/Contents/MacOS/"
cp Scripts/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign - "$app" >/dev/null 2>&1
echo "built $app and $out/cineeye-replay"
