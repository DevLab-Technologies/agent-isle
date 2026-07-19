# Claude Island

A Dynamic Island for your coding agents — a native macOS app that lives in the
notch and lets you monitor, approve, and jump back to Claude Code, Codex, Gemini,
Cursor and other agents without leaving your flow.

A native SwiftUI clone of [Vibe Island](https://vibeisland.app). No Electron —
pure Swift, runs as a lightweight menu-bar accessory app.

## What it does

- **Notch-anchored island** — a black pill hugging the notch that expands on hover
  or click into a full panel of every running agent session.
- **Multi-agent monitoring** — Claude, Codex, Gemini, Cursor, OpenCode, Droid,
  Kiro, Amp; each with a live status dot (working / permission / question / done).
- **Approve from the notch** — permission requests render an inline diff preview
  with Deny (⌘N) / Allow (⌘Y). The decision flows straight back to the agent.
- **Answer questions** — multiple-choice prompts answered right in the island.
- **8-bit sound alerts** — synthesized chiptune cues for attention / approve /
  deny / done (no audio files, generated at runtime).
- **Fully local** — a tiny localhost HTTP server is the only moving part; nothing
  leaves your machine.

## Build & run

```bash
swift build                       # compile
bash Scripts/bundle.sh            # build "build/Claude Island.app"
open "build/Claude Island.app"    # launch (appears in the notch + menu bar 🏝️)
```

On launch it shows **demo mode** with simulated sessions so you can see it work.
Toggle demo mode / sound and grab the hook command from the 🏝️ menu-bar item.

## Wire it to real Claude Code sessions

```bash
bash Scripts/install-hooks.sh
```

This adds hooks to `~/.claude/settings.json` that report every Claude Code session
to the island. Then just run `claude` in any project — sessions appear in the notch,
and `PreToolUse` permission prompts can be approved from the island (the hook blocks
on your decision).

To connect any other tool, POST to the event server:

```bash
curl -X POST http://localhost:4711/event -H 'Content-Type: application/json' -d '{
  "type": "status", "session": "my-session", "agent": "codex",
  "title": "build api", "terminal": "iTerm",
  "status": "working", "message": "Writing routes/users.ts"
}'
```

### Event types

| `type`       | Behavior                                                        |
|--------------|----------------------------------------------------------------|
| `status`     | Create/update a session (`status`, `message`, `title`).        |
| `permission` | Show an approval card; **blocks** until you decide, then replies `{"decision":"allow"\|"deny"}`. |
| `question`   | Show options; blocks until chosen, replies `{"decision":"<option>"}`. |
| `done`       | Mark the session finished.                                     |
| `remove`     | Drop the session.                                              |

Permission payload fields: `tool`, `file`, `command`, `added`, `removed`, and an
optional `diff` array of `{kind: added|removed|context, line, text}`.

## Architecture

```
Sources/ClaudeIsland/
  main.swift              App entry (NSApplication, accessory policy)
  AppDelegate.swift       Notch window + menu-bar item + demo/server wiring
  Notch/
    NotchGeometry.swift   Detects the physical notch (falls back to a centered pill)
    NotchWindow.swift     Borderless floating NSPanel anchored over the notch
  Views/
    IslandRootView.swift  Collapsed <-> expanded switch, spring animations, NotchShape
    CollapsedIsland.swift  Resting pill (focus session + count badge)
    ExpandedIsland.swift   Full panel: header, session list, action bar
    SessionRow.swift       Per-session row with agent badge + status
    PermissionCard.swift   Inline diff + Allow/Deny; QuestionCard for choices
  Model/
    Models.swift          AgentKind, SessionStatus, AgentSession, PermissionRequest
    SessionStore.swift    Observable state + demo generator
  Server/
    EventServer.swift     Localhost HTTP listener; parks blocking requests
  Sound/
    SoundPlayer.swift     Runtime-synthesized square-wave alerts
Scripts/
  bundle.sh               Package the binary into a .app
  install-hooks.sh        Register Claude Code hooks
  vibe-hook.py            Claude Code -> island bridge (approvals block on the notch)
```

Built by Ahmed · runs on Apple Silicon, macOS 14+.
