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
cp "$ROOT/Scripts/agent-isle-cursor-hook.py" "$CONTENTS/Resources/agent-isle-cursor-hook.py"

# Quoted heredoc (no shell interpolation) — the version is stamped in afterward via
# PlistBuddy so nothing in the plist can be accidentally expanded by the shell.
#
# NOTE: this local bundle uses a DISTINCT bundle id (`.dev`) from the shipped release
# (`com.devlab.agentisle`, set by release.sh). macOS keys TCC permission grants — especially
# Accessibility, which the keystroke delivery path needs — on bundle id + code identity. This
# build is ad-hoc signed, so its identity changes every rebuild; if it shared the release's
# bundle id it would overwrite the release's Accessibility grant, leaving the installed
# release "not trusted" and re-prompting even though it was granted. A separate id keeps the
# two grants independent so a dev build never breaks the installed app (and vice versa).
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Agent Isle (dev)</string>
  <key>CFBundleDisplayName</key><string>Agent Isle (dev)</string>
  <key>CFBundleIdentifier</key><string>com.devlab.agentisle.dev</string>
  <key>CFBundleExecutable</key><string>AgentIsle</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>0.0</string>
  <key>CFBundleShortVersionString</key><string>0.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Agent Isle delivers your typed messages and answers into Terminal and iTerm sessions.</string>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set CFBundleVersion $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"

# Sign with the stable dev identity if it exists (see Scripts/dev-cert.sh). This gives the
# dev build a persistent code identity so macOS TCC grants — Accessibility, Automation —
# survive rebuilds instead of resetting each time. Without it the app link-time ad-hoc
# signature changes every build and permissions must be re-granted. Never used for release
# (release.sh signs with the Developer ID cert); purely local dev ergonomics.
DEV_IDENTITY="Agent Isle Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_IDENTITY"; then
  codesign --force --sign "$DEV_IDENTITY" "$APP" >/dev/null 2>&1 \
    && echo "Signed with stable dev identity '$DEV_IDENTITY' (permissions persist across rebuilds)." \
    || echo "warning: signing with '$DEV_IDENTITY' failed; build is ad-hoc (permissions will reset)."
else
  echo "Tip: run 'bash Scripts/dev-cert.sh' once so Accessibility/Automation grants persist across dev rebuilds."
fi

echo "Built: $APP ($VERSION)"
