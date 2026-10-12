#!/bin/bash
# Build CapitalBar and install it as a real .app in ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/CapitalBar.app"

echo "→ building"
swift build -c release

echo "→ bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CapitalBar "$APP/Contents/MacOS/CapitalBar"

echo "→ rendering icon"
ICONSET="$(mktemp -d)/CapitalBar.iconset"
.build/release/CapitalBar --export-icons "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CapitalBar</string>
  <key>CFBundleDisplayName</key><string>CapitalBar</string>
  <key>CFBundleIdentifier</key><string>com.jamahl.capitalbar</string>
  <key>CFBundleExecutable</key><string>CapitalBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true

echo "→ restarting"
pkill -x CapitalBar 2>/dev/null || true
sleep 1
open "$APP"
echo "done — look at the right side of your menu bar"
