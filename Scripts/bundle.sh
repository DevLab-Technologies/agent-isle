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

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/AgentIsle"
cp "$ROOT/Sources/AgentIsle/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/Scripts/agent-isle-hook.py" "$CONTENTS/Resources/agent-isle-hook.py"
cp "$ROOT/Scripts/agent-isle-cursor-hook.py" "$CONTENTS/Resources/agent-isle-cursor-hook.py"

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
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Built: $APP"
