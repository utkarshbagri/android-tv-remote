#!/bin/bash
# Builds the menu-bar widget and installs it as ~/Applications/TV Remote.app (ad-hoc signed).
# Needs only the Command Line Tools — no Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TVRemoteBar
BIN="$(swift build -c release --show-bin-path)/TVRemoteBar"

APP="$HOME/Applications/TV Remote.app"
pkill -x TVRemoteBar 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TVRemoteBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>co.ubrain.tvremotebar</string>
    <key>CFBundleName</key><string>TV Remote</string>
    <key>CFBundleDisplayName</key><string>TV Remote</string>
    <key>CFBundleExecutable</key><string>TVRemoteBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Controls your Android TV on the local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_androidtvremote2._tcp</string><string>_googlecast._tcp</string></array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Installed $APP"
open "$APP"
