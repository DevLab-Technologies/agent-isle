#!/usr/bin/env bash
#
# Wire Claude Code up to Agent Isle by adding hooks to ~/.claude/settings.json.
# Every Claude Code session in any project will then appear in the notch, and you
# can approve tool calls straight from the island.
#
# Safe to re-run: it rewrites only the "hooks" keys it manages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/agent-isle-hook.py"
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

def entry(kind, timeout=None):
    cmd = {"type": "command", "command": f"python3 '{hook}' {kind}"}
    if timeout:
        cmd["timeout"] = timeout
    return {"hooks": [cmd]}

hooks = settings.setdefault("hooks", {})
# PreToolUse blocks while you decide from the notch, so give it a long timeout.
hooks["PreToolUse"]        = [dict(entry("pretooluse", timeout=300), matcher="*")]
hooks["PostToolUse"]       = [dict(entry("posttooluse"), matcher="*")]
hooks["Notification"]      = [entry("notification")]
hooks["Stop"]              = [entry("stop")]
hooks["UserPromptSubmit"]  = [entry("userprompt")]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)

print(f"Installed Agent Isle hooks into {settings_path}")
PY

echo "Done. Start Agent Isle, then run 'claude' in any project."
echo "To remove: edit the \"hooks\" section of $SETTINGS"
