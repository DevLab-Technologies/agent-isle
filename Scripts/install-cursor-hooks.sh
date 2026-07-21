#!/usr/bin/env bash
#
# Wire the Cursor CLI (cursor-agent) up to Agent Isle by adding hooks to
# ~/.cursor/hooks.json. Every Cursor session will then appear in the notch, and you can
# approve shell / MCP / file-edit calls straight from the island.
#
# Safe to re-run and safe alongside other tools: it rewrites only the hook entries it
# owns (those pointing at agent-isle-cursor-hook.py) and preserves everyone else's.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/agent-isle-cursor-hook.py"
HOOKS_JSON="$HOME/.cursor/hooks.json"

chmod +x "$HOOK"

if [[ ! -f "$HOOKS_JSON" ]]; then
  mkdir -p "$(dirname "$HOOKS_JSON")"
  echo '{"version": 1, "hooks": {}}' > "$HOOKS_JSON"
fi

python3 - "$HOOKS_JSON" "$HOOK" <<'PY'
import json, sys

path, hook = sys.argv[1], sys.argv[2]
with open(path) as f:
    config = json.load(f)

config.setdefault("version", 1)
hooks = config.setdefault("hooks", {})

# event -> blocking timeout (seconds); None means fire-and-forget.
managed = {
    "beforeShellExecution": 300,
    "beforeMCPExecution": 300,
    "beforeFileEdit": 300,
    "beforeSubmitPrompt": None,
    "afterShellExecution": None,
    "afterMCPExecution": None,
    "afterFileEdit": None,
    "afterAgentResponse": None,
    "stop": None,
}

for event, timeout in managed.items():
    # Keep foreign hooks; drop only a prior copy of ours.
    entries = [e for e in hooks.get(event, [])
               if "agent-isle-cursor-hook" not in e.get("command", "")]
    cmd = {"command": f"python3 '{hook}'"}
    if timeout:
        cmd["timeout"] = timeout
    entries.append(cmd)
    hooks[event] = entries

with open(path, "w") as f:
    json.dump(config, f, indent=2)

print(f"Installed Agent Isle Cursor hooks into {path}")
PY

echo "Done. Start Agent Isle, then run 'cursor-agent' in any project."
echo "To remove: bash Scripts/uninstall-cursor-hooks.sh"
