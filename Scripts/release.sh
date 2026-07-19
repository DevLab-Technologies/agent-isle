#!/usr/bin/env bash
# Produce a shareable Claude Island build:
#   - universal binary (Apple Silicon + Intel)
#   - wrapped in a .app bundle
#   - ad-hoc code-signed (so it launches; not notarized — see README)
#   - zipped into dist/ for sending to friends
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "▸ Building universal release binary…"
swift build -c release --arch arm64 --arch x86_64

BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ClaudeIsland"
APP="$ROOT/dist/Claude Island.app"
CONTENTS="$APP/Contents"

rm -rf "$ROOT/dist"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/ClaudeIsland"
cp "$ROOT/Sources/ClaudeIsland/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Island</string>
  <key>CFBundleDisplayName</key><string>Claude Island</string>
  <key>CFBundleIdentifier</key><string>app.claudeisland.notch</string>
  <key>CFBundleExecutable</key><string>ClaudeIsland</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Notarized signing is used when signing credentials are present in the environment;
# otherwise we fall back to an ad-hoc signature (works for friends, shows a warning).
#
#   export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export APPLE_ID="you@example.com"
#   export TEAM_ID="TEAMID"
#   export APPLE_PASSWORD="app-specific-password"   # appleid.apple.com -> App-Specific Passwords
#
NOTARIZED=0
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "▸ Code-signing with Developer ID (hardened runtime)…"
  codesign --force --deep --options runtime --timestamp \
           --sign "$SIGN_IDENTITY" "$APP"
else
  echo "▸ Ad-hoc code-signing (set SIGN_IDENTITY to notarize)…"
  codesign --force --deep --sign - "$APP"
fi

echo "▸ Zipping…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/Claude-Island.zip"

if [[ -n "${SIGN_IDENTITY:-}" && -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APPLE_PASSWORD:-}" ]]; then
  echo "▸ Submitting to Apple notary service (this can take a few minutes)…"
  xcrun notarytool submit "$ROOT/dist/Claude-Island.zip" \
        --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APPLE_PASSWORD" --wait
  echo "▸ Stapling ticket…"
  xcrun stapler staple "$APP"
  # Re-zip so the stapled ticket ships inside the archive.
  rm -f "$ROOT/dist/Claude-Island.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/Claude-Island.zip"
  NOTARIZED=1
fi

echo
echo "✓ Universal binary: $(lipo -archs "$CONTENTS/MacOS/ClaudeIsland")"
echo "✓ Shareable zip:    $ROOT/dist/Claude-Island.zip"
if [[ "$NOTARIZED" == "1" ]]; then
  echo "✓ Notarized & stapled — friends can just double-click to open."
else
  echo
  echo "Not notarized. Tell your friend to run this once after unzipping"
  echo "(or right-click the app → Open the first time):"
  echo "    xattr -dr com.apple.quarantine '/Applications/Claude Island.app'"
fi
