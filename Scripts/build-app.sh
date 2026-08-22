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

# ── Icon ──────────────────────────────────────────────────────────────────
# assets/logo.png is the single source of truth; the .icns and the in-app
# copy are both derived here so there is never a stale duplicate to sync.
LOGO="$ROOT/assets/logo.png"
if [ -f "$LOGO" ]; then
    echo "▶ generating Glance.icns from assets/logo.png"
    ICONSET="$(mktemp -d)/Glance.iconset"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz          "$LOGO" --out "$ICONSET/icon_${sz}x${sz}.png"    >/dev/null
        sips -z $((sz*2)) $((sz*2)) "$LOGO" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Glance.icns"
    rm -rf "$(dirname "$ICONSET")"
    # Full-res copy for in-app brand marks (onboarding hero, About).
    cp "$LOGO" "$APP/Contents/Resources/GlanceLogo.png"
else
    echo "⚠ assets/logo.png missing — building without an app icon"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Glance</string>
    <key>CFBundleDisplayName</key>       <string>Glance</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>        <string>Glance</string>
    <key>CFBundleIconFile</key>          <string>Glance</string>
    <key>CFBundleIconName</key>          <string>Glance</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- FR5/FR3: menu-bar accessory, no Dock icon, no App Switcher entry. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>Personal tool.</string>
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
