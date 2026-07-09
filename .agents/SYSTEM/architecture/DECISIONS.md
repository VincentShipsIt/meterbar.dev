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
- Shared UserDefaults container: `group.dev.shipshit.meterbar`
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

<!-- Add new ADRs above this line -->
