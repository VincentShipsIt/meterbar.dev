# Architecture - MeterBar

**Purpose:** Document what IS implemented (not what WILL BE).
**Last Updated:** 2026-07-17 (rewritten from a full-repo audit; see `docs/audits/00-repo-map.md`)

---

## Overview

MeterBar is a macOS menu bar app (with a WidgetKit widget and a bundled `meterbar` CLI) that tracks AI coding-assistant quota usage. It reads usage from **local CLI artifacts and provider APIs** — it does not run a backend and does not ask users for provider API keys for the CLI-backed providers.

Providers tracked:

| Provider | `ServiceType` case | Data source |
|---|---|---|
| Claude Code | `.claudeCode` | Unscoped default account: calls the authenticated `https://api.anthropic.com/api/oauth/usage` endpoint with the global `Claude Code-credentials` Keychain OAuth token (primary; on by default via the `ClaudeCodeEnableOAuthFallback` flag). Falls back to shelling out to `claude /usage` and regex-parsing terminal output when no token is available. Any account with an explicit `CLAUDE_CONFIG_DIR`, including the editable default row, uses the CLI so credentials cannot cross-contaminate profiles. |
| OpenAI Codex CLI | `.codexCli` | Reads `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`), calls `https://chatgpt.com/backend-api/wham/usage`; exhausted accounts can consume a banked reset credit through the authenticated reset-credit endpoints after explicit confirmation |
| Cursor | `.cursor` | Reads session JWT from Cursor's `state.vscdb` SQLite, calls `https://cursor.com/api/usage-summary` |
| OpenRouter | `.openRouter` | User-provided API key in Keychain; calls documented `/api/v1/credits` and `/api/v1/key` endpoints |
| Grok | `.grok` | Opt-in. Runs the official Grok Build CLI's ACP stdio agent with its cached login and maps `_x.ai/billing` into the shared weekly quota/credit model; MeterBar checks login-file presence but never reads token contents |
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
- Release bundle ids `dev.meterbar.app` / `dev.meterbar.app.Widget`; Debug uses
  `dev.meterbar.app.debug` / `dev.meterbar.app.debug.Widget` and the app product name `MeterBar Dev` so
  local builds cannot shadow the installed release. Both configurations use app group `group.dev.meterbar.app`.

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

- **UsageDataManager** (`@MainActor`, ObservableObject) — orchestrates refresh across providers, caches to UserDefaults (`cached_usage_metrics`), mirrors to the app group via SharedDataStore, records per-provider refresh outcomes in `ProviderParseHealthStore`, and drives a non-overlapping `Timer` auto-refresh (default 10 min; `RefreshInterval` supports 1/2/5/10/15/30 min + manual). The app forwards system wake events so stale enabled data catches up once without replaying missed ticks.
- **ClaudeCodeCLIUsageService** — fallback source. Resolves the `claude` binary (`CLAUDE_CLI_PATH`, `$PATH`, 7 fallback paths), runs `claude /usage` (12 s timeout, dedicated GCD queue bridged to async), parses output with `ClaudeCodeCLIUsageParser`. `/usage` no longer renders in a headless spawn (it prints a session cost summary), so the parser detects that shape and throws a legible error. Multi-account via `CLAUDE_CONFIG_DIR` env injection.
- **ClaudeCodeLocalService** — OAuth-primary wrapper. For the default account it reads `api.anthropic.com/api/oauth/usage` with the Keychain token (`metrics(from:)` maps windows + extra-usage), falling back to the CLI parser only when no token is available; custom accounts use the CLI. `prefersOAuth`/`isOAuthUsageEnabled` are the pure source-selection helpers.
- **CodexCliLocalService** — Codex auth file + wham/usage endpoint; maps credits/spend to `ExtraUsageStatus` (safety-biased: never false "Off"). It also lists and consumes banked rate-limit resets with an idempotency key, then immediately refreshes usage. The exhausted popover card and `meterbar reset-credit --yes` are the two explicit-confirmation entry points.
- **CursorLocalService** — SQLite token extraction + usage-summary endpoint; assumed 500-request default quota when API omits totals.
- **OpenRouterService** — opt-in API-key provider; maps account credits/spend and optional per-key caps into shared metrics.
- **GrokCLIUsageService** — opt-in CLI provider; resolves `grok`, authenticates the official ACP process with `cached_token`, and maps weekly usage, reset time, prepaid balance, and on-demand credit limits. The process runs with auto-update disabled and discards stderr to avoid account metadata in logs.
- **ClaudeService / OpenAIService** — admin-key usage reports (paginated, 50-page cap) via `ServiceSupport.fetchDecoded`.
- **CostTracker** — JSONL/SQLite log scanning, per-day/model/origin breakdowns, cache at `~/Library/Application Support/MeterBar/cost-summary-v1.json`. API-rate estimates come from the versioned `ModelPricing` table in `MeterBarShared`, which is shared with the CLI.
- **ClaudeFableSessionTracker** — schedules a coalesced, off-main scan after Claude quota refreshes. It reads bounded tails from configured profile JSONL roots, caches unchanged files by modification date and size, persists only profile/session/model/timestamp/lifecycle metadata in the app group, and retains deduplicated history for 30 days. Transcript content, credentials, working directories, and git metadata are never retained.
- **AuthenticationManager + KeychainManager** — the two admin keys, stored in keychain service `dev.meterbar.app`. Reads migrate the older `dev.shipshit.meterbar` (v1.6.x) and `com.agenticindiedev.quotaguard` (v1.0-v1.6) services into the current one, and removals delete all three so a legacy key cannot reappear.
- **SharedDataStore** — app-group JSON file (`cached_usage_metrics.json`), atomic writes on a serial queue, `WidgetCenter.reloadTimelines` after save.
- **ProviderParseHealthStore** — app-group `UserDefaults` records of each provider's last successful parse, last attempt, consecutive failures, and format-mismatch state. Diagnostics and `meterbar doctor` share the same records; successful data warns after 2 hours, while format mismatches or 3 consecutive failures need attention and dim the menu bar item.
- **ProviderVisibilityStore / DockVisibilityStore / ClaudeCodeAccountStore** — UserDefaults-backed preference stores.
- **OAuthTokenExpiry** — JWT/unix-timestamp expiry checks (60 s grace; unparseable ⇒ not-expired by design).
- **ServiceSupport** — shared URLSession config, secret-safe HTTP/URLError mapping, real (non-container) home dir via `getpwuid`.
- **AppLog** — `os.Logger` categories: app, usage, cost, network, storage. This is the only observability; there is no crash reporting or analytics.
- **SoftwareUpdateController** — owns Sparkle 2's standard updater. The General settings pane binds directly to Sparkle's automatic-check preference (default off until consent) and exposes a manual check action. Release builds embed the GitHub Releases appcast URL and an Actions-provided EdDSA public key.
- **SessionWakeController + managed agent** — signed release bundles register `Contents/Helpers/meterbar wake-agent` through `SMAppService.agent`. The launch agent owns the shared wake lock for its lifetime, reads versioned configuration/status through the app group, and keeps the native coordinator alive after the GUI quits. Debug builds without the injected CLI retain the in-process fallback.

