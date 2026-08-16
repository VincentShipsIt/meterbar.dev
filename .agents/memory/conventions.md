---
last_verified: 2026-08-16
status: active
---

# Conventions

## Agent docs

- Source of truth: `.agents/memory/MEMORY.md`, then the topic file for the task.
- Root markdown is only `AGENTS.md`, `CLAUDE.md`, `CODEX.md`, `README.md`. Everything else goes under `.agents/` or `docs/`.
- Durable decisions go in [decisions.md](decisions.md). Delivery state goes on the GitHub issue or PR.
- Session logs: `.agents/sessions/YYYY-MM-DD.md`, lowercase, gitignored. Never commit. Never `git add -f`.
- Do not recreate `.agents/SYSTEM/` or `.agents/docs/`.

## Swift

Tooling is `.swiftlint.yml` + `.swiftformat`.

- Follow 3+ nearby implementations before adding a pattern.
- No `print(...)` in app/widget — `AppLog`. SwiftLint `no_print_statements`.
- No force-unwraps. Prefer `guard let` or a documented sentinel (`ClaudeCodeAccount.defaultID`).
- Never log secrets or raw API bodies. `privacy: .public` only on proven-safe values.
- 4-space indent, 120-col warning, 200-col error.
- Swift 5 language mode. Do not introduce Swift 6 strict-concurrency-only constructs without migrating the singletons.
- Types PascalCase; file named after the primary type.
- Services: `static let shared`. UI: `ObservableObject` + `@Published`, mutations on the main actor.
- External JSON: explicit `CodingKeys` for snake_case; tolerate missing fields with optionals.

## Data contract

Canonical types live in `Packages/MeterBarShared`. Changing `UsageMetrics` / `UsageLimit` / `ServiceType` serialization requires updating `CachedMetricsContractTests`. Do not change the shared-cache date strategy.

CLI human output may stay English. `--json` keys, enum tokens, and exit codes are never localized. See `docs/localization.md`.

## Errors

- Map provider failures to `ServiceError` and update `@Published lastError` / `hasAccess` on the main actor.
- Keep cached metrics on fetch failure. Do not blank the UI.
- Unparseable tokens are not treated as expired — [decisions.md](decisions.md).

## Tests

- `MeterBarTests/` via `swift test` (full Xcode; CLT has no XCTest).
- TDD for new features. Parsers/decoders ship with fixtures.
- Network tests `XCTSkip` without credentials (`APIIntegrationTests`).
- Pure logic must be testable offline.

## Git

```text
type(scope): description
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`.  
Branches: `feature/…`, `fix/…`, `chore/…`, `docs/…`.  
No `Co-Authored-By` trailer.
