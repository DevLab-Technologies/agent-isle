#!/usr/bin/env bash
#
# Remove the Agent Isle hooks from ~/.cursor/hooks.json.
# Monitoring keeps working without hooks (the app reads Cursor's store.db directly);
# hooks are only needed for blocking permission approvals from the notch.
set -euo pipefail

HOOKS_JSON="$HOME/.cursor/hooks.json"
[[ -f "$HOOKS_JSON" ]] || { echo "No Cursor hooks file at $HOOKS_JSON"; exit 0; }

python3 - "$HOOKS_JSON" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as f:
    config = json.load(f)

hooks = config.get("hooks", {})
removed = 0
for event in list(hooks.keys()):
    kept = [e for e in hooks[event]
            if "agent-isle-cursor-hook" not in e.get("command", "")]
    removed += len(hooks[event]) - len(kept)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]

if not hooks:
    config.pop("hooks", None)
else:
    config["hooks"] = hooks

with open(path, "w") as f:
    json.dump(config, f, indent=2)

print(f"Removed {removed} Agent Isle Cursor hook(s) from {path}")
PY

echo "Done. The island keeps monitoring Cursor sessions without hooks."
