#!/usr/bin/env bash
# Assemble the fixture executable into a real .app bundle.
#
# SwiftPM cannot emit an .app, and `open -n` — which is how the capture driver
# launches things, precisely because it activates the app — will not accept a bare
# executable. So the bundle is built by hand.
#
# The bundle name must match the executable name: the driver derives the process
# name to pgrep from the .app's basename, so AppShotFixture.app/Contents/MacOS/
# AppShotFixture is load-bearing, not tidiness.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/fixture/AppShotFixture.app"

swift build -c "$CONFIG" --product AppShotFixture >&2
BIN="$(swift build -c "$CONFIG" --product AppShotFixture --show-bin-path)/AppShotFixture"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AppShotFixture"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AppShotFixture</string>
    <key>CFBundleIdentifier</key><string>dev.appshot.fixture</string>
    <key>CFBundleName</key><string>AppShotFixture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "$APP"
