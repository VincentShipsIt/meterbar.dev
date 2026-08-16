---
last_verified: 2026-08-16
status: active
---

# Architecture

What is implemented. Not a roadmap.

## Surfaces

- **Menu bar app** — `@main` SwiftUI `App` + `NSApplicationDelegateAdaptor`. Manual `NSStatusItem` + `NSPopover` (`MenuBarView`), not `MenuBarExtra`. Right-click native menu. `LSUIElement = true`; Dock icon via `DockVisibilityStore`.
- **Dashboard window** — `UsageDashboardView` and split section files under `MeterBar/Views/`.
- **Settings** — `SettingsView` + `MeterBar/Views/Settings/*`.
- **Widgets** — `UsageWidget` (small/medium/large) and `BurnDownWidget` (small/medium). Both read `WidgetPreferences`. Burn-down uses `WidgetBurnDownPlanner` on `UsageLimit.pace()`.
- **CLI** — `meterbar` in `MeterBar.app/Contents/Helpers/`. Public JSON is versioned in `docs/cli-json-schema.md`.

First launch: `FirstRunOnboardingStore` offers launch-at-login once via `SMAppService`.

## Layout

```text
MeterBar/                 app (App, Models, Services, SessionWake, Views, Resources)
MeterBarWidget/           Usage + Burn Down widgets
MeterBarCLI/              meterbar SwiftPM package
MeterBarTests/            XCTest via root Package.swift
Packages/MeterBarShared/  canonical models, pricing, widget planners, metrics codec
scripts/                  coverage, screenshot, icon generators
.github/workflows/        ci.yml, release.yml, update-homebrew.yml, secret-scan.yml
.agents/memory/           agent source of truth
docs/                     user/maintainer contracts
```

## Build systems

1. `MeterBar.xcodeproj` — app + widget. File-system-synchronized groups. `MACOSX_DEPLOYMENT_TARGET = 26.0`, Swift 5 language mode.
2. Root `Package.swift` — library + `MeterBarTests` so `swift test` works.
3. `MeterBarCLI/Package.swift` — `meterbar` executable (swift-argument-parser). Release copies it into the app bundle.

## Shared data contract

App, widget, and CLI decode `ServiceType` / `UsageLimit` / `UsageMetrics` from `Packages/MeterBarShared`. App-group file `cached_usage_metrics.json` via `SharedDataStore` / `SharedMetricsStore`. Date encoding is the **default** `JSONEncoder` strategy (seconds since reference date). Do not change it. Locked by `CachedMetricsContractTests` and `CachedMetricsReplicaContractTests`.

`UsageMetrics.modelLimitLabel` is additive optional. Older payloads decode as `nil`.

CLI `--json` is a separate version-1 DTO with ISO-8601 dates (`docs/cli-json-schema.md`).

## Orchestration

- `UsageDataManager` (`@MainActor`, `ObservableObject`) — provider refresh, per-account isolation for Claude/Codex/Grok, UserDefaults cache, app-group mirror, `ProviderParseHealthStore`, non-overlapping timer (default 10 min; Adaptive 1–30 min; wake catch-up). Cross-process lock shared with `meterbar refresh`.
- Services are `.shared` singletons. New services follow that until a DI refactor (not planned).
- Cost: `CostTracker` + provider scanners. Cache `~/Library/Application Support/MeterBar/cost-summary-v2.json`. Pricing from `MeterBarShared.ModelPricing`.
- Session Wake: `SessionWakeController` + signed `meterbar wake-agent` via `SMAppService.agent`. Debug without the injected CLI uses the in-process fallback.
- Quota events: `QuotaEventService` + coordinator. Off by default. Contract: `docs/quota-event-webhooks.md`.
- Updates: `SoftwareUpdateController` (Sparkle 2). Automatic checks default off until consent.

## Observability

`AppLog` (`os.Logger`) categories: app, usage, cost, network, storage. No crash reporting. No analytics.

## Risks that are still true

- **R1** unofficial provider APIs — see [providers.md](providers.md)
- **R5** hardcoded `ModelPricing` and Cursor’s 500-request default when the API omits totals
- **R6** three build systems
- **R8** remaining 1k-line files: `UsageDataManager`, `CodexCostScanner`, `WidgetSettingsView`, `ProviderSettingsView`

R2 (unsigned distribution) and R4 (forked models) are **done**.
