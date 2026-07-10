# PRD: Session Wake — Auto-Resume Blocked CLI Sessions After Quota Reset

## Executive Summary

MeterBar already tells users **when** their Claude Code and Codex CLI quotas reset. **Session Wake** adds the action layer: discover sessions blocked on usage limits, wait until the primary quota window opens, then headlessly resume them one at a time with a configurable prompt (default: `continue`).

This turns MeterBar from a passive monitor into an overnight automation tool — especially for power users running many parallel agent sessions who hit the 5-hour session limit before quota resets.

**v1 scope:** Claude Code only, headless CLI resume, single active account per machine, opt-in from Settings.

---

## Problem Statement

Power users of Claude Code and Codex CLI routinely run many long-lived sessions across worktrees and projects. When the 5-hour session limit is exhausted:

1. Sessions stop mid-task with only a rate-limit message in the transcript.
2. Users must manually reopen each session and type `continue` after reset — tedious at scale (10–30+ sessions).
3. MeterBar shows reset countdowns but provides no recovery path.
4. External workarounds (launchd + Python scripts) exist but are invisible, machine-specific, and disconnected from the quota data MeterBar already fetches.

Users going to bed with blocked sessions wake up to idle agents unless they manually intervene or maintain bespoke automation.

---

## Goals

### Primary goals
- Detect Claude Code sessions blocked on usage limits from local transcript data.
- Wait until the active account's 5h quota window is available (API reset time + configurable buffer).
- Resume blocked sessions sequentially via headless CLI without GUI automation.
- Surface status in MeterBar UI and optional macOS notifications.

### Non-goals (v1)
- Resuming live Claude Desktop GUI sessions via `osascript` / Accessibility.
- Codex thread resume (defer to v1.1).
- Multi-machine orchestration (Mac Studio + MBP coordination).
- Consuming OpenAI/Anthropic "reset credits" automatically.
- Replacing or conflicting with user's existing `launchd` jobs (coexist, don't fight).

### Success metrics
- User can enable Session Wake, go to bed blocked, and find ≥1 session actively resumed after reset without manual CLI interaction.
- Zero resume attempts while quota is still blocked (no rate-limit spam).
- Blocked session count in UI matches manual audit of `*.jsonl` transcripts within ±1.

---

## User Stories

1. **As a developer hitting session limits**, I want MeterBar to resume my blocked Claude sessions after reset so I don't manually type `continue` in 20 terminals.
2. **As a multi-account user**, I want Session Wake to respect my active `CLAUDE_CONFIG_DIR` profile so only the correct account's sessions are resumed.
3. **As a cautious user**, I want a dry-run/preview of which sessions would be resumed before enabling overnight automation.
4. **As a morning user**, I want a notification summarizing how many sessions resumed successfully vs skipped/failed.
5. **As a user who changes plans**, I want a dedicated **Wake Watcher** toggle I can flip off anytime so MeterBar stops polling and does not resume sessions until I turn it back on.

---

## Functional Requirements

