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

Usage:  agent-isle-hook.py <event-kind> [--agent <name>]
        event-kind in: pretooluse | posttooluse | notification | stop | userprompt
        --agent tags the session's agent (default "claude"); any CLI whose hook payload
        matches Claude Code's shape can reuse this bridge by passing its own name.
"""
import json
import os
import re
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
# Tools whose rule specifier is a gitignore-style path, and the input key holding it.
PATH_TOOLS = {
    "Read": "file_path", "Edit": "file_path", "Write": "file_path",
    "MultiEdit": "file_path", "NotebookEdit": "notebook_path",
    "Glob": "path", "Grep": "path", "LS": "path",
}
# Enterprise policy file (macOS); merged like any other settings file.
MANAGED_SETTINGS = "/Library/Application Support/ClaudeCode/managed-settings.json"
# A command that chains or substitutes could smuggle anything past a prefix rule, so it
# is never matched against one — the island asks and the user decides.
SHELL_CHAINING = re.compile(r"&&|\|\||;|\||`|\$\(|>|<|\n")


def _project_root(cwd):
    """The outermost directory Claude Code treats as the project: the nearest ancestor
    holding a `.git`, never crossing above $HOME. Falls back to `cwd` when there is no
    repo, so a stray `.claude/` in an unrelated ancestor can't contribute rules."""
    home = os.path.abspath(os.path.expanduser("~"))
    d = cwd
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d or d == home:
            return cwd
        d = parent


def _settings_files(cwd):
    """Every settings file Claude Code merges for a call in `cwd`, each paired with the
    directory its relative path rules resolve against: managed policy, user settings, and
    the project chain from its root down to `cwd` (Claude Code honors nested `.claude/`
    dirs inside a project, but nothing above its root). Ordered outermost-first; buckets
    are unioned rather than overridden, so the order only affects which rule is reported
    first for an equally-matching pair."""
    out = [(MANAGED_SETTINGS, "/")]
    user_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    user_settings = os.path.join(user_dir, "settings.json")
    out.append((user_settings, os.path.expanduser("~")))
    d = os.path.abspath(cwd) if cwd else os.getcwd()
    root = _project_root(d)
    chain = []
    while True:
        chain.append(d)
        parent = os.path.dirname(d)
        if d == root or parent == d:
            break
        d = parent
    for d in reversed(chain):
        for name in ("settings.json", "settings.local.json"):
            path = os.path.join(d, ".claude", name)
            if path != user_settings:  # already added above, with its own base dir
                out.append((path, d))
    return out


_RULES_CACHE = {}


def load_rules(cwd):
    """Merge `permissions.allow/ask/deny` from every settings file into
    {bucket: [(rule, base_dir)]}. Unreadable or malformed files are skipped silently: a
    broken settings file must not stop the island from prompting."""
    if cwd in _RULES_CACHE:
        return _RULES_CACHE[cwd]
    rules = {"allow": [], "ask": [], "deny": []}
    for path, base in _settings_files(cwd):
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            continue
        perms = (data or {}).get("permissions") or {}
        for bucket in rules:
            for rule in perms.get(bucket) or []:
                if isinstance(rule, str) and rule.strip():
                    rules[bucket].append((rule.strip(), base))
    _RULES_CACHE[cwd] = rules
    return rules


def _split_rule(rule):
    """"Bash(git status:*)" -> ("Bash", "git status:*"); "Read" -> ("Read", None)."""
    if rule.endswith(")") and "(" in rule:
        name, _, spec = rule.partition("(")
        return name.strip(), spec[:-1]
    return rule, None


def _norm_cmd(s):
    return " ".join((s or "").split())


def _bash_matches(spec, command):
    """Claude Code's Bash rules are exact ("git status") or a prefix ("git status:*")."""
    # Guard the raw command: _norm_cmd collapses newlines, so a multiline command would
    # otherwise read as a single line and satisfy a prefix rule.
    if SHELL_CHAINING.search(command or ""):
        return False
    cmd = _norm_cmd(command)
    if not cmd:
        return False
    if spec.endswith(":*"):
        prefix = _norm_cmd(spec[:-2])
        return bool(prefix) and (cmd == prefix or cmd.startswith(prefix + " "))
    return cmd == _norm_cmd(spec)


def _resolve_pattern(spec, base):
    """`//abs/path` is filesystem-absolute, `~/x` home-relative, anything else relative to
    the directory of the settings file that declared the rule."""
    if spec.startswith("//"):
        pattern = spec[1:]
    elif spec == "~" or spec.startswith("~/"):
        pattern = os.path.expanduser(spec)
    else:
        pattern = os.path.join(base, spec)
    # Normalized to match the target, which _path_matches runs through abspath.
    return os.path.normpath(pattern)


def _glob_to_regex(pattern):
    """gitignore-style globbing: `*` stops at a path separator, `**` crosses it."""
    out = []
    i = 0
    while i < len(pattern):
        if pattern[i] == "*":
            if pattern[i:i + 2] == "**":
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
        elif pattern[i] == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(pattern[i]))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def _path_matches(spec, target, base, cwd):
    """A rule path matches the tool's target, or anything under it when the rule names a
    bare directory (gitignore semantics). `base` resolves the rule's own pattern; a
    relative target belongs to the session, so it resolves against `cwd`."""
    if not target:
        return False
    target = os.path.abspath(os.path.join(cwd or os.getcwd(), os.path.expanduser(target)))
    pattern = _resolve_pattern(spec, base)
    if "*" in pattern or "?" in pattern:
        return bool(_glob_to_regex(pattern).match(target))
    pattern = os.path.abspath(pattern)
    return target == pattern or target.startswith(pattern.rstrip("/") + "/")


