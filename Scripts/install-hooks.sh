#!/usr/bin/env bash
#
# Wire Claude Code up to Agent Isle by adding hooks to ~/.claude/settings.json.
# Every Claude Code session in any project will then appear in the notch, and you
# can approve tool calls straight from the island.
#
# Safe to re-run: it replaces only its own hook entries and preserves every
# other hook you have configured.
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

MARKER = "agent-isle-hook"

def is_ours(group):
    if not isinstance(group, dict):
        return False
    return any(MARKER in c.get("command", "")
               for c in group.get("hooks", []) if isinstance(c, dict))

hooks = settings.setdefault("hooks", {})
# PreToolUse blocks while you decide from the notch, so give it a long timeout.
managed = {
    "PreToolUse":       dict(entry("pretooluse", timeout=300), matcher="*"),
    "PostToolUse":      dict(entry("posttooluse"), matcher="*"),
    "Notification":     entry("notification"),
    "Stop":             entry("stop"),
    "UserPromptSubmit": entry("userprompt"),
}
for event, group in managed.items():
    # Drop only prior copies of our own hook so re-runs stay idempotent, and
    # preserve every foreign hook group — mirrors the in-app installer
    # (CLIIntegration.swift `applyingHook`), which must stay consistent with this.
    existing = hooks.get(event, [])
    kept = [g for g in existing if not is_ours(g)] if isinstance(existing, list) else []
    kept.append(group)
    hooks[event] = kept

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)

print(f"Installed Agent Isle hooks into {settings_path}")
PY

echo "Done. Start Agent Isle, then run 'claude' in any project."
echo "To remove: edit the \"hooks\" section of $SETTINGS"
