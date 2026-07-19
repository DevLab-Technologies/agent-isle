#!/usr/bin/env bash
#
# Wire Claude Code up to Claude Island by adding hooks to ~/.claude/settings.json.
# Every Claude Code session in any project will then appear in the notch, and you
# can approve tool calls straight from the island.
#
# Safe to re-run: it rewrites only the "hooks" keys it manages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/vibe-hook.py"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

chmod +x "$HOOK"

if [[ ! -f "$SETTINGS" ]]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi

python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, sys

settings_path, hook = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    settings = json.load(f)

def entry(kind):
    return {"hooks": [{"type": "command", "command": f"python3 '{hook}' {kind}"}]}

hooks = settings.setdefault("hooks", {})
hooks["PreToolUse"]        = [dict(entry("pretooluse"),  matcher="*")]
hooks["PostToolUse"]       = [dict(entry("posttooluse"), matcher="*")]
hooks["Notification"]      = [entry("notification")]
hooks["Stop"]              = [entry("stop")]
hooks["UserPromptSubmit"]  = [entry("userprompt")]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)

print(f"Installed Claude Island hooks into {settings_path}")
PY

echo "Done. Start Claude Island, then run 'claude' in any project."
echo "To remove: edit the \"hooks\" section of $SETTINGS"
