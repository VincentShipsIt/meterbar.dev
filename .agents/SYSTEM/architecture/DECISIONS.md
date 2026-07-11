# Architectural Decision Records (ADRs)

**Purpose:** Document significant architectural decisions.
**Last Updated:** 2025-01-27

---

## How to Use

When making a significant architectural decision, add an entry below using this format:

```markdown
## ADR-XXX: Title

**Date:** YYYY-MM-DD
**Status:** Proposed / Accepted / Deprecated / Superseded

### Context
What is the issue that we're seeing that is motivating this decision?

### Decision
What is the change that we're proposing and/or doing?

### Consequences
What becomes easier or more difficult because of this change?

### Alternatives Considered
What other options were considered?
```

---

## Decisions

### ADR-001: Use .agents/ Folder for AI Documentation

**Date:** 2025-12-29
**Status:** Accepted

#### Context
Need a structured way to organize AI agent documentation, session tracking, and project rules.

#### Decision
Use a `.agents/` folder at the project root with standardized subdirectories:
- `SYSTEM/` for rules and architecture
- `TASKS/` for task tracking
- `SESSIONS/` for daily session documentation
- `SOP/` for standard procedures

#### Consequences
- **Easier:** AI agents have consistent documentation structure
- **Easier:** Session continuity across conversations
- **More difficult:** Initial setup overhead

