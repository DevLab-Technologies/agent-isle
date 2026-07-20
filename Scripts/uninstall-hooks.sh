#!/usr/bin/env bash
#
# Remove the Agent Isle hooks from ~/.claude/settings.json.
# Monitoring keeps working without hooks (the app reads transcripts directly);
# hooks are only needed for blocking permission approvals from the notch.
set -euo pipefail

SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
[[ -f "$SETTINGS" ]] || { echo "No settings file at $SETTINGS"; exit 0; }

python3 - "$SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
removed = 0
for event in list(hooks.keys()):
    kept = []
    for group in hooks[event]:
        cmds = group.get("hooks", [])
        cmds = [c for c in cmds if "agent-isle-hook" not in c.get("command", "")]
        if cmds:
            group["hooks"] = cmds
            kept.append(group)
        else:
            removed += 1
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]

if not hooks:
    settings.pop("hooks", None)
else:
    settings["hooks"] = hooks

with open(path, "w") as f:
    json.dump(settings, f, indent=2)

print(f"Removed {removed} Agent Isle hook group(s) from {path}")
PY

echo "Done. The island keeps monitoring sessions without hooks."