### FR-1: Blocked session discovery (Claude)
- Scan `CLAUDE_CONFIG_DIR/projects/**/*.jsonl` (fallback: active account dir from MeterBar's configured Claude profile).
- A session is **blocked** when the transcript tail contains `error: rate_limit` or an API error message containing `session limit`.
- Exclude `/subagents/` transcript paths.
- Deduplicate by `session_id`.
- Resolve `cwd` from session metadata (`sessions/*.json`) or transcript fields.

### FR-2: Quota gate
- Reuse existing Claude usage fetch (`ClaudeCodeCLIUsageService` / OAuth usage API) to read primary 5h window utilization and `resets_at`.
- **Do not resume** when primary window is blocked (`utilization >= 100` or equivalent).
- **`--wait` mode:** poll usage until primary window is unblocked, sleeping until `resets_at + bufferSecs` (default buffer: 90s).
- Poll interval configurable (default: 60s).

### FR-3: Sequential headless resume
- For each blocked session (oldest-first or most-recently-updated-first — document choice):
  ```bash
  claude -r <session_id> -p "<prompt>" \
    --print --output-format text \
    --dangerously-skip-permissions
  ```
- Set `CLAUDE_CONFIG_DIR` to the MeterBar-configured account directory.
- Configurable inter-session gap (default: 20s).
- Configurable per-session timeout (default: 7200s).
- Configurable max sessions per run (default: unlimited; 0 = all).
- Configurable prompt (default: `continue`).
- File lock to prevent concurrent wake runs.

### FR-4: Settings UI (`Settings → Automation`)

Two independent toggles — feature config vs active watcher:

| Setting | Type | Default | Behavior |
|---------|------|---------|----------|
| **Enable Session Wake** | toggle | off | Master switch. When off: no discovery runs, no resume, watcher cannot start. Persists user intent to use the feature. |
| **Wake Watcher** | toggle | off | **Active on/off for the quota watcher.** When on: MeterBar polls quota and runs the wait→resume loop (if blocked). When off: **immediately cancels** any in-progress watch, stops polling, and does not resume until toggled on again. |
| Max sessions per run | int | 0 (all) | Only applies when watcher runs |
| Gap between sessions (seconds) | int | 20 | |
| Buffer after reset (seconds) | int | 90 | |
| Resume prompt | string | see `resume-quota-prompt.txt` pattern | |
| Notify on completion | toggle | on | |

**Toggle rules (required):**
- `Enable Session Wake` off → `Wake Watcher` forced off and disabled in UI.
- `Wake Watcher` on while quota already open → run resume pass immediately (no wait).
- `Wake Watcher` off mid-wait → cancel sleep/poll loop within one poll interval; log "watcher stopped by user".
- Watcher state persisted across app relaunch **only if** user left `Wake Watcher` on (optional: prompt on launch "Resume watching for quota reset?").
- Menu bar popover exposes the same **Wake Watcher** toggle for quick kill-switch without opening Settings.

### FR-5: Dashboard / popover surfacing
- When Claude 5h window is blocked, show: **"N sessions waiting · resets {countdown}"**.
- **Watcher status chip:** `Watching` (poll active) · `Idle` (feature on, watcher off) · `Off` (feature disabled).
- Actions:
  - **Preview** (dry-run list)
  - **Wake Watcher** toggle (same binding as Settings — primary control surface)
  - **Resume Now** (one-shot, only if quota available; does not require watcher on)
- Show last run summary: resumed / skipped / failed counts + timestamp.
- Link to log file.

### FR-6: Notifications
- Optional notification when wake watch starts: *"Watching for Claude quota reset — N sessions queued"*.
- Optional notification on completion: *"Session Wake: resumed X/Y Claude sessions"*.
- Respect existing `NotificationPreferences` and provider enablement.

### FR-7: CLI extension
```bash
meterbar wake [--provider claude] [--wait] [--dry-run] [--limit N] [--session-id UUID]
```
- JSON output mode for scripting: `--json`
- Exit 0 when quota blocked and not waiting; exit 0 after successful run.

### FR-8: Logging
- Write logs to `~/Library/Logs/MeterBar/session-wake-YYYYMMDD-HHMMSS.log` (or `~/.meterbar/logs/` — pick one, document in Settings).
- Log: quota state, session list, per-session exit code + tail snippet, timing.

### FR-9: Account model compatibility
- Support MeterBar's existing multi-account Claude profiles (`CLAUDE_CONFIG_DIR` per profile).
- v1: wake **only the active/default profile** selected in MeterBar Settings.
- Optionally run `sync-active-account-sessions.sh` equivalent (link account sessions into `~/.claude/projects`) before resume if MeterBar already has this pattern.

---

## Technical Design Notes

### Reference implementation
A working Python driver exists on the author's machines (`~/.claude/scripts/resume-quota-sessions.py`) with:
- `active_claude_account_dir()` from `~/.claude-active-account`
- `discover_claude_targets()` from transcript tails
- `wait_for_client_quota()` polling
- `--session-id`, `--wait-for-quota`, `--dry-run` flags

Port core logic into Swift (`MeterBarShared` for pure discovery; app target for `Process` execution) or bundle script initially with MeterBar invoking it — prefer native Swift long-term.

### Architecture sketch
```
MeterBarShared
  └── BlockedSessionDiscovery (pure: parse jsonl tails)

MeterBar
  ├── SessionWakeScheduler (Timer + quota observation from UsageDataManager)
  ├── SessionWakeRunner (Process spawn, lock file, sequential queue)
  └── SessionWakeStore (UserDefaults: prefs, last run stats)

MeterBarCLI
  └── Wake command (thin wrapper around shared runner or script)
```

### Security / permissions
- App is already un-sandboxed — required to read `~/.claude*` and spawn `claude`.
- No new network endpoints beyond existing usage APIs.
- Do not log OAuth tokens or full transcript content.

---

## Acceptance Criteria

- [ ] **AC-1:** With Claude 5h at 100%, Preview shows blocked session count > 0 matching manual `rg rate_limit` audit.
- [ ] **AC-2:** Resume Now does nothing (clean message) when quota blocked; no CLI invocations fired.
- [ ] **AC-3:** With `--wait` / Wake Watch enabled, MeterBar waits until `resets_at + buffer` before first resume.
- [ ] **AC-4:** After reset, at least one blocked session receives a new transcript entry (user prompt + non-rate-limit assistant response or tool use).
- [ ] **AC-5:** Sessions resume one at a time with configured gap; second session does not start until first process exits.
- [ ] **AC-6:** Concurrent wake attempts are rejected via lock file.
- [ ] **AC-7:** Only the MeterBar-selected Claude account dir is scanned/resumed.
- [ ] **AC-8:** `meterbar wake --dry-run --json` returns structured session list.
- [ ] **AC-9:** Completion notification fires with accurate resumed/failed counts when enabled.
- [ ] **AC-10:** Feature is off by default; no background wake without explicit opt-in.
- [ ] **AC-11:** `Wake Watcher` toggle off stops an in-progress watch within one poll interval; no further `claude -r` invocations fire.
- [ ] **AC-12:** `Wake Watcher` toggle is available in Settings **and** menu bar popover; both stay in sync.
- [ ] **AC-13:** With `Enable Session Wake` off, watcher toggle is disabled and any active watch is cancelled.

---

## Verification Plan

### Manual
1. Exhaust Claude 5h quota with 2+ sessions blocked.
2. Enable Session Wake → Preview → confirm session list.
3. Tap Resume Now while blocked → confirm no-op + user-visible message.
4. Turn **Wake Watcher** on → confirm app logs "waiting until {time}" and status chip shows `Watching`.
5. Turn **Wake Watcher** off mid-wait → confirm polling stops and status returns to `Idle`.
6. After reset (watcher still on) → confirm sessions resume sequentially; check transcript tails.
7. Confirm notification and last-run summary in UI.

### Automated
- Unit tests: `BlockedSessionDiscovery` with fixture `*.jsonl` tails (blocked vs healthy vs subagent paths).
- Unit tests: quota gate logic (blocked / unblocked / wait scheduling math).
- CLI contract test: `meterbar wake --dry-run --json` schema snapshot.

### Regression
- Existing usage fetch, notifications, and multi-account Claude settings unaffected when Session Wake is disabled.

---

## Milestones

### v1.0 (MVP)
- Claude only, Settings + Dashboard card, Wake Watch, CLI `meterbar wake`, logging, notifications.

### v1.1
- Codex `codex exec resume` support.
- Per-session picker (resume subset).

### v2.0
- Scheduled profiles per machine.
- Menu bar compact "watching" indicator.
- Integration with reset credits flow (user-confirmed).

---

## Open Questions

1. Sort order for resume queue: oldest-blocked first vs most-recently-active first?
2. Should MeterBar install/manage a `launchd` helper, or only run while the app is open / via CLI `nohup`?
3. Native Swift vs bundled script for v1 speed-to-ship?
4. Show blocked sessions list in Dashboard even when quota is not exhausted (stale blocked from earlier window)?

---

## References

- MeterBar README: reset countdowns, multi-account Claude, `meterbar usage --json`
- Existing services: `ClaudeCodeLocalService`, `ClaudeCodeCLIUsageService`, `NotificationDecider`, `UsageLimit.resetTime`
- Prototype driver: `resume-quota-sessions.py` / `.sh` (author's `~/.claude/scripts/`)