# Contributing to Agent Isle

Thanks for your interest! Agent Isle is a small, focused native macOS app, and
contributions — especially **new agent adapters** — are very welcome.

## Getting started

```bash
git clone git@github.com:DevLab-Technologies/agent-isle.git
cd agent-isle
swift build
bash Scripts/bundle.sh && open "build/Agent Isle.app"
```

Requirements: macOS 14+ and a Swift 5.9+ toolchain (Xcode).

## Project layout

See the architecture map in the [README](README.md#architecture). The short version:

- `Sources/AgentIsle/Model` — data model and observable state
- `Sources/AgentIsle/Views` — the SwiftUI island (collapsed + expanded)
- `Sources/AgentIsle/Notch` — the notch-anchored, click-through panel
- `Sources/AgentIsle/Server` — session discovery, the event server, and jump logic

## Adding a new agent

Most agents can be supported without hooks by reading their on-disk session history.
Add an adapter in [`Sources/AgentIsle/Server/ExternalAgents.swift`](Sources/AgentIsle/Server/ExternalAgents.swift):

1. Add a case to `AgentKind` in `Model/Models.swift` with a `displayName`, `tint`, and `glyph`.
2. Add a `scan(activeWindow:limit:)` function that returns `[ExternalSession]` by:
   - locating the tool's session files (e.g. `~/.yourtool/sessions/...`),
   - filtering to files modified within `activeWindow`,
   - extracting the cwd, a one-line last activity, and the modification time.
3. Call it from `ExternalAgents.scanAll`.

Keep adapters **best-effort and non-throwing** — a format change should just make that
agent stop appearing, never crash the app. Verify against real files before opening a PR.

If a tool can't be read from disk (opaque database, protobuf, etc.) but supports hooks,
a hook that POSTs to the event server (see `Scripts/agent-isle-hook.py`) is the way to go.

## Pull requests

- One focused change per PR; include a short description and testing notes.
- Match the surrounding code style (the code favors small, well-commented functions).
- Run `swift build` and launch the app to confirm it works before submitting.

## Reporting issues

Open an issue with your macOS version, the agent/terminal involved, and steps to
reproduce. Screenshots of the notch are helpful.
