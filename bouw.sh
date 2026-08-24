#!/bin/bash
# Builds Presort.app. Without a full Xcode: swift build plus the bundle by hand.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Presort"
ID="nl.justinmeijer.presort"
VERSION="0.1.0"
APP="build/$NAME.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$NAME" "$APP/Contents/MacOS/$NAME"
cp "Resources/$NAME.icns" "$APP/Contents/Resources/$NAME.icns"
# The string catalogue SwiftPM generates. Without this the app falls back to raw keys.
cp -R ".build/release/${NAME}_${NAME}.bundle" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>

  <!-- Without these three sentences the app crashes the moment it asks for access. -->
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Presort puts the appointments it finds into a calendar of its own. Your existing calendars are read but never changed.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Presort puts the tasks it finds into a reminder list of its own. Your existing lists are left alone.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Presort reads your mail from Mail to pull appointments and tasks out of it. Nothing is sent or deleted.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing: enough to run it here and to make permissions stick.
# For distribution this is replaced by a Developer ID plus notarisation.
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/  /' || true
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
echo "  done: $APP"
