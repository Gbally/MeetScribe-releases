#!/bin/sh
# Builds Hesper.app and a drag-to-install DMG in dist/.
#
#   ./scripts/build_app.sh                      ad-hoc signed (colleagues must allow it once)
#   SIGN_ID="Developer ID Application: …" ./scripts/build_app.sh
#                                               signed with your Apple Developer ID; then
#                                               notarize dist/*.dmg for a warning-free install
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP=build/Hesper.app
UV_BIN=$(command -v uv || echo "$HOME/development/bin/uv")

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine" dist

echo "• Compiling"
swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  mac/Shared/*.swift mac/App/*.swift -o "$APP/Contents/MacOS/Hesper"

echo "• Bundling engine"
cp "$UV_BIN" "$APP/Contents/MacOS/uv"
cp -R src pyproject.toml uv.lock .python-version "$APP/Contents/Resources/engine/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
find "$APP/Contents/Resources/engine" -name __pycache__ -prune -exec rm -rf {} +

echo "• Icon"
if [ ! -f build-cache/AppIcon.icns ]; then
  mkdir -p build-cache
  swift scripts/make_icon.swift build-cache/AppIcon.iconset
  iconutil -c icns build-cache/AppIcon.iconset -o build-cache/AppIcon.icns
fi
cp build-cache/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp catalog/models.json "$APP/Contents/Resources/models.json"

echo "• Translations"
python3 scripts/i18n.py build "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hesper</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string><string>es</string><string>pt</string><string>ja</string><string>zh-Hans</string></array>
  <key>CFBundleDisplayName</key><string>Hesper</string>
  <key>CFBundleIdentifier</key><string>studio.nibjorg.Hesper</string>
  <key>CFBundleExecutable</key><string>Hesper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>HesperReleasesRepo</key><string>Gbally/Hesper</string>
  <key>MSDeveloperTeam</key><string>${DEVELOPER_TEAM:-}</string>
  <key>NSMicrophoneUsageDescription</key><string>Hesper records your voice during meetings to create a transcript. Audio stays on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Hesper records the meeting audio (the other participants) to create a transcript. Audio stays on this Mac.</string>
  <key>NSCalendarsUsageDescription</key><string>Hesper reads the current meeting's title and attendees to name the notes and email them. Nothing leaves this Mac.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Hesper reads the current meeting's title and attendees to name the notes and email them. Nothing leaves this Mac.</string>
  <key>NSRemindersUsageDescription</key><string>Hesper can add your meeting to-dos to Reminders.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Hesper can add your meeting to-dos to Reminders.</string>
  <key>NSAppleEventsUsageDescription</key><string>Hesper adds your meeting notes to Apple Notes when you ask it to.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Hesper only records the meeting audio, never your screen. Audio stays on this Mac.</string>
</dict>
</plist>
PLIST

echo "• Signing"
KC="$ROOT/signing/MeetScribe-signing.keychain-db"
if [ -n "$SIGN_ID" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/uv"
  codesign --force --options runtime --timestamp --entitlements mac/Hesper.entitlements --sign "$SIGN_ID" "$APP"
elif [ -f "$KC" ]; then
  # Stable local identity (scripts/make_signing_identity.sh): permissions survive updates.
  security unlock-keychain -p "$(cat "$ROOT/signing/keychain-password")" "$KC"
  HASH=$(security find-identity "$KC" | sed -n 's/.*) \([0-9A-F]\{40\}\) "MeetScribe Local Signing".*/\1/p' | head -1)
  codesign --force --keychain "$KC" --sign "$HASH" "$APP/Contents/MacOS/uv"
  codesign --force --keychain "$KC" --sign "$HASH" "$APP"
else
  echo "  ⚠️  ad-hoc signature: macOS will re-ask for permissions after every update."
  echo "     Run scripts/make_signing_identity.sh once to fix that."
  codesign --force --sign - "$APP/Contents/MacOS/uv"
  codesign --force --sign - "$APP"
fi
codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => /  identity: /p'

echo "• DMG"
STAGE=build/dmg && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
cp mac/INSTALL.txt "$STAGE/How to install.txt"
mkdir -p "$STAGE/Licenses" && cp LICENSE THIRD_PARTY_NOTICES.md PRIVACY.md "$STAGE/Licenses/"
DMG="dist/Hesper-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname Hesper -srcfolder "$STAGE" -ov -format UDZO "$DMG"
[ -n "$SIGN_ID" ] && codesign --sign "$SIGN_ID" "$DMG"
# Don't let macOS launch the build copies instead of the installed app.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -u "$APP" 2>/dev/null || true
"$LSR" -u "$STAGE/Hesper.app" 2>/dev/null || true
echo "✅ $ROOT/$DMG ($(du -h "$DMG" | cut -f1))"
