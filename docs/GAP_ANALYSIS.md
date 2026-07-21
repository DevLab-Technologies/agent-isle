# Agent Isle — Competitive Gap Analysis

**Benchmark:** Vibe Island (vibeisland.app) — the closest commercial competitor and the
app Agent Isle is modeled on.
**Baseline:** the `wt/competitor-ui-review-f97ee7` branch, which already adds the session
task list, the settings window (General / Integrations / Display / Sound / Usage / About),
and usage analytics.
**Method:** feature-by-feature comparison of Vibe Island's UI (notch panel + full
preferences window) against the Agent Isle source. Each gap is grounded in code, not
guesswork; "Missing" means no supporting code exists in this repo.

Priority scale — **P0** = table-stakes parity, **P1** = important differentiator, **P2** =
nice-to-have. Effort — **S** ≈ <1 day, **M** ≈ 1–3 days, **L** ≈ 1 week+.

---

## Executive summary

Agent Isle has strong bones: notch island, auto-discovery of Claude sessions, inline
permission/question cards, live chat with message-send, multi-agent history parsing, hook
install, updater, and now a task list, a settings window, and usage analytics. It is at
rough **UI parity** with Vibe Island for the core "monitor one machine's local Claude
sessions" loop.

The material gaps are in **reach and control**, not looks:

1. **No keyboard control** — no global switcher, no panel hotkeys (approve/deny/jump). This
   is Vibe Island's biggest daily-driver advantage.
2. **No OS notifications** — attention is sound-only; nothing reaches a locked screen or
   Notification Center.
3. **No noise control** — no way to mute/hide sessions by project, prompt, or launcher app,
   and no "quiet scenes" (focus/screen-share). Heavy users drown in probe/worker sessions.
4. **No remote monitoring** — local only; Vibe Island monitors SSH hosts and containers.
5. **No subscription usage limits** — Agent Isle counts *tokens*; Vibe Island surfaces the
   Claude plan's 5-hour/weekly **quota** ("Click to view usage limits").
6. **No richer activity model** — no subagents/fan-out display, no "Always Allow"/Bypass
   decisions, no session archiving.

Recommended near-term focus: **keyboard shortcuts → notifications → session filtering.**
Those three close the gap that users actually feel.

---

## Parity baseline — what Agent Isle already does well

| Capability | Status |
|---|---|
| Notch island (collapsed pill + expanded panel) | ✅ |
| Auto-discovery of Claude sessions (no hook required) | ✅ `IdeWatcher` |
| Inline permission cards with diff preview (Allow/Deny) | ✅ `PermissionCard` |
| Inline multiple-choice question cards | ✅ `QuestionCard` |
| Live chat transcript + send message into session | ✅ `SessionChatView` / `MessageSender` |
| Multi-agent history (Claude, Grok, Copilot) | ✅ `ChatHistory` |
| Task/todo list with progress + overflow | ✅ (this branch) |
| Settings window (6 sections) | ✅ (this branch) |
| Usage analytics (tokens by day/month/project/session) | ✅ (this branch) |
| Hook install/uninstall (Claude Code) | ✅ `HookInstaller` |
| Jump to terminal/IDE | ✅ `Jumper` |
| Auto-update from GitHub releases | ✅ `Updater` |
| Synthesized sound cues | ✅ `SoundPlayer` |

---

## Gap inventory by area

### 1. Session display & activity

| Feature | Vibe Island | Agent Isle | Priority | Effort |
|---|---|---|---|---|
| **Subagents / fan-out display** — nested `Task` subagents under a session with live steps | Yes ("Subagents (1) · Trace Stripe payout…") | **Missing** — no subagent model | P1 | M |
| **Agent activity detail** — "Editing chatEndpoint.ts · 12s" + nested tool steps | Yes | Partial — one `lastMessage` line only | P1 | M |
| **Session archiving** — archive/dismiss a finished session (archive icon on card) | Yes | **Missing** | P2 | S |
| **Collapsed island modes** — Clean vs Detailed preview | Yes | Partial — single collapsed style | P2 | S |
| **Show AI model** on card | Yes (toggle) | **Missing** — model not parsed | P2 | S |

### 2. Notifications & attention control

| Feature | Vibe Island | Agent Isle | Priority | Effort |
|---|---|---|---|---|
| **OS notifications** on completion / approval needed | Yes | **Missing** — sound only, no `UserNotifications` | **P0** | M |
| **Quiet scenes** — auto-silence during Focus, screen locked, screen recording/sharing | Yes | **Missing** | P1 | M |
| **Session filters** — hide by working directory / first-prompt (with presets) | Yes | **Missing** | P1 | M |
| **Blocked launcher apps** — drop sessions spawned by helper apps | Yes | **Missing** | P1 | M |
| **Built-in noise filters** — e.g. Codex internal workers, probe sessions | Yes | **Missing** | P1 | S |
| **Completion reveal + dwell** — panel auto-expands on completion, auto-collapses after N s | Yes | Partial — expands on hover only | P2 | S |

### 3. Keyboard & navigation

| Feature | Vibe Island | Agent Isle | Priority | Effort |
|---|---|---|---|---|
| **Global session switcher** — Alfred-style open + ⌘Tab-style cycle | Yes | **Missing** | **P0** | M |
| **Panel hotkeys** — Approve / Deny / Always-Allow / Bypass / Jump | Yes | **Missing** — mouse only | **P0** | M |
| **Numbered option select** (⌘1–9) for questions | Yes | Partial — shown as labels, not bound | P1 | S |
| **Collapse / Esc**, modifier-key config, on-panel hint overlay | Yes | **Missing** | P1 | M |

