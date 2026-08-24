#!/bin/bash
# Bouwt Voorsorteren.app. Zonder volledige Xcode: swift build plus de bundel met de hand.
set -euo pipefail
cd "$(dirname "$0")"

NAAM="Voorsorteren"
ID="nl.justinmeijer.voorsorteren"
VERSIE="0.1.0"
APP="build/$NAAM.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$NAAM" "$APP/Contents/MacOS/$NAAM"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAAM</string>
  <key>CFBundleDisplayName</key><string>$NAAM</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>$NAAM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSIE</string>
  <key>CFBundleVersion</key><string>$VERSIE</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>

  <!-- Zonder deze drie teksten valt de app om zodra hij toestemming vraagt. -->
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Voorsorteren zet gevonden afspraken in een eigen agenda. Je bestaande agenda's worden gelezen maar nooit gewijzigd.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Voorsorteren zet gevonden acties in een eigen herinneringenlijst. Je bestaande lijsten blijven ongemoeid.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Voorsorteren leest je post uit Mail om er afspraken en acties uit te halen. Er wordt niets verstuurd of verwijderd.</string>
</dict>
</plist>
PLIST

# Ad-hoc ondertekenen: genoeg om hier te draaien en om toestemmingen te laten plakken.
# Voor verkoop komt hier een Developer ID plus notarisatie voor in de plaats.
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/  /' || true
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
echo "  klaar: $APP"
