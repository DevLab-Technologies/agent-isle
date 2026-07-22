#!/usr/bin/env python3
"""
Claude Code -> Agent Isle bridge.

Configured as a Claude Code hook (see install-hooks.sh). Claude Code pipes a JSON
payload on stdin for each hook event; this script translates it into a Agent Isle
`/event` POST so the session shows up in the notch.

For PreToolUse it BLOCKS on the island's decision and echoes the allow/deny back to
Claude Code in the hook output format, so you can approve tools right from the notch.
The AskUserQuestion tool is a special case: it's shown as a question card and the chosen
answer is fed back to Claude, so multiple-choice questions can be answered from the notch.

Usage:  agent-isle-hook.py <event-kind>
        event-kind in: pretooluse | posttooluse | notification | stop | userprompt
"""
import json
import os
import sys
import urllib.request

ISLAND_URL = "http://localhost:4711/event"
TIMEOUT = 280  # seconds to wait for a notch decision before falling back to Claude's own prompt

# Tools Claude Code never prompts for (read-only / bookkeeping) — don't gate these.
READONLY_TOOLS = {
    "Read", "Glob", "Grep", "LS", "NotebookRead", "TodoWrite", "Task",
    "WebSearch", "BashOutput", "KillBash",
}
# Tools that are auto-approved specifically in acceptEdits mode.
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit", "Update"}


def should_ask(mode, tool):
    """Mirror when Claude Code would actually prompt, so the island intercepts the
    same requests instead of prompting on every tool or on none."""
    if os.environ.get("AGENT_ISLE_APPROVALS") == "0":
        return False
    if mode == "bypassPermissions" or mode == "plan":
        return False
    if tool in READONLY_TOOLS:
        return False
    if mode == "acceptEdits" and tool in EDIT_TOOLS:
        return False
    return True  # default / acceptEdits(non-edit) / unknown mode


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


def ask_question(base, tool_input):
    """Handle Claude's AskUserQuestion tool: show every question in the notch, wait for
    the answers, and feed them back to Claude by denying the tool with the answers as the
    reason (a PreToolUse hook can't return a tool result, only allow/deny + reason).

    All questions in the call are shown together in one card; the notch supports
    single-select, multi-select, and a free-text "Other" field per question, so the
    returned answer is a headed line per question. A question with no options, or a
    malformed input, returns False so the caller falls back to Claude's own native
    picker. A notch timeout raises out of post() and is caught by the caller, likewise
    falling back to native.

    Returns True when the questions were handled here (caller should exit)."""
    questions = tool_input.get("questions") or []
    if not questions:
        return False

    wire = []
    for q in questions:
        options = [o.get("label", "") for o in (q.get("options") or []) if o.get("label")]
        if not options:
            return False  # can't represent an option-less question — defer to native
        wire.append({
            "header": q.get("header") or "",
            "question": q.get("question") or q.get("header") or "Choose an option",
            "options": options,
            "multiSelect": bool(q.get("multiSelect")),
            "allowOther": True,
        })

    result = post(dict(base, type="question", questions=wire), timeout=TIMEOUT)
    answer = result.get("decision")
    # No usable answer → let Claude prompt natively. Empty means the prompt was
    # abandoned; "allow"/"deny" is the island's fail-safe reply when it can't encode a
    # real answer (see EventServer.reply), never a genuine question response.
    if not answer or answer in ("allow", "deny"):
        return False

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "The user answered from Agent Isle:\n" + answer +
                "\nUse these answers and continue; do not call AskUserQuestion again for this."
            ),
        }
    }))
    return True