### 4. Integrations (CLIs, IDE, hooks)

| Feature | Vibe Island | Agent Isle | Priority | Effort |
|---|---|---|---|---|
| **Multi-CLI hooks** — install for Gemini, Cursor, Grok, Copilot, Copilot-VSCode | Yes (per-CLI toggles) | Partial — hook install is **Claude-only**; others are read-only history | P1 | M |
| **Auto-configure new CLIs** | Yes | **Missing** | P2 | S |
| **Add custom CLI branch** | Yes | **Missing** | P2 | M |
| **IDE extension install** (VS Code) for precise tab-jump | Yes | **Missing** | P2 | M |
| **Disable Claude Code native terminal title** (for reliable Warp/Ghostty jump) | Yes | **Missing** | P2 | S |
| **Custom jump rules** (register URL scheme) | Yes | Partial — `Jumper` has fixed rules | P2 | M |

### 5. Remote & environments

| Feature | Vibe Island | Agent Isle | Priority | Effort |
|---|---|---|---|---|
| **SSH remote monitoring** — monitor/approve sessions on remote hosts | Yes | **Missing** | P1 | L |
| **Docker/Podman container hook bridge** | Yes | **Missing** | P2 | M |
| **Restricted-network / air-gapped manual install** | Yes | **Missing** | P2 | S |

### 6. Usage & limits

| Feature | Vibe Island | Agent Isle | Priority | Effort |
|---|---|---|---|---|
| **Subscription usage limits** in header — plan quota (5-hour / weekly), "Click to view usage limits" | Yes | **Missing** — Agent Isle tracks tokens, not plan quota | P1 | M |
| **Token analytics** (by day/project/session) | Basic | ✅ **Ahead** (charts + filters, this branch) | — | — |

### 7. Behavior & window management

| Feature | Vibe Island | Agent Isle | Priority | Effort |
|---|---|---|---|---|
| **Hover-expand + duration** slider | Yes | Partial — on/off only (this branch), no duration | P2 | S |
| **Smart suppression** — don't auto-expand when the agent's own terminal is focused | Yes | **Missing** | P1 | M |
| **Hide in fullscreen** | Yes | **Missing** | P1 | S |
| **Auto-hide when no active sessions** | Yes | **Missing** | P2 | S |
| **Idle-session cleanup** window (for CLIs without a clear close signal) | Yes | Partial — fixed 8-min active window in `IdeWatcher` | P2 | S |
| **Disable click-to-jump** | Yes | **Missing** | P2 | S |
| **Accessory ⇄ regular policy** so Settings appears in ⌘Tab / has an app menu | n/a | **Missing** — always `.accessory` | P1 | S |

### 8. Reliability / Labs

| Feature | Vibe Island | Agent Isle | Priority | Effort |
|---|---|---|---|---|
| **"Always Allow" / "Bypass" decisions** (beyond Allow/Deny) | Yes | **Missing** — decision is allow/deny only | P1 | S |
| **Auto Mode vs Bypass**, native-approvals passthrough | Yes | **Missing** | P2 | M |
| **Restart-on-high-memory** safety net | Yes | **Missing** | P2 | S |
| **Beta/pre-release update channel** | Yes | Partial — updater has no channel toggle | P2 | S |
| **Cursor sandbox approval** auto-detect | Yes | **Missing** | P2 | M |

### 9. Distribution & licensing

| Feature | Vibe Island | Agent Isle | Priority | Effort |
|---|---|---|---|---|
| **Pass / licensing** (boarding-pass, license & devices) | Yes (paid app) | **Out of scope** — Agent Isle is MIT open-source | — | — |
| **Diagnostic report export** | Yes | **Missing** | P2 | S |
| **Onboarding / hook-setup prompt** | Yes | ✅ (has launch prompt) | — | — |

---

## Prioritized roadmap

**P0 — close the felt gap (target first):**
1. Keyboard shortcuts: global switcher + panel hotkeys (Approve/Deny/Jump, ⌘1–9). *(M)*
2. OS notifications via `UserNotifications` for completion + approval-needed, honoring a
   mute toggle. *(M)*

**P1 — control & reach:**
3. Session filtering (by directory / first-prompt / launcher app) + built-in probe filter. *(M)*
4. Quiet scenes (Focus / locked / screen-share) reusing the notification path. *(M)*
5. "Always Allow" / Bypass decision + smart suppression + hide-in-fullscreen. *(S–M)*
6. Multi-CLI hook install (Gemini, Cursor, Grok, Copilot). *(M)*
7. Subscription usage-limit readout in the header. *(M)*
8. Subagents / richer activity model. *(M)*
9. Settings window `.regular` policy while open (⌘Tab + app menu). *(S)*

**P2 — polish & depth:**
10. SSH remote monitoring. *(L)* — high ceiling, lower urgency.
11. Session archiving, collapsed-island modes, show-model, hover-duration, auto-hide,
    diagnostic export, beta channel, IDE extension. *(S each)*

---

## Explicitly out of scope

- **Pass / licensing** — Agent Isle is MIT open-source; there is no paid tier to gate.
- Anything requiring Vibe Island's private update/hook infrastructure (`edwluo/vibe-island-*`);
  Agent Isle uses its own `DevLab-Technologies/agent-isle` releases.

---

*Generated from the branch's source; token analytics and the settings window described as
"this branch" are the additions in `wt/competitor-ui-review-f97ee7`.*
