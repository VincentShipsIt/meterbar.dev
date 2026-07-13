# Architecture - MeterBar

**Purpose:** Document what IS implemented (not what WILL BE).
**Last Updated:** 2026-07-09 (rewritten from a full-repo audit; see `docs/audits/00-repo-map.md`)

---

## Overview

MeterBar is a macOS menu bar app (with a WidgetKit widget and a bundled `meterbar` CLI) that tracks AI coding-assistant quota usage. It reads usage from **local CLI artifacts and provider APIs** — it does not run a backend and does not ask users for provider API keys for the CLI-backed providers.

Providers tracked:

| Provider | `ServiceType` case | Data source |
|---|---|---|
| Claude Code | `.claudeCode` | Shells out to `claude /usage`, regex-parses terminal output. Legacy OAuth fallback (keychain item `Claude Code-credentials`) behind the `ClaudeCodeEnableOAuthFallback` UserDefaults flag |
| OpenAI Codex CLI | `.codexCli` | Reads `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`), calls `https://chatgpt.com/backend-api/wham/usage` |
| Cursor | `.cursor` | Reads session JWT from Cursor's `state.vscdb` SQLite, calls `https://cursor.com/api/usage-summary` |
| OpenRouter | `.openRouter` | User-provided API key in Keychain; calls documented `/api/v1/credits` and `/api/v1/key` endpoints |
| Claude (admin) | `.claude` | Anthropic Admin API key (user-provided, stored in our keychain), `/v1/organizations/usage_report/messages` |
| OpenAI (admin) | `.openai` | OpenAI Admin API key (user-provided, stored in our keychain), `/v1/organization/usage/completions` |

Plus local **cost estimation**: `CostTracker` scans `~/.claude*/projects/**/*.jsonl` and Codex's `$CODEX_HOME/archived_sessions` + `$CODEX_HOME/logs_2.sqlite` (`CODEX_HOME` defaults to `~/.codex`), priced from a hardcoded per-model table.

---

## Targets / build systems

Three build systems coexist (see `docs/audits/00-repo-map.md` §2):

1. **MeterBar.xcodeproj** — app target `MeterBar` + widget target `MeterBarWidgetExtension`. objectVersion 77 with file-system-synchronized groups (new files under `MeterBar/`/`MeterBarWidget/` join their target automatically).
2. **Root `Package.swift`** — SwiftPM library `MeterBar` + test target `MeterBarTests`. Exists so `swift test` works without Xcode. Excludes the app entry point, Info.plist, entitlements, and assets.
3. **`MeterBarCLI/Package.swift`** — separate SwiftPM package building the `meterbar` executable (dependency: swift-argument-parser). Copied into `MeterBar.app/Contents/Helpers/` by the release workflow.

