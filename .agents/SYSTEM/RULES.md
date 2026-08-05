# Coding Rules - MeterBar

**Purpose:** Coding standards and patterns for this project.
**Last Updated:** 2026-07-02 (rewritten — the previous version was a TypeScript template that never
applied to this pure-Swift repo)

---

## General Principles

1. **Follow existing patterns** — search for 3+ similar implementations before writing new code
2. **Quality over speed** — think through implementations before coding
3. **No `print(...)`** — use `AppLog` (`os.Logger`); enforced by the SwiftLint custom rule `no_print_statements`
4. **No force-unwraps** — `force_unwrapping` is an opt-in SwiftLint rule here; prefer `guard let` or documented sentinels (see `ClaudeCodeAccount.defaultID`)
5. **Never log secrets or raw API response bodies** — use `privacy: .public` only on values proven non-sensitive

## Swift conventions (enforced by tooling)

The single source of truth is `.swiftlint.yml` + `.swiftformat` at the repo root. Highlights:

- 4-space indent, max line width 120 (SwiftLint error at 200)
- Swift 5 language mode (`SWIFT_VERSION = 5.0` in the Xcode project, `.swiftLanguageMode(.v5)` in `Package.swift`) — don't introduce Swift 6 strict-concurrency-only constructs without migrating the singletons
- Types: PascalCase; files named after their primary type (`CostTracker.swift`)
- Services are singletons (`static let shared`); new services should follow that pattern until the DI refactor happens
- UI state via `ObservableObject` + `@Published`; UI mutations on the main actor
- Decode external JSON with explicit `CodingKeys` for snake_case fields; tolerate absent fields with optionals rather than failing decode

## Data-contract rules (important)

- The app-group JSON (`cached_usage_metrics.json`) is decoded by **three** codebases (app, widget, CLI) with duplicated struct definitions. Any change to `UsageMetrics`/`UsageLimit`/`ServiceType` serialization must be mirrored in `MeterBarWidget/UsageWidget.swift` and `MeterBarCLI/Sources/MeterBarCLI.swift`, and the contract tests in `MeterBarTests/CachedMetricsContractTests.swift` must be updated.
- Do NOT change the `JSONEncoder`/`JSONDecoder` date strategy for the shared cache — all three sides rely on the default (seconds since reference date).

## Error handling

- Provider services map errors to `ServiceError` (`notAuthenticated`, `invalidURL`, `apiError(String)`, `parsingError`) and update their `@Published lastError`/`hasAccess` on the main actor
- Fetch failures degrade gracefully: keep cached metrics rather than blanking the UI (see `UsageDataManager.refreshAll`)
- Availability-biased token checks: a token we cannot introspect is treated as valid and the server 401 is the source of truth (`OAuthTokenExpiry`)

## Testing

- Tests live in `MeterBarTests/` and run via `swift test` (requires full Xcode; Command Line Tools lack the XCTest module)
- TDD for new features; new parsing/decode logic must come with fixture tests
- Network-touching tests must gate on credentials with `XCTSkip` (see `APIIntegrationTests`)
- Pure logic (parsers, formatters, models) must be testable without the network

## Git

### Commit Messages

```
type(scope): description
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

### Branch Naming

- `feature/description`, `fix/description`, `chore/description`

## Documentation

- Keep `README.md` claims true to the code (the sandbox/minimum-OS claims drifted once already)
- Architectural decisions go in `SYSTEM/architecture/DECISIONS.md`
- Session logs: `.agents/sessions/YYYY-MM-DD.md`, one file per day — gitignored,
  local-only. This repo is public; never commit them, never `git add -f` one.

---

**Remember:** When in doubt, check existing code for patterns.
