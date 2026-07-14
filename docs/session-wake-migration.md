# Session Wake — Legacy Watcher Migration Checklist

Session Wake is now implemented **natively inside MeterBar** (epic #94, issues
#95–#99). The old Python/launchd watcher is reference material only — MeterBar
does not bundle, invoke, or fall back to it at runtime.

This checklist removes the legacy watcher **only after** the native, signed
replacement is verified. Do not delete anything until every box in
"Verify the native replacement" passes.

> Order matters: verify native → stop legacy → delete legacy. Removing the
> legacy job before the native path is proven risks leaving no auto-resume at
> all.

## 1. Verify the native replacement

- [ ] You are on a **signed + notarized + stapled** MeterBar release (not a
      debug build). Hardened runtime can change process-spawn behavior, so the
      native runner must be exercised in the real artifact.
      - Release CI does this automatically: `scripts/sign-and-verify-release.sh`
        and the release workflow both run
        `meterbar wake --dry-run --json` against the signed/stapled bundle and
        assert the versioned response.
- [ ] `meterbar wake --dry-run --json` returns a `schemaVersion: 1` response and
      lists the sessions you expect (exit code `0`).
- [ ] MeterBar → Settings → **Automation** shows the correct wake account and a
      non-error status.
- [ ] A real overnight run resumed at least one blocked session (check the
      structured logs under
      `~/Library/Application Support/MeterBar/session-wake/logs/`).

## 2. Detect the legacy watcher

MeterBar refuses to start native automation while a legacy watcher still holds
the shared lock, and `meterbar wake` reports it as a validation failure with
guidance. To find it manually:

- [ ] List loaded launchd jobs:
      ```sh
      launchctl list | grep -i -E 'wake|resume|claude'
      ```
- [ ] Look for legacy plists (names vary by install):
      ```sh
      ls -1 ~/Library/LaunchAgents | grep -i -E 'wake|resume|claude'
      ```
- [ ] Look for the legacy driver scripts (reference prototype):
      ```sh
      ls -1 ~/.claude/scripts 2>/dev/null | grep -i -E 'resume|wake|sync-active-account-sessions'
      ```

## 3. Stop the legacy watcher

For each legacy launchd label found above:

- [ ] Unload / boot it out:
      ```sh
      launchctl bootout gui/$(id -u)/<LABEL> 2>/dev/null || launchctl unload ~/Library/LaunchAgents/<LABEL>.plist
      ```
- [ ] Confirm it is gone from `launchctl list`.
- [ ] Confirm no legacy watcher process remains:
      ```sh
      pgrep -fl -E 'resume-quota-sessions|wake-watcher' || echo "no legacy watcher running"
      ```

## 4. Delete the legacy files

Only after steps 1–3 pass:

- [ ] Remove the legacy launchd plists:
      ```sh
      rm -f ~/Library/LaunchAgents/<LABEL>.plist
      ```
- [ ] Remove the legacy driver scripts (e.g. `resume-quota-sessions.py`,
      `resume-quota-sessions.sh`, `sync-active-account-sessions.sh`).
- [ ] Remove any legacy lock file (native Session Wake uses its own lock under
      `~/Library/Application Support/MeterBar/session-wake/wake.lock`):
      ```sh
      rm -f ~/.claude/wake-watcher.lock ~/.meterbar/session-wake.lock
      ```

## 5. Confirm

- [ ] `meterbar wake --dry-run --json` still succeeds.
- [ ] Settings → Automation still shows the wake account and arms cleanly.
- [ ] No `launchctl list` entry and no legacy process reappears after a reboot.

---

### Notes

- **`sync-active-account-sessions.sh` is not ported.** Native discovery scans
  the selected account directory directly; there is no session-sync step.
- **Codex is not covered by v1.** Its subagent filtering and CLI-compatibility
  preflight are deferred to a separate follow-up issue.
- **v1.8+ watcher lifetime is managed.** Enabling Session Wake registers the
  signed `meterbar wake-agent` launch agent bundled inside MeterBar.app. It
  survives GUI quit and subsequent logins; turning the Session Wake switch off
  writes the kill-switch first and then unregisters the agent.