Key settings (from `MeterBar.xcodeproj/project.pbxproj`):
- `MACOSX_DEPLOYMENT_TARGET = 26.0` (Liquid Glass APIs), `SWIFT_VERSION = 5.0` (Swift 5 language mode)
- App: `ENABLE_APP_SANDBOX = NO` (the app must read other tools' credential/log files and spawn the `claude` binary). Widget: sandboxed. Hardened runtime on for both.
- Bundle ids `dev.meterbar.app` / `dev.meterbar.app.Widget`; app group `group.dev.meterbar.app`.

---

## Layout

```
meterbar/
├── MeterBar/                 # App target sources
│   ├── App/MeterBarApp.swift # @main + AppDelegate (NSStatusItem, popover, notifications)
│   ├── Models/               # ServiceType, UsageMetrics, UsageLimit(+pace), TokenCost,
│   │                         # RefreshInterval, ClaudeCodeAccount(+store), UsageFormatting
│   ├── Services/             # 16 services, all singletons (see below)
│   ├── Views/                # MenuBarView, SettingsView, UsageDashboardView,
│   │                         # MeterBarTheme, RefreshingIcon
│   └── Resources/, Assets.xcassets, Info.plist, MeterBar.entitlements
├── MeterBarWidget/           # Widget extension (UsageWidget kind "UsageWidget")
├── MeterBarCLI/              # `meterbar` CLI package
├── MeterBarTests/            # XCTest suite (runs via `swift test`)
├── scripts/                  # Bun/Playwright asset generators, check-coverage.sh
├── .github/workflows/        # ci.yml, release.yml, update-homebrew.yml, secret-scan.yml
└── docs/audits/              # Audit reports
```

---

## Services (all `.shared` singletons)

- **UsageDataManager** (`@MainActor`, ObservableObject) — orchestrates refresh across providers, caches to UserDefaults (`cached_usage_metrics`), mirrors to the app group via SharedDataStore, drives a `Timer` auto-refresh (default 15 min; `RefreshInterval` supports 1/2/5/15/30 min + manual).
- **ClaudeCodeCLIUsageService** — resolves the `claude` binary (`CLAUDE_CLI_PATH`, `$PATH`, 7 fallback paths), runs `claude /usage` (12 s timeout, dedicated GCD queue bridged to async), parses output with `ClaudeCodeCLIUsageParser`. Multi-account via `CLAUDE_CONFIG_DIR` env injection.
- **ClaudeCodeLocalService** — CLI-first wrapper; legacy OAuth fallback + best-effort "extra usage" probe against `api.anthropic.com/api/oauth/usage`.
- **CodexCliLocalService** — Codex auth file + wham/usage endpoint; maps credits/spend to `ExtraUsageStatus` (safety-biased: never false "Off").
- **CursorLocalService** — SQLite token extraction + usage-summary endpoint; assumed 500-request default quota when API omits totals.
- **OpenRouterService** — opt-in API-key provider; maps account credits/spend and optional per-key caps into shared metrics.
- **ClaudeService / OpenAIService** — admin-key usage reports (paginated, 50-page cap) via `ServiceSupport.fetchDecoded`.
- **CostTracker** — JSONL/SQLite log scanning, per-day/model/origin breakdowns, cache at `~/Library/Application Support/MeterBar/cost-summary-v1.json`. API-rate estimates come from the versioned `ModelPricing` table in `MeterBarShared`, which is shared with the CLI.
- **AuthenticationManager + KeychainManager** — the two admin keys, stored in keychain service `dev.meterbar.app`. Reads migrate the older `dev.shipshit.meterbar` (v1.6.x) and `com.agenticindiedev.quotaguard` (v1.0-v1.6) services into the current one, and removals delete all three so a legacy key cannot reappear.
- **SharedDataStore** — app-group JSON file (`cached_usage_metrics.json`), atomic writes on a serial queue, `WidgetCenter.reloadTimelines` after save.
- **ProviderVisibilityStore / DockVisibilityStore / ClaudeCodeAccountStore** — UserDefaults-backed preference stores.
- **OAuthTokenExpiry** — JWT/unix-timestamp expiry checks (60 s grace; unparseable ⇒ not-expired by design).
- **ServiceSupport** — shared URLSession config, secret-safe HTTP/URLError mapping, real (non-container) home dir via `getpwuid`.
- **AppLog** — `os.Logger` categories: app, usage, cost, network, storage. This is the only observability; there is no crash reporting or analytics.

## App lifecycle

`@main` SwiftUI `App` with `Settings` scene + `NSApplicationDelegateAdaptor`. The delegate creates a manual `NSStatusItem` (not `MenuBarExtra`) with an `NSPopover` hosting `MenuBarView`; right-click opens a native status menu (Dock toggle / dashboard / quit). `LSUIElement = true`; Dock icon toggled at runtime via activation policy. A 5-minute `Task.sleep` loop checks limits and posts local notifications at 90%/100% with stable identifiers and re-arm-on-drop semantics.

## Widget & CLI data contract

The app, widget, and CLI consume the canonical `ServiceType`, `UsageLimit`, and `UsageMetrics` definitions from `Packages/MeterBarShared`. The app-group JSON contract is locked by `CachedMetricsContractTests` and `CachedMetricsReplicaContractTests` so fields and date encoding cannot silently drift across targets.

Dates in the shared JSON use `JSONEncoder`/`JSONDecoder` **default** strategies (seconds since 2001-01-01 reference date). Changing either side's date strategy breaks widget + CLI decode.

---

## CI / release

- `ci.yml` (push/PR to master, macos-26 + Xcode 26.2): the branch-protection-required `build` job waits for tests/coverage and SwiftLint, fails explicitly unless both pass, then compiles and verifies universal app, widget, and CLI artifacts. Branch protection also requires the test, lint, and secret-scan contexts directly.
- `release.yml` (canonical `vMAJOR.MINOR.PATCH` tag): builds universal arm64+x86_64 app/widget/CLI artifacts, checks tag/app/CLI version agreement, signs nested code inside-out with an ad-hoc hardened-runtime signature, verifies source entitlements and bundle integrity, zips via `ditto`, publishes GitHub Release, then calls `update-homebrew.yml`. Developer ID signing, authorized provisioning, and notarization remain pending credentials.
- `secret-scan.yml`: gitleaks (pinned + checksum-verified) over full history.

## Known architectural risks

Tracked in `docs/audits/00-repo-map.md` §6. Headlines: reverse-engineered provider interfaces (R1), non-notarized distribution (R2), hardcoded pricing (R5), three build systems (R6), and god view files (R8). The shared model drift and unverifiable release-artifact findings have since been remediated.