def review_plan(base, tool_input):
    """Handle Claude's ExitPlanMode tool: show the plan in the notch as a Markdown card,
    wait for the user to approve it or send feedback, and feed the result back to Claude.

    Approval allows the tool (Claude proceeds with the plan). Feedback denies the tool with
    the feedback as the reason, so Claude revises the plan instead of executing it — the same
    allow/deny channel a PreToolUse hook is limited to.

    Returns True when handled here (caller should exit). An empty plan, or a notch timeout /
    abandonment, returns False so the caller falls back to Claude's own plan approval UI."""
    plan = (tool_input.get("plan") or "").strip()
    if not plan:
        return False

    result = post(dict(base, type="plan", plan=plan,
                       message="Shared a plan for review"), timeout=TIMEOUT)
    decision = result.get("decision")
    # Empty means the card was abandoned; "deny" is the island's fail-safe reply when it
    # couldn't encode a real decision — either way defer to Claude's native plan prompt.
    if not decision or decision == "deny":
        return False

    if decision in ("approve", "allow", "yes"):
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "Plan approved from Agent Isle",
            }
        }))
        return True

    # Anything else is feedback: deny the plan and hand the feedback back for a revision.
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "The user reviewed the plan in Agent Isle and asked for changes:\n" + decision +
                "\nRevise the plan accordingly and present it again."
            ),
        }
    }))
    return True


def detect_terminal():
    """Identify the real host terminal/IDE from the CLI's environment.

    TERM_PROGRAM tells us the terminal; for VS Code-family editors we use the
    hosting app's bundle id to tell VS Code / Cursor / Windsurf apart. Returns
    (label, bundle_id)."""
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
        label = vscode_family.get(bundle, "VS Code")
        return label, (bundle or "com.microsoft.VSCode")
    if tp in known:
        label, bid = known[tp]
        return label, bid
    if bundle in vscode_family:
        return vscode_family[bundle], bundle
    if bundle:
        return (tp or "Terminal"), bundle
    return (tp or "Terminal"), None


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else "notification"
    raw = sys.stdin.read()
    try:
        hook = json.loads(raw)
    except Exception:
        hook = {}
    if os.environ.get("AGENT_ISLE_DEBUG") == "1":
        try:
            with open("/tmp/agent-isle-hook-debug.jsonl", "a") as _f:
                _f.write(kind + " " + raw + "\n")
        except Exception:
            pass

    session = hook.get("session_id", "claude-session")
    cwd = hook.get("cwd", "")
    title = cwd.split("/")[-1] if cwd else "claude session"

    term_label, term_bundle = detect_terminal()
    base = {
        "session": session,
        "agent": "claude",
        "title": title,
        "terminal": term_label,
        "term_bundle": term_bundle,
    }

    mode = hook.get("permission_mode") or hook.get("permissionMode") or "default"

    try:
        if kind == "pretooluse":
            tool = hook.get("tool_name", "Tool")
            tin = hook.get("tool_input", {}) or {}
            # Claude's own "AskUserQuestion" tool is a question, not a tool to gate.
            # Surface it as a proper question card so it can be answered from the notch,
            # instead of a generic allow/deny "Wants to run AskUserQuestion" prompt. A
            # question is never gated as allow/deny: if it isn't handled here (multi-part
            # question, or the user didn't answer in the notch), just report activity and
            # let Claude's own native picker take over.
            if tool == "AskUserQuestion":
                if not ask_question(base, tin):
                    post(dict(base, type="status", status="working",
                              message="Asking a question"))
                sys.exit(0)
            # ExitPlanMode presents a plan, not a tool to gate. Surface it as a plan-review
            # card so it can be approved (or sent back with feedback) from the notch. If it
            # isn't handled there, report activity and let Claude's native plan prompt run.
            if tool == "ExitPlanMode":
                if not review_plan(base, tin):
                    post(dict(base, type="status", status="working",
                              message="Presented a plan"))
                sys.exit(0)
            if should_ask(mode, tool):
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
                        "permissionDecisionReason": "Decided from Agent Isle",
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
        sys.stderr.write(f"agent-isle-hook: {exc}\n")

    sys.exit(0)


if __name__ == "__main__":
    main()