def _domain_matches(spec, url):
    """WebFetch rules are written `domain:example.com` and cover subdomains."""
    if not spec.startswith("domain:"):
        return False
    want = spec[len("domain:"):].strip().lower().lstrip(".")
    m = re.match(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://([^/?#]+)", url or "")
    if not (want and m):
        return False
    host = m.group(1).rsplit("@", 1)[-1].split(":")[0].lower()
    return host == want or host.endswith("." + want)


def _rule_matches(rule, base, tool, tool_input, cwd):
    name, spec = _split_rule(rule)
    if name.startswith("mcp__"):
        # `mcp__server` covers a whole server; `mcp__server__tool` one of its tools.
        return tool == name or tool.startswith(name + "__")
    if name != tool:
        return False
    if spec is None:
        return True  # a bare tool name covers every use of that tool
    if tool == "Bash":
        return _bash_matches(spec, tool_input.get("command"))
    if tool == "WebFetch":
        return _domain_matches(spec, tool_input.get("url"))
    key = PATH_TOOLS.get(tool)
    if key:
        return _path_matches(spec, tool_input.get(key), base, cwd)
    return False  # specifier shape we don't understand — fall through and ask


def rule_verdict(tool, tool_input, cwd):
    """The user's own permission rules for this exact call: "deny", "ask", "allow", or
    None when no rule applies. deny beats ask beats allow, as in Claude Code."""
    if os.environ.get("AGENT_ISLE_IGNORE_RULES") == "1":
        return None
    try:
        rules = load_rules(cwd)
    except Exception:
        return None
    for bucket in ("deny", "ask", "allow"):
        for rule, base in rules[bucket]:
            try:
                if _rule_matches(rule, base, tool, tool_input, cwd):
                    return bucket
            except Exception:
                continue
    return None


def should_ask(mode, tool, tool_input=None, cwd=""):
    """Mirror when Claude Code would actually prompt, so the island intercepts the
    same requests instead of prompting on every tool or on none."""
    tool_input = tool_input or {}
    if os.environ.get("AGENT_ISLE_APPROVALS") == "0":
        return False
    if mode == "bypassPermissions" or mode == "plan":
        return False
    # The user's own rules — including every "don't ask again" Claude Code has recorded —
    # decide before any heuristic. A deny needs no prompt either: staying quiet lets
    # Claude Code block the call itself, and an `ask` rule outranks acceptEdits.
    verdict = rule_verdict(tool, tool_input, cwd)
    if verdict == "ask":
        return True
    if verdict in ("allow", "deny"):
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


def parse_args(argv):
    """First positional arg is the event kind; `--agent <name>` optionally overrides the
    agent tag. Kept dependency-free (no argparse) to stay a fast, importless hook."""
    kind = "notification"
    agent = "claude"
    positional = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--agent" and i + 1 < len(argv):
            agent = argv[i + 1]
            i += 2
            continue
        positional.append(a)
        i += 1
    if positional:
        kind = positional[0]
    return kind, agent


def main():
    kind, agent = parse_args(sys.argv[1:])
    raw = sys.stdin.read()
    try:
        hook = json.loads(raw)
    except Exception:
        hook = {}
    if os.environ.get("AGENT_ISLE_DEBUG") == "1":
        # Private path + mode: payloads include prompts and tool inputs.
        try:
            debug_dir = os.path.join(os.path.expanduser("~"), ".agent-isle")
            os.makedirs(debug_dir, mode=0o700, exist_ok=True)
            path = os.path.join(debug_dir, "hook-debug.jsonl")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "a") as _f:
                _f.write(kind + " " + raw + "\n")
        except Exception:
            pass

    session = hook.get("session_id", "claude-session")
    cwd = hook.get("cwd", "")
    title = cwd.split("/")[-1] if cwd else "claude session"

    term_label, term_bundle = detect_terminal()
    base = {
        "session": session,
        "agent": agent,
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
            if should_ask(mode, tool, tin, cwd):
                event = dict(base, type="permission", tool=tool,
                             file=short_path(tin.get("file_path")),
                             command=tin.get("command"),
                             message=f"Wants to run {tool}")
                result = post(event, timeout=TIMEOUT)
                decision = result.get("decision")
                # Only an explicit allow/deny is a decision. Missing, malformed, or
                # error replies (bad json, request too large, parked-question free-text)
                # must not approve — and must not hard-deny either: defer to Claude's
                # own prompt, same as ask_question / review_plan / the outer except.
                if decision not in ("allow", "yes", "deny", "no"):
                    sys.exit(0)
                allow = decision in ("allow", "yes")
                print(json.dumps({
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "allow" if allow else "deny",
                        "permissionDecisionReason": "Decided from Agent Isle",
                    }
                }))
            else:
                # Non-blocking: just report activity, let Claude Code proceed normally.
                # A deny-matched call never runs — Claude Code blocks it — so don't
                # report it as running.
                blocked = rule_verdict(tool, tin, cwd) == "deny"
                post(dict(base, type="status", status="working",
                          message=f"Blocked {tool}" if blocked else f"Running {tool}"))
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
