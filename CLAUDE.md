# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Agent Isle is a native macOS menu-bar accessory app (Swift/SwiftUI/AppKit, no third-party dependencies) that renders a "Dynamic Island" in the MacBook notch to monitor AI coding-agent sessions, approve their permission requests, and chat with them. It runs as an `LSUIElement` (no dock icon) and force-terminates other running copies on launch so only one instance owns the event port.

## Commands

```bash
swift build                     # debug build
swift test                      # run all tests
swift test --filter ChatHistoryTests   # run a single test target/case
bash Scripts/bundle.sh          # build "build/Agent Isle.app" (release; pass "debug" for a debug bundle)
open "build/Agent Isle.app"     # launch
bash Scripts/release.sh         # universal build + optional notarization + zip
```

To exercise permission approvals end-to-end you must run the app AND install the Claude Code hooks (`bash Scripts/install-hooks.sh`); monitoring works without hooks.

## Architecture

Three cooperating layers, all under `Sources/AgentIsle/`:

1. **UI (Notch/, Views/)** — `AppDelegate` builds a fixed-size floating `NotchWindow` pinned over the notch (`NotchGeometry` detects the physical notch, else centers a pill). `PassthroughView` makes the window click-through everywhere except the island itself. `IslandRootView` toggles collapsed↔expanded.

2. **State (Model/)** — `SessionStore` is the single `ObservableObject` source of truth (sessions, filters, demo mode). Everything else feeds it or reads from it.

3. **Ingest (Server/)** — two independent input paths populate the store:
   - **Hook-free watching**: `IdeWatcher` discovers Claude Code sessions by tailing `~/.claude/projects/` transcripts (`TranscriptReader`/`TranscriptTailer` extract activity + token totals); `ExternalAgents` adapts Grok (`~/.grok/sessions`) and Copilot (`~/.copilot/history-session-state`). This is read-only and always on.
   - **Event server**: `EventServer` is an `NWListener` HTTP server on `127.0.0.1:4711`. Any tool POSTs to `/event`. Read the module comment before touching it — see the parking model below.

### The permission "parking" model (critical, non-obvious)

`permission` and `question` events **block the HTTP connection** rather than replying immediately. `EventServer` parks the `NWConnection` in a `pending[sessionID]` map, keyed by session. When the user taps Allow/Deny in the UI, `SessionStore` calls back into the server to `reply()` on the parked connection with `{"decision":...}`, which unblocks the waiting agent. A new prompt for the same session supersedes (cancels) any still-parked one; when a session ends or is removed, its parked prompt is unparked (abandoned) since the decision is moot.

The Python bridge `Scripts/agent-isle-hook.py` is the Claude Code end of this: it is registered as `PreToolUse`/`PostToolUse`/`Notification`/`Stop`/`UserPromptSubmit` hooks. `PreToolUse` blocks (300s timeout) awaiting the notch decision and echoes it back in Claude's `hookSpecificOutput` format. Its `should_ask()` mirrors when Claude Code would actually prompt (skips read-only tools, respects `acceptEdits`/`plan`/`bypassPermissions` modes) so the island intercepts the same requests Claude would — keep this in sync with Claude Code's permission behavior. `AGENT_ISLE_APPROVALS=0` disables gating; `AGENT_ISLE_DEBUG=1` logs payloads to `/tmp/agent-isle-hook-debug.jsonl`. The hook must never break the user's session, so all failures are swallowed and it exits 0.

### Hook installation

Two install paths exist and must stay consistent:
- `Scripts/install-hooks.sh` / `uninstall-hooks.sh` — shell scripts that edit `~/.claude/settings.json` (honors `CLAUDE_CONFIG_DIR`), pointing hooks at the in-repo `Scripts/agent-isle-hook.py`.
- `Server/HookInstaller.swift` — the in-app installer. It copies the bundled hook to `~/.agent-isle/agent-isle-hook.py` and writes the same hook entries into `~/.claude/settings.json`. When editing the Python bridge or the hook entry shape, update **both** this and the shell scripts.

### Other Server/ modules

`Jumper` focuses a session's terminal/IDE (terminal detected via `TERM_PROGRAM` + `__CFBundleIdentifier`). `MessageSender` sends chat messages into a live session; `ChatHistory` loads per-agent chat history. `Updater` polls GitHub Releases (`DevLab-Technologies/agent-isle`) ~every 6h and installs the notarized zip.

`Sound/SoundPlayer` synthesizes square-wave chiptune alerts at runtime — there are no audio asset files.

## Conventions

- **No external dependencies.** Use system frameworks (SwiftUI, AppKit, Network) only; don't add SwiftPM dependencies.
- **New agent adapters** are small additions to `ExternalAgents.swift` that read a tool's session history and return `ExternalSession` values.
- The event server is deliberately pinned to `127.0.0.1` via `requiredLocalEndpoint` to reject LAN injection — do not loosen this.
- Adding an event type or changing the `/event` JSON contract means updating `EventServer`, `agent-isle-hook.py`, and the event-type table in `README.md` together.
