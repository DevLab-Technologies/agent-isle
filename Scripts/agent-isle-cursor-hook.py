#!/usr/bin/env python3
"""
Cursor CLI -> Agent Isle bridge.

Configured as a Cursor agent hook (see CursorHookInstaller / install-cursor-hooks.sh).
Cursor pipes a single JSON payload on stdin for each hook event and reads a single JSON
object back on stdout. This script translates the payload into an Agent Isle `/event`
POST so the Cursor session shows up in the notch.

For the gating events (beforeShellExecution / beforeMCPExecution / beforeFileEdit) it
BLOCKS on the island's decision and echoes it back to Cursor as a permission decision, so
you can approve tool calls right from the notch. If the island can't be reached or you
don't answer in time, it returns `ask` — Cursor then falls back to its own native prompt,
so a stopped island never blocks your session.

Unlike Claude Code, the event name is taken from the payload's `hook_event_name`, so
every hook in ~/.cursor/hooks.json maps to this one command with no arguments.

Decision schema (Cursor docs, snake_case):
    {"permission": "allow" | "deny" | "ask", "user_message": "...", "agent_message": "..."}
`beforeSubmitPrompt` uses {"continue": true|false} instead; observational hooks ignore
stdout entirely.
"""
import json
import os
import sys
import urllib.request

ISLAND_URL = "http://localhost:4711/event"
TIMEOUT = 280  # seconds to wait for a notch decision before falling back to Cursor's native prompt

# Gating events that ask the notch for an allow/deny, keyed to how we label them.
GATING = {"beforeShellExecution", "beforeMCPExecution", "beforeFileEdit"}


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


def emit(decision):
    """Print a single JSON decision object (snake_case, per Cursor docs) and exit 0."""
    print(json.dumps(decision))
    sys.exit(0)


def allow():
    emit({"permission": "allow"})


def deny(reason="Denied from Agent Isle"):
    emit({"permission": "deny", "user_message": reason, "agent_message": reason})


def ask():
    # Hand the decision back to Cursor's own prompt — used when the island is
    # unreachable or the prompt was abandoned, so we never block the session.
    emit({"permission": "ask"})


def detect_terminal():
    """Identify the real host terminal/IDE from the CLI's environment, matching the
    Claude bridge so Jump focuses the right app. Returns (label, bundle_id)."""
    tp = os.environ.get("TERM_PROGRAM", "") or ""
    bundle = os.environ.get("__CFBundleIdentifier", "") or ""

    vscode_family = {
        "com.microsoft.VSCode": "VS Code",
        "com.microsoft.VSCodeInsiders": "VS Code",
        "com.visualstudio.code.oss": "VS Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
    }
    known = {
        "Apple_Terminal": ("Terminal", "com.apple.Terminal"),
        "iTerm.app": ("iTerm", "com.googlecode.iterm2"),
        "ghostty": ("Ghostty", "com.mitchellh.ghostty"),
        "WezTerm": ("WezTerm", "com.github.wez.wezterm"),
        "WarpTerminal": ("Warp", "dev.warp.Warp-Stable"),
        "Hyper": ("Hyper", "co.zeit.hyper"),
        "Tabby": ("Tabby", "org.tabby"),
        "kitty": ("Kitty", "net.kovidgoyal.kitty"),
        "rio": ("Rio", "com.raphaelamorim.rio"),
    }

    if tp == "vscode":
        return vscode_family.get(bundle, "VS Code"), (bundle or "com.microsoft.VSCode")
    if tp in known:
        label, bid = known[tp]
        return label, bid
    if bundle in vscode_family:
        return vscode_family[bundle], bundle
    if bundle:
        return (tp or "Cursor CLI"), bundle
    return "Cursor CLI", None


def workspace(hook):
    """Best cwd for the session: the shell's own cwd, else the first workspace root,
    else the CURSOR_PROJECT_DIR env var (all per the Cursor hooks docs)."""
    cwd = hook.get("cwd")
    if not cwd:
        roots = hook.get("workspace_roots") or []
        cwd = roots[0] if roots else os.environ.get("CURSOR_PROJECT_DIR", "")
    return cwd or ""


