#!/usr/bin/env bash
# Produce a shareable Agent Isle build:
#   - universal binary (Apple Silicon + Intel)
#   - wrapped in a .app bundle
#   - ad-hoc code-signed (so it launches; not notarized — see README)
#   - zipped into dist/ for sending to friends
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Marketing version baked into the bundle; the in-app updater compares this against
# the latest GitHub release tag. Bump it for every release: ./release.sh 1.2
VERSION="${1:-1.1}"
echo "▸ Version: $VERSION"

echo "▸ Building universal release binary…"
swift build -c release --arch arm64 --arch x86_64

BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AgentIsle"
APP="$ROOT/dist/Agent Isle.app"
CONTENTS="$APP/Contents"

rm -rf "$ROOT/dist"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/AgentIsle"
cp "$ROOT/Sources/AgentIsle/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/Scripts/agent-isle-hook.py" "$CONTENTS/Resources/agent-isle-hook.py"

# Quoted heredoc: nothing here is shell-expanded. The version is injected afterward
# with PlistBuddy so a stray `$` in the template can never break the build.
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Agent Isle</string>
  <key>CFBundleDisplayName</key><string>Agent Isle</string>
  <key>CFBundleIdentifier</key><string>com.devlab.agentisle</string>
  <key>CFBundleExecutable</key><string>AgentIsle</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>0</string>
  <key>CFBundleShortVersionString</key><string>0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion $VERSION" \
  -c "Set :CFBundleShortVersionString $VERSION" \
  "$CONTENTS/Info.plist"

# --- Code signing ------------------------------------------------------------
# Signs with a Developer ID Application certificate (hardened runtime, so the build
# is notarizable). If SIGN_IDENTITY isn't set we auto-detect the first Developer ID
# cert in the keychain; with no cert at all we fall back to an ad-hoc signature
# (unsigned — Gatekeeper will warn).
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
                   | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "▸ Code-signing with: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
           --sign "$SIGN_IDENTITY" "$APP"
else
  echo "▸ Ad-hoc code-signing (no Developer ID cert found)…"
  codesign --force --deep --sign - "$APP"
fi

echo "▸ Zipping…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/Agent-Isle.zip"

# --- Notarization ------------------------------------------------------------
# Prefers a stored notarytool keychain profile (no secrets in env). Set it up once:
#   xcrun notarytool store-credentials "AgentIsle" \
#     --apple-id you@example.com --team-id ZS3A435WC2 --password <app-specific-pw>
# Override the profile name with NOTARY_PROFILE, or fall back to APPLE_ID /
# TEAM_ID / APPLE_PASSWORD env vars if you prefer.
NOTARY_PROFILE="${NOTARY_PROFILE:-AgentIsle}"
NOTARIZED=0
NOTARY_ARGS=()
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APPLE_PASSWORD:-}" ]]; then
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APPLE_PASSWORD")
fi

if [[ -n "${SIGN_IDENTITY:-}" && ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  echo "▸ Submitting to Apple notary service (this can take a few minutes)…"
  xcrun notarytool submit "$ROOT/dist/Agent-Isle.zip" "${NOTARY_ARGS[@]}" --wait
  echo "▸ Stapling ticket…"
  xcrun stapler staple "$APP"
  # Re-zip so the stapled ticket ships inside the archive.
  rm -f "$ROOT/dist/Agent-Isle.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/Agent-Isle.zip"
  NOTARIZED=1
fi

echo
echo "✓ Universal binary: $(lipo -archs "$CONTENTS/MacOS/AgentIsle")"
echo "✓ Shareable zip:    $ROOT/dist/Agent-Isle.zip"
if [[ "$NOTARIZED" == "1" ]]; then
  echo "✓ Notarized & stapled — friends can just double-click to open."
else
  echo
  echo "Not notarized. Tell your friend to run this once after unzipping"
  echo "(or right-click the app → Open the first time):"
  echo "    xattr -dr com.apple.quarantine '/Applications/Agent Isle.app'"
fi
