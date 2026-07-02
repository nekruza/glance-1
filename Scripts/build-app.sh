#!/usr/bin/env bash
# Assemble Glance.app from the SwiftPM build product.
#
# Local run:      Scripts/build-app.sh && open build/Glance.app
# Release (NFR7): re-sign with a Developer ID identity and notarize — see
#                 the "Distribution" note at the bottom of this file.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Glance.app"
BUNDLE_ID="com.h57q3wq0c.glance"
VERSION="1.0"

cd "$ROOT"
echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Glance"

echo "▶ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glance"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Glance</string>
    <key>CFBundleDisplayName</key>       <string>Glance</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>        <string>Glance</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- FR5/FR3: menu-bar accessory, no Dock icon, no App Switcher entry. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>Personal tool.</string>
    <!-- Meeting transcription -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Glance records your microphone to transcribe your side of meetings.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Glance transcribes meeting audio on-device to create notes.</string>
</dict>
</plist>
PLIST

# TCC (Screen Recording) ties the grant to the code-signing identity. Ad-hoc
# (`--sign -`) changes identity every rebuild and orphans the grant, so prefer a
# STABLE self-signed identity (create it once with Scripts/dev-sign-setup.sh).
SIGN_KC="$HOME/Library/Keychains/glance-signing.keychain-db"
SIGN_ID="Glance Dev"
if security find-identity -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "▶ codesign with stable identity '$SIGN_ID'"
    codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KC" "$APP"
else
    echo "▶ ad-hoc codesign (run Scripts/dev-sign-setup.sh for a persistent Screen Recording grant)"
    codesign --force --deep --sign - "$APP"
fi

echo "✔ built $APP"
echo "  run: open \"$APP\""

# ── Distribution (NFR7), not automated here ───────────────────────────────
# 1. codesign --force --options runtime --sign "Developer ID Application: …" \
#      --timestamp "$APP"
# 2. ditto -c -k --keepParent "$APP" build/Glance.zip
# 3. xcrun notarytool submit build/Glance.zip --keychain-profile "…" --wait
# 4. xcrun stapler staple "$APP"