def main():
    raw = sys.stdin.read()
    try:
        hook = json.loads(raw)
    except Exception:
        hook = {}
    event = hook.get("hook_event_name") or (sys.argv[1] if len(sys.argv) > 1 else "")

    if os.environ.get("AGENT_ISLE_DEBUG") == "1":
        try:
            with open("/tmp/agent-isle-cursor-hook-debug.jsonl", "a") as _f:
                _f.write((event or "?") + " " + raw + "\n")
        except Exception:
            pass

    # Cursor's stable per-run id; falls back so a session still groups if it's absent.
    session = hook.get("conversation_id") or "cursor-session"
    cwd = workspace(hook)
    title = cwd.split("/")[-1] if cwd else "cursor session"
    model = hook.get("model") or hook.get("model_id")

    term_label, term_bundle = detect_terminal()
    base = {
        "session": session,
        "agent": "cursor",
        "title": title,
        "terminal": term_label,
        "term_bundle": term_bundle,
        "model": model,
    }

    gating = event in GATING and os.environ.get("AGENT_ISLE_APPROVALS") != "0"

    try:
        if gating:
            if event == "beforeShellExecution":
                tool, file, command = "Shell", None, hook.get("command")
                message = "Wants to run a command"
            elif event == "beforeMCPExecution":
                tool = hook.get("tool_name") or "MCP"
                file, command = None, hook.get("command") or hook.get("url")
                message = f"Wants to run {tool}"
            else:  # beforeFileEdit
                tool = "Edit"
                file, command = short_path(hook.get("file_path")), None
                message = f"Wants to edit {os.path.basename(hook.get('file_path') or '') or 'a file'}"

            result = post(dict(base, type="permission", tool=tool,
                               file=file, command=command, message=message),
                          timeout=TIMEOUT)
            decision = result.get("decision", "")
            if decision in ("deny", "no"):
                deny()
            elif decision in ("allow", "yes") or decision:
                # Any non-empty non-deny answer (incl. an "Other" free-text reply) approves.
                allow()
            else:
                ask()  # abandoned in the notch -> let Cursor prompt natively
            return

        # Non-gating events: report activity, never block.
        if event == "beforeSubmitPrompt":
            prompt = (hook.get("prompt") or "").strip()
            post(dict(base, type="status", status="working",
                      message=("You: " + prompt[:60]) if prompt else "Thinking"))
            emit({"continue": True})  # this event decides via `continue`, not `permission`

        elif event == "afterShellExecution":
            cmd = (hook.get("command") or "command")[:40]
            post(dict(base, type="status", status="working", message=f"Ran: {cmd}"))

        elif event == "afterMCPExecution":
            post(dict(base, type="status", status="working",
                      message=f"Ran {hook.get('tool_name') or 'a tool'}"))

        elif event == "afterFileEdit":
            name = os.path.basename(hook.get("file_path") or "") or "a file"
            post(dict(base, type="status", status="working", message=f"Edited {name}"))

        elif event in ("afterAgentResponse", "afterAgentThought"):
            text = (hook.get("text") or "").strip().split("\n")[0]
            post(dict(base, type="status", status="working",
                      message=text[:80] if text else "Thinking"))

        elif event == "stop":
            post(dict(base, type="done", message="Done"))

        else:
            # Unknown / observational event: a lightweight heartbeat keeps the row fresh.
            post(dict(base, type="status", status="working", message="Working"))

    except Exception as exc:
        # Never break the user's Cursor session because the island is down. A gating hook
        # that failed to reach the notch defers to Cursor's native prompt.
        sys.stderr.write(f"agent-isle-cursor-hook: {exc}\n")
        if gating:
            ask()

    sys.exit(0)


if __name__ == "__main__":
    main()