## App lifecycle

`@main` SwiftUI `App` with `Settings` scene + `NSApplicationDelegateAdaptor`. The delegate creates a manual `NSStatusItem` (not `MenuBarExtra`) with an `NSPopover` hosting `MenuBarView`; right-click opens a native status menu (Dock toggle / dashboard / quit). `LSUIElement = true`; Dock icon toggled at runtime via activation policy. A 5-minute `Task.sleep` loop checks limits and posts local notifications at 90%/100% with stable identifiers and re-arm-on-drop semantics.

On the first launch, `FirstRunOnboardingStore` auto-opens the menu panel and shows a one-time launch-at-login choice. Enablement remains explicit through `SMAppService`; choosing either option or dismissing the panel persists `HasCompletedFirstRun` so onboarding does not reappear.

## Widget & CLI data contract

The app, widget, and CLI consume the canonical `ServiceType`, `UsageLimit`, and `UsageMetrics` definitions from `Packages/MeterBarShared`. The app-group JSON contract is locked by `CachedMetricsContractTests` and `CachedMetricsReplicaContractTests` so fields and date encoding cannot silently drift across targets.

Dates in the shared JSON use `JSONEncoder`/`JSONDecoder` **default** strategies (seconds since 2001-01-01 reference date). Changing either side's date strategy breaks widget + CLI decode.

The CLI's public `usage --json` and `cost --json` integration surface is separate from that internal
cache format. It emits explicit version 1 DTOs with ISO-8601 dates; the compatibility contract lives
in `docs/cli-json-schema.md`.

---

## CI / release

- `ci.yml` (push/PR to master, macos-26 + Xcode 26.2): the branch-protection-required `build` job waits for tests/coverage and SwiftLint, fails explicitly unless both pass, then compiles and verifies universal app, widget, and CLI artifacts. Branch protection also requires the test, lint, and secret-scan contexts directly.
- `release.yml` (canonical `vMAJOR.MINOR.PATCH` tag): preflights Developer ID, notarization, and Sparkle EdDSA credentials; builds universal arm64+x86_64 app/widget/CLI artifacts; checks tag/app/CLI version agreement; signs, notarizes, and staples nested code; generates and validates an EdDSA-signed Sparkle appcast; publishes all assets to GitHub Releases; then calls `update-homebrew.yml`.
- `secret-scan.yml`: gitleaks (pinned + checksum-verified) over full history.

## Known architectural risks

Tracked in `docs/audits/00-repo-map.md` §6. Headlines: reverse-engineered provider interfaces (R1), non-notarized distribution (R2), hardcoded pricing (R5), three build systems (R6), and god view files (R8). The shared model drift and unverifiable release-artifact findings have since been remediated.
