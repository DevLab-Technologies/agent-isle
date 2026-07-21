#!/usr/bin/env bash
# Build a release binary and wrap it in a proper .app bundle so it runs as a
# menu-bar / notch accessory app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/AgentIsle"
APP="$ROOT/build/Agent Isle.app"
CONTENTS="$APP/Contents"

# Marketing version stamped into the bundle. The updater compares this against the
# latest GitHub release; a locally built copy that looks OLDER would auto-update and
# replace itself with the release, wiping out the local build. So derive the version
# from git — the latest tag plus the number of commits since it — so a dev build reads
# e.g. "1.2.8" (> the "1.2" release) and is never clobbered, while a build cut exactly
# at a tag reads the clean tag ("1.2"). Override with AGENT_ISLE_VERSION in release CI.
if [ -n "${AGENT_ISLE_VERSION:-}" ]; then
  VERSION="$AGENT_ISLE_VERSION"
else
  RAWTAG="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
  if [ -n "$RAWTAG" ]; then
    TAG="${RAWTAG#v}"
    AHEAD="$(git -C "$ROOT" rev-list "${RAWTAG}..HEAD" --count 2>/dev/null || echo 0)"
    if [ "${AHEAD:-0}" -gt 0 ] 2>/dev/null; then VERSION="${TAG}.${AHEAD}"; else VERSION="$TAG"; fi
  else
    VERSION="0.0"   # no tags reachable (e.g. shallow CI clone) — set AGENT_ISLE_VERSION
  fi
fi
echo "Version: $VERSION ($CONFIG)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/AgentIsle"
cp "$ROOT/Sources/AgentIsle/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/Scripts/agent-isle-hook.py" "$CONTENTS/Resources/agent-isle-hook.py"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Agent Isle</string>
  <key>CFBundleDisplayName</key><string>Agent Isle</string>
  <key>CFBundleIdentifier</key><string>com.devlab.agentisle</string>
  <key>CFBundleExecutable</key><string>AgentIsle</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Built: $APP ($VERSION)"
