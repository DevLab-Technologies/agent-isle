#!/usr/bin/env python3
"""
Claude Code -> Claude Island bridge.

Configured as a Claude Code hook (see install-hooks.sh). Claude Code pipes a JSON
payload on stdin for each hook event; this script translates it into a Claude Island
`/event` POST so the session shows up in the notch.

For PreToolUse it BLOCKS on the island's decision and echoes the allow/deny back to
Claude Code in the hook output format, so you can approve tools right from the notch.

Usage:  vibe-hook.py <event-kind>
        event-kind in: pretooluse | posttooluse | notification | stop | userprompt
"""
import json
import sys
import urllib.request

ISLAND_URL = "http://localhost:4711/event"
TIMEOUT = 600  # allow the user plenty of time to decide from the notch


def post(payload, timeout=5):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(ISLAND_URL, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def short_path(p):
    if not p:
        return None
    parts = p.split("/")
    return "/".join(parts[-3:]) if len(parts) > 3 else p


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else "notification"
    raw = sys.stdin.read()
    try:
        hook = json.loads(raw)
    except Exception:
        hook = {}
    if os.environ.get("VIBE_DEBUG") == "1":
        try:
            with open("/tmp/vibe-hook-debug.jsonl", "a") as _f:
                _f.write(kind + " " + raw + "\n")
        except Exception:
            pass

    session = hook.get("session_id", "claude-session")
    cwd = hook.get("cwd", "")
    title = cwd.split("/")[-1] if cwd else "claude session"

    base = {
        "session": session,
        "agent": "claude",
        "title": title,
        "terminal": "Terminal",
    }

    # Show a blocking approval card only when Claude Code is in an interactive
    # permission mode. In bypass/acceptEdits mode Claude proceeds on its own, so we
    # stay out of the way and just report activity (no prompt on every tool call).
    # `export VIBE_APPROVALS=0` disables approvals entirely.
    mode = hook.get("permission_mode") or hook.get("permissionMode") or "default"
    interactive_mode = mode not in ("bypassPermissions", "acceptEdits")
    ask = interactive_mode and os.environ.get("VIBE_APPROVALS") != "0"

    try:
        if kind == "pretooluse":
            tool = hook.get("tool_name", "Tool")
            tin = hook.get("tool_input", {}) or {}
            if ask:
                event = dict(base, type="permission", tool=tool,
                             file=short_path(tin.get("file_path")),
                             command=tin.get("command"),
                             message=f"Wants to run {tool}")
                result = post(event, timeout=TIMEOUT)
                decision = result.get("decision", "allow")
                allow = decision not in ("deny", "no")
                print(json.dumps({
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "allow" if allow else "deny",
                        "permissionDecisionReason": "Decided from Claude Island",
                    }
                }))
            else:
                # Non-blocking: just report activity, let Claude Code proceed normally.
                post(dict(base, type="status", status="working",
                          message=f"Running {tool}"))
            sys.exit(0)

        elif kind == "posttooluse":
            tool = hook.get("tool_name", "Tool")
            post(dict(base, type="status", status="working",
                      message=f"Ran {tool}"))

        elif kind == "notification":
            msg = hook.get("message", "Waiting for input")
            post(dict(base, type="status", status="working", message=msg))

        elif kind == "userprompt":
            prompt = hook.get("prompt", "")
            post(dict(base, type="status", status="working",
                      message=("You: " + prompt[:60]) if prompt else "Thinking"))

        elif kind == "stop":
            post(dict(base, type="done", message="Done"))

    except Exception as exc:
        # Never break the user's Claude Code session because the island is down.
        sys.stderr.write(f"vibe-hook: {exc}\n")

    sys.exit(0)


if __name__ == "__main__":
    main()