#### Alternatives Considered
- Inline documentation in code (rejected: not AI-friendly)
- Single README (rejected: doesn't scale)
- Wiki (rejected: separate from codebase)

---

### ADR-002: Singleton Pattern for Managers and Services

**Date:** 2025-12-29
**Status:** Accepted

#### Context
Need shared state across app (authentication, usage data, keychain access). SwiftUI views need access to same instances.

#### Decision
Use singleton pattern for:
- `KeychainManager.shared`
- `AuthenticationManager.shared`
- `UsageDataManager.shared`
- Service classes (ClaudeService, OpenAIService, CursorService)

#### Consequences
- **Easier:** Single source of truth
- **Easier:** Accessible from anywhere in app
- **Easier:** No dependency injection complexity
- **More difficult:** Harder to test (can't inject mocks)
- **More difficult:** Global state can be problematic

#### Alternatives Considered
- Dependency injection (rejected: overkill for simple app)
- Environment objects (rejected: still global, more complex)
- Static methods (rejected: can't use @Published properties)

---

### ADR-003: ObservableObject for Reactive UI

**Date:** 2025-12-29
**Status:** Accepted

#### Context
SwiftUI views need to update automatically when data changes. Usage metrics update asynchronously.

#### Decision
Use `ObservableObject` protocol with `@Published` properties:
- `AuthenticationManager`: Published auth state
- `UsageDataManager`: Published metrics and loading state

#### Consequences
- **Easier:** Automatic UI updates when data changes
- **Easier:** SwiftUI integration (no manual updates)
- **Easier:** Reactive programming model
- **More difficult:** Must be @MainActor for UI updates
- **More difficult:** Can cause unnecessary re-renders

#### Alternatives Considered
- Manual state updates (rejected: error-prone, verbose)
- Combine publishers (rejected: ObservableObject is simpler)
- @State in views (rejected: can't share across views)

---

### ADR-004: macOS Keychain for Credential Storage

**Date:** 2025-12-29
**Status:** Accepted

#### Context
Need secure storage for API keys and session keys. Plaintext storage is insecure.

#### Decision
Use macOS Keychain Services API via `KeychainManager`:
- All credentials stored in Keychain
- No credentials in UserDefaults or code
- Encrypted by OS

#### Consequences
- **Easier:** Secure by default (OS-level encryption)
- **Easier:** No manual encryption needed
- **Easier:** Standard macOS security model
- **More difficult:** Keychain access requires entitlements
- **More difficult:** Can't easily export/import credentials

#### Alternatives Considered
- UserDefaults (rejected: not secure)
- Custom encryption (rejected: reinventing the wheel)
- File-based storage (rejected: security risk)

---

### ADR-005: App Groups for Widget Data Sharing

**Date:** 2025-12-29
**Status:** Accepted

#### Context
Widget extension needs access to usage metrics from main app. Extensions can't directly access app's UserDefaults.

#### Decision
Use App Groups capability:
- Shared UserDefaults container: `group.dev.meterbar.app`
- `SharedDataStore` manages shared data
- Both targets have same App Group identifier

#### Consequences
- **Easier:** Secure data sharing between app and widget
- **Easier:** No network requests needed
- **Easier:** Fast data access
- **More difficult:** Must configure in Xcode (entitlements)
- **More difficult:** Both targets must have capability enabled

#### Alternatives Considered
- Network requests from widget (rejected: slow, requires network)
- File-based sharing (rejected: less secure, more complex)
- No sharing (rejected: widget needs data)

---

### ADR-006: WidgetKit for Notification Center Widgets

**Date:** 2025-12-29
**Status:** Accepted

#### Context
Want to display usage metrics in macOS Notification Center. Need native widget support.

#### Decision
Use WidgetKit framework:
- Separate widget extension target
- Timeline provider with 15-minute refresh
- Three widget sizes (Small, Medium, Large)

#### Consequences
- **Easier:** Native macOS widget support
- **Easier:** System-managed refresh
- **Easier:** User can add to Notification Center
- **More difficult:** Separate target to maintain
- **More difficult:** Limited interactivity (read-only)
- **More difficult:** WidgetKit Simulator bugs (known issue)

#### Alternatives Considered
- Menu bar only (rejected: less visible)
- Dashboard widget (rejected: deprecated)
- Third-party widget framework (rejected: not native)

---

### ADR-007: SwiftUI for UI

**Date:** 2025-12-29
**Status:** Accepted

#### Context
Modern SwiftUI is declarative and easier to maintain than AppKit. Menu bar apps can use SwiftUI.

#### Decision
Use SwiftUI for all UI:
- Settings window
- Menu bar popover
- Widget views

#### Consequences
- **Easier:** Declarative UI (less code)
- **Easier:** Automatic updates with @Published
- **Easier:** Modern Swift patterns
- **More difficult:** Some AppKit features not available
- **More difficult:** Menu bar integration requires NSStatusItem

#### Alternatives Considered
- AppKit (rejected: more verbose, imperative)
- Hybrid (rejected: adds complexity)
- Web-based (rejected: not native)

---

### ADR-008: Async/Await for API Calls

**Date:** 2025-12-29
**Status:** Accepted

#### Context
API calls are asynchronous. Need modern Swift concurrency.

#### Decision
Use async/await for all API calls:
- Service methods are async
- UsageDataManager uses async/await
- @MainActor for UI updates

#### Consequences
- **Easier:** Modern Swift concurrency
- **Easier:** No callback hell
- **Easier:** Error handling with try/catch
- **More difficult:** Must be @MainActor for UI updates
- **More difficult:** Requires Swift 5.5+

#### Alternatives Considered
- Completion handlers (rejected: callback hell)
- Combine (rejected: async/await is simpler)
- ReactiveSwift (rejected: external dependency)

---

### ADR-009: Caching with UserDefaults

**Date:** 2025-12-29
**Status:** Accepted

#### Context
API calls may be slow. Want to show cached data immediately while fetching fresh data.

#### Decision
Cache usage metrics in UserDefaults:
- Save after each fetch
- Load on app launch
- Show cached data while refreshing

#### Consequences
- **Easier:** Fast initial display
- **Easier:** Works offline
- **Easier:** Simple implementation
- **More difficult:** Stale data if refresh fails
- **More difficult:** UserDefaults size limits

#### Alternatives Considered
- No caching (rejected: slow initial load)
- Core Data (rejected: overkill)
- File-based cache (rejected: more complex)

---

### ADR-010: Session Wake watcher lifetime and active-child cancellation (v1)

**Date:** 2026-07-10
**Status:** Accepted
**Issue:** #96 (cancellable watcher state machine); refined by #112 (single
ON/OFF toggle wired to a live continuous watcher)

#### Context

Session Wake needs a long-lived component that waits for a quota reset and then
resumes blocked Claude Code sessions. #96 requires an explicit, tested decision
for the watcher's lifetime (app-running-only vs. a managed background helper)
covering sleep/wake, app quit, crash, and relaunch — plus what happens to a
child `claude` session that is mid-run when the user turns the watcher off.

#### Decision

**Lifetime: app-running-only. No managed helper (no launchd/XPC daemon) in v1.**

Each watch *pass* is a single cancellable structured `Task` owned by the
`WakeCoordinator` actor, driving scan → (wait | quota-unknown) → run → re-check.
Since #112 the watcher is *continuous*: `SessionWakeController` runs a
`WakeCoordinator` pass, and when a pass settles it re-scans after a fixed
interval so the watcher keeps watching for the *next* limit hit rather than
stopping after one resume. The whole thing is tied to the app process lifetime:

- **Quit / crash:** the watch task dies with the app. Nothing resumes while
  MeterBar is not running. This is intentional — a background daemon that
  resumes agent sessions unattended is a larger security/permissions surface
  than v1 accepts (permission bypass, private logging, and the mutual-exclusion
  protocol are #97 concerns). The legacy launchd watcher stays paused; it is not
  replaced by a new daemon here.
- **Relaunch:** the coordinator starts in `.off`. Re-arming is driven by the
  persisted single ON/OFF toggle (#98/#112 settings store): if the toggle was
  left on, the controller reconciles and re-arms on launch. #95's replay ledger
  guarantees a block already handled before the quit is not resumed again after
  relaunch.
- **Sleep / wake:** a known reset waits in a single bounded sleep until that
  instant (an unknown reset polls in interval-sized steps), and **every**
  launch is gated on a *fresh* quota fetch. A sleep that overshoots after the
  machine wakes therefore costs only latency, never correctness; the watcher
  never launches on a stale timer — it re-proves quota on wake.

**Active-child cancellation: cooperative-cancel, preserve, never record.**

When the watcher is turned off (toggle off, wake account removed, or app
teardown) while a child session is running:

- The structured task is cancelled; the runner (#97) receives cooperative
  cancellation via its task-cancellation handler, terminates the child within a
  bounded grace, and returns `WakeRunOutcome.cancelled`.
- A `.cancelled` outcome is **not** recorded: only `.succeeded` writes the
  candidate's block fingerprint to the replay ledger, so the interrupted block
  stays retryable on a later armed run. The in-flight candidate has already been
  removed from the local queue for the attempt, but because nothing was recorded
  a subsequent re-scan rediscovers it.
- `stop()` requests cancellation and returns; the run loop — not `stop()` —
  owns the final transition, and the coordinator only enters `.off` after the
  task fully unwinds (observable via `waitUntilFinished()`), so "watcher off"
  is deterministic rather than best-effort.

#### Consequences

- **Easier:** no signing/entitlement surface for a helper; no daemon lifecycle
  to manage; cancellation is deterministic and unit-testable with fakes.
- **Easier:** fail-closed by construction — missing/stale/ambiguous quota and a
  passed reset all launch nothing.
- **More difficult:** no overnight resume when the Mac is fully asleep or the
  app is quit. Documented as a v1 limitation; a managed helper is a possible
  v2 follow-up.
- **More difficult:** interrupting a child mid-turn may leave that session's
  work partially done; it is retried from its last transcript state, not from a
  checkpoint.

#### Alternatives Considered

- **launchd/XPC managed helper (rejected for v1):** enables resume while the app
  is closed, but multiplies the signing, permission-bypass, and private-logging
  surface the epic defers to later issues; the legacy launchd watcher is being
  retired, not re-created.
- **Let the active child finish on watcher-off (rejected):** makes "off" mean
  "off after the current session," which is surprising for a kill switch and
  leaves a subprocess running unbounded after the user opted out.
- **Force-kill without preserving the candidate (rejected):** would either drop
  the work or, if recorded as handled, silently skip it on the next run.

---

<!-- Add new ADRs above this line -->
