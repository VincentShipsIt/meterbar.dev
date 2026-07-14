# 00 — Repo Map: MeterBar

**Audit date:** 2026-07-02
**Scope:** Full repository (201 tracked files, ~10,800 lines of Swift across app + widget + CLI + tests)
**Method:** Every claim below was verified by reading the actual file; paths are cited inline. Nothing was inferred from filenames alone. No code was changed.

---

## 1. System overview

MeterBar (working title in older docs: "Quota Guard") is a **single macOS menu bar app** — not a monorepo of services. There is no backend, no database server, no queue, no web app. Everything runs on the user's Mac.

What it does (verified in code, not just README):

- Shows AI coding-assistant quota usage in the macOS menu bar and in a WidgetKit widget: Claude Code, OpenAI Codex CLI, Cursor, plus optional Anthropic/OpenAI **admin-API** org usage (`MeterBar/Services/UsageDataManager.swift:43-126`).
- Reads credentials/usage **from local CLI artifacts** rather than asking for API keys:
  - Claude Code: shells out to `claude /usage` and regex-parses the terminal output (`MeterBar/Services/ClaudeCodeCLIUsageService.swift:75-126`, parser at `:129-262`); a legacy OAuth fallback reads the `Claude Code-credentials` keychain item, gated behind the `ClaudeCodeEnableOAuthFallback` UserDefaults flag (`MeterBar/Services/ClaudeCodeLocalService.swift:9-14, 81-96`).
  - Codex: reads `~/.codex/auth.json` and calls `https://chatgpt.com/backend-api/wham/usage` with browser-spoofed headers (`MeterBar/Services/CodexCliLocalService.swift:18-24, 95-112`).
  - Cursor: opens Cursor's SQLite `state.vscdb` read-only, extracts the session JWT, and calls `https://cursor.com/api/usage-summary` with a spoofed cookie/User-Agent (`MeterBar/Services/CursorLocalService.swift:53-163, 285-295`).
- Estimates local token **costs** by scanning `~/.claude*/projects/**/*.jsonl` session logs and Codex's `~/.codex/archived_sessions` + `~/.codex/logs_2.sqlite`, priced from a hardcoded per-model table (`MeterBar/Services/CostTracker.swift:23-41, 227-313, 554-685`).
- Fires local notifications at 90%/100% of any limit (`MeterBar/App/MeterBarApp.swift:239-299`).
- Ships a small `meterbar` CLI that prints the app's cached metrics and does its own (simplified, drifted) cost scan (`MeterBarCLI/Sources/MeterBarCLI.swift`).

**Product identity note:** the public site is `meterbar.dev`. As of 2026-07-10 the bundle IDs (`dev.meterbar.app` / `dev.meterbar.app.Widget`), app group (`group.dev.meterbar.app`), and keychain service (`dev.meterbar.app`) match the domain; the keychain migration chain still reads the older `dev.shipshit.meterbar` and `com.agenticindiedev.quotaguard` services. Historical naming may still appear in archived audit and session material.

---

## 2. Repo / package map

Three build systems coexist in one repo (see risk R6):

| Unit | Path | Build system | What it is |
|---|---|---|---|
| **MeterBar.app** | `MeterBar/` | `MeterBar.xcodeproj` (target `MeterBar`) | Menu bar app. 16 services, 7 models, 5 views, AppKit delegate entry (`MeterBar/App/MeterBarApp.swift`) |
| **MeterBarWidgetExtension** | `MeterBarWidget/` | `MeterBar.xcodeproj` (target `MeterBarWidgetExtension`) | WidgetKit extension, kind `"UsageWidget"`, reads app-group JSON (`MeterBarWidget/UsageWidget.swift:147-233`) |
| **MeterBar (SwiftPM library + tests)** | root `Package.swift` | SwiftPM, tools 6.2, `.macOS(.v26)`, Swift 5 language mode | Exists to make `MeterBarTests/` runnable via `swift test`; excludes the app entry point (`Package.swift:18-40`) |
| **MeterBarCLI** | `MeterBarCLI/` | Separate SwiftPM package, tools 5.9, `.macOS(.v13)` | `meterbar` executable; sole dependency `swift-argument-parser >= 1.3.0` (`MeterBarCLI/Package.swift`) |
| **Asset scripts** | `scripts/` | Bun + Playwright 1.57.0 (`scripts/package.json`) | Icon/social-preview generators (`generate-icons.ts`, `generate-social-preview.ts`), README screenshot renderer (`render-readme-screenshots.sh/.swift`), coverage gate (`check-coverage.sh`), manual API smoke test (`test-api-access.sh` + `APIAccessTest.swift`) |
| **CI/CD** | `.github/workflows/` | GitHub Actions | `ci.yml`, `release.yml`, `update-homebrew.yml`, `secret-scan.yml` |
| **Agent docs/config** | `.agents/`, `.claude/`, `.codex/`, `.cursor/`, `.shipcode/` | — | AI-workflow docs, session logs, skills, hooks. `.claude/settings.json` enables the swift-lsp plugin; `.codex/hooks.json` wires a local voice-hooks server |
| **Docs/assets** | `docs/` (logo, screenshots), `assets/` (social preview), `README.md`, `LICENSE` (MIT, "Agentic Indie Dev") | — | User-facing docs |

**No shared code package.** `ServiceType`, `UsageLimit`, `UsageMetrics`, `UsageStatus` are copy-pasted into the widget (`MeterBarWidget/UsageWidget.swift:4-131`, comment says "duplicated for Widget target") and re-implemented in the CLI (`MeterBarCLI/Sources/MeterBarCLI.swift:314-331`). The drift is already documented internally in `.agents/docs/DEFERRED_WORK.md` §1, including a table of divergences (widget's `UsageMetrics` silently drops `extraUsage`/`resetCreditsAvailable` on decode; CLI hardcodes Sonnet pricing at `MeterBarCLI/Sources/MeterBarCLI.swift:263-268` while the app has a 13-entry per-model table).

---

## 3. Runtime / deployment map

**Runtime:**
- Swift 5 language mode everywhere (`SWIFT_VERSION = 5.0` in `MeterBar.xcodeproj/project.pbxproj:291,502`; `.swiftLanguageMode(.v5)` in root `Package.swift:33`). Not Swift 6 concurrency-checked.
- Deployment target **macOS 26.0** (`MACOSX_DEPLOYMENT_TARGET = 26.0`, pbxproj lines 281/326/491/537) — needed for Liquid Glass UI APIs per the comment in `Package.swift:30-32`. CLI targets macOS 13.
- App lifecycle: `@main` SwiftUI `App` + `NSApplicationDelegateAdaptor`; manual `NSStatusItem` + `NSPopover` (not `MenuBarExtra`), `LSUIElement = true` with a user-toggleable Dock icon via activation policy (`MeterBar/App/MeterBarApp.swift:23-206`, `MeterBar/Services/DockVisibilityStore.swift`).
- Concurrency: singletons everywhere (every service is `.shared`); `UsageDataManager` is `@MainActor ObservableObject` with a `Timer`-based auto-refresh (default 15 min, options 1 min–manual, `MeterBar/Models/RefreshInterval.swift`); a separate 5-minute `Task.sleep` loop drives notifications (`MeterBar/App/MeterBarApp.swift:240-260`). CLI subprocess runs on a dedicated GCD queue bridged via continuation (`ClaudeCodeCLIUsageService.swift:8-73`).
- **Sandbox: the main app is NOT sandboxed** — `ENABLE_APP_SANDBOX = NO` (pbxproj:471,517) and `MeterBar/MeterBar.entitlements` contains only the app group. Only the widget is sandboxed (`MeterBarWidget/MeterBarWidget.entitlements`). Hardened runtime is on for both. This contradicts README ("Sandboxed app", `README.md:193`) — see risk R2.

**Deployment / distribution:**
- Tag `v*` → `release.yml`: builds Release on `macos-26` runner with Xcode 26.2, **unsigned** (`CODE_SIGNING_ALLOWED=NO`, `release.yml:36-38`), builds the CLI with `swift build -c release` and copies it into `MeterBar.app/Contents/Helpers/` (`release.yml:41-46`), verifies CLI version == `CFBundleShortVersionString` (`:48-59`), zips with `ditto`, publishes a GitHub Release via pinned `softprops/action-gh-release` (`:88-98`).
- Then `update-homebrew.yml` (called via `workflow_call`, deliberately not `release: published` — reason documented at `release.yml:108-110`) rewrites `Casks/meterbar.rb` in the external repo `VincentShipsIt/homebrew-tap` using `secrets.TAP_GITHUB_TOKEN`, with a regex guard that the downloaded SHA256 is a bare 64-hex digest (`update-homebrew.yml:39-55`).
- **No code signing identity, no notarization** anywhere in the pipeline; README instructs users to `xattr -cr` the quarantine flag (`README.md:80-83`). Version currently `MARKETING_VERSION = 1.6` (pbxproj:282 etc.), while `MeterBar/Info.plist:22` pins `CFBundleShortVersionString` to `1.0` — the plist value appears overridden by build settings, but the checked-in `1.0` is misleading.
- README badge claims "macOS 13.0+" and "Swift 5.9" (`README.md:12-13`) — both false against the project files (macOS 26, Swift 5 mode / tools 6.2).

**Scheduling/cron analog:** in-process `Timer` (refresh) + `Task.sleep` loop (notifications) + WidgetKit timeline `.after(nextUpdate)` (`MeterBarWidget/UsageWidget.swift:225-233`). Session Wake additionally registers the bundled `meterbar wake-agent` as a per-user `SMAppService` launch agent while armed.

**Observability:** `os.Logger` only, via `AppLog` with 5 categories (`MeterBar/Services/AppLog.swift`). No crash reporting, no analytics, no telemetry (grep for Sentry/Crashlytics/analytics: zero hits in Swift sources). For a distributed app, the only failure signal is user reports.

---

## 4. Data / auth / integration map

**Network endpoints called (complete list found in sources):**

| Endpoint | Auth | File |
|---|---|---|
| `https://api.anthropic.com/api/oauth/usage` | Claude Code OAuth bearer + `anthropic-beta: oauth-2025-04-20` (fallback path + extra-usage probe) | `ClaudeCodeLocalService.swift:9,138-254` |
| `https://api.anthropic.com/v1/organizations/usage_report/messages` | Anthropic **Admin API key** (`x-api-key`), paginated, 50-page cap | `ClaudeService.swift:15-70` |
| `https://api.openai.com/v1/organization/usage/completions` | OpenAI **Admin API key** (Bearer), paginated, 50-page cap | `OpenAIService.swift:15-65` |
| `https://chatgpt.com/backend-api/wham/usage` | Codex OAuth bearer + `ChatGPT-Account-Id` header, browser-spoofed UA/Referer/Origin | `CodexCliLocalService.swift:18,95-112` |
| `https://cursor.com/api/usage-summary` | `WorkosCursorSessionToken` cookie forged from local DB JWT, spoofed UA | `CursorLocalService.swift:15,285-311` |
| (`https://cursor.com/api/dashboard/get-me` is declared at `CursorLocalService.swift:16` but never called — dead constant) | | |

All of these except the two admin APIs are **undocumented/private endpoints** subject to breakage (see R1).

**Local data read (integration surface on the user's machine):**
- `claude` binary resolved from `CLAUDE_CLI_PATH`, `$PATH`, then 7 hardcoded fallbacks (homebrew, `~/.local/bin`, npm/yarn/bun/volta) (`ClaudeCodeCLIUsageService.swift:31-57`); per-account `CLAUDE_CONFIG_DIR` env injection for multi-account (`:116-126`, accounts persisted in UserDefaults via `ClaudeCodeAccountStore`, `MeterBar/Models/ClaudeCodeAccount.swift:25-75`).
- macOS Keychain item service `"Claude Code-credentials"` (Claude Code's own item) — read-only, fallback path only (`ClaudeCodeLocalService.swift:12,55-78`).
- `~/.codex/auth.json`, `~/.codex/archived_sessions/*.jsonl`, `~/.codex/logs_2.sqlite` (`CodexCliLocalService.swift:21-24`, `CostTracker.swift:554-685`).
- Cursor `state.vscdb` SQLite — 5 candidate paths + recursive rescan (`CursorLocalService.swift:53-110`).
- `~/.claude/projects`, `~/.config/claude/projects`, every `~/.claude-*` profile dir, plus custom account dirs — JSONL scan for cost tracking (`CostTracker.swift:316-356`).
- Sandbox-escape helper: `ServiceSupport.realHomeDirectory()` uses `getpwuid` to bypass the container home (`ServiceSupport.swift:59-73`) — works because the app is not actually sandboxed.

**Data written / persisted:**
- `UserDefaults.standard`: metrics cache (`cached_usage_metrics`), refresh interval, hidden providers (`HiddenProviderServices`), dock flag (`ShowMeterBarInDock`), custom Claude accounts (`ClaudeCodeCustomAccounts`), OAuth-fallback flag.
- App group container `group.dev.shipshit.meterbar`: `cached_usage_metrics.json`, atomic writes on a serial queue, triggers `WidgetCenter.reloadTimelines` (`SharedDataStore.swift`). Read by widget and CLI (`MeterBarCLI.swift:95-123`).
- `~/Library/Application Support/MeterBar/cost-summary-v1.json` cost cache (`CostTracker.swift:175-225`).
- Own keychain service `dev.shipshit.meterbar` for the two optional admin keys (`KeychainManager.swift:7`, `AuthenticationManager.swift`).

**No database, no auth provider, no job queue** in the server sense. "Auth" is entirely: two admin keys in keychain + scavenged CLI credentials.

---

## 5. CI / test / tooling map

**CI (`.github/workflows/ci.yml`):** push/PR to `master`, `macos-26` runner, Xcode 26.2 pinned, builds Debug unsigned, then runs `xcodebuild … test || echo "Tests completed (some may require credentials)"` — **the `|| echo` makes the test step unconditionally green** (`ci.yml:35-44`). Compounding this: the Xcode project has **no test target** (only `MeterBar` and `MeterBarWidgetExtension` native targets exist, `project.pbxproj:122-169`) and the only shared scheme is `MeterBarWidgetExtension.xcscheme`, so the `-scheme MeterBar` test action has nothing to run even when it succeeds. Tests are actually runnable only via SwiftPM (`swift test` against root `Package.swift`). Net: **CI gates compilation, not tests** (risk R3).

**Tests (`MeterBarTests/`, 14 files, ~115 `func test…`, all XCTest):**
- Covered: CLI-output parser, Codex reset credits, dock store, extra-usage mapping, theme, OAuth expiry, refresh interval, reset countdown/pace, `ServiceType`, `TokenCost`, formatting, `UsageLimit`, `UsageMetrics`.
- `APIIntegrationTests.swift` (442 lines) makes **real network calls**, gated by `XCTSkip` when credentials are absent (`:26-28`).
- **Untested**: `UsageDataManager` (refresh/caching orchestration), `CostTracker` (1,029 lines — the biggest service), `CursorLocalService`, `CodexCliLocalService` fetch path, `ClaudeService`, `OpenAIService`, `SharedDataStore`, `KeychainManager`, `AuthenticationManager`, `ProviderVisibilityStore`, `ClaudeCodeAccountStore`, all 5 views (~3,500 lines), `AppDelegate` notification logic, and the entire CLI. The CLAUDE.md-declared policy "TDD, 80%+ coverage" is not met by the current suite and is not enforced anywhere in CI; `scripts/check-coverage.sh` implements an 80% llvm-cov gate but no workflow invokes it.
- Secret scanning: gitleaks 8.30.1, pinned + SHA256-verified, full-history scan, one scoped false-positive fingerprint in `.gitleaksignore` — this workflow is in good shape.

**Lint/format:** `.swiftlint.yml` (52 opt-in rules, custom `no_print_statements`, 120/200 line length) and `.swiftformat` (says `--swiftversion 5.9`) exist, but **no CI step and no build phase runs either** (no SwiftLint invocation in `ci.yml` or `project.pbxproj`). They are editor-only conventions today. `.editorconfig` present.

**Actions hygiene:** all third-party actions SHA-pinned (`ci.yml:16`, `release.yml:21,89`); release tag handled as data not shell (`release.yml:14-17`); workflow permissions scoped. Good.

---

## 6. Main architectural risks noticed during mapping

Ranked by expected pain.

- **R1 — The product stands on undocumented, reverse-engineered interfaces.** Regex-parsing `claude /usage` terminal output (fragile to any CLI copy change — parser matches English labels like "current week (all models)", `ClaudeCodeCLIUsageService.swift:137-151`), a private ChatGPT backend endpoint with spoofed browser headers, Cursor's internal SQLite schema + forged session cookie, and Codex's internal log formats (`logs_2.sqlite` text-blob regex extraction, `CostTracker.swift:59-73,643-685`). Any upstream change silently breaks a provider; there is no contract-test or canary beyond user reports (no telemetry, §3).
- **R2 — Security posture is misrepresented and inherently sensitive.** README claims "Sandboxed app with minimal file system access" (`README.md:193`); actually `ENABLE_APP_SANDBOX = NO` and the app reads other apps' credentials (Claude Code keychain item, Codex OAuth tokens, Cursor session JWT) and ships **unsigned and un-notarized**, with install docs telling users to strip quarantine. Unsigned + credential-scavenging is a trust problem for a distributed utility and an easy target for criticism.
- **R3 — Tests do not gate anything.** `|| echo` on the CI test step, no test target in the Xcode project, coverage script never wired into CI, lint never run in CI. The 115 test functions only run when someone remembers `swift test` locally.
- **R4 — Triplicate model definitions with confirmed drift.** App/widget/CLI each own `UsageLimit`/`UsageMetrics`/`ServiceType`; widget already silently drops fields on decode; CLI already had one production decode bug from this (Int vs Double, fixed per `DEFERRED_WORK.md` and the comment at `MeterBarCLI.swift:321-323`). Every new shared field is a latent cross-target bug.
- **R5 — Hardcoded pricing and heuristic quotas rot silently.** The per-model price table (`CostTracker.swift:23-41`), the CLI's separate Sonnet-only pricing (`MeterBarCLI.swift:263-268`), Cursor's assumed 500-request default and 1.5× on-demand headroom guess (`CursorLocalService.swift:22-25`), and the fake "1.5× usage or 1M token" limit for admin APIs (`ClaudeService.swift:85-89`, `OpenAIService.swift:82-86`) all present invented numbers as facts in the UI.
- **R6 — Three build systems for one app.** Xcode project (app/widget), root SwiftPM package (tests only, with a hand-maintained `exclude` list), and a second SwiftPM package (CLI). Settings already disagree (Swift tools 6.2 vs 5.9; macOS 26 vs 13; `.swiftformat` says 5.9). `create_xcode_project.sh` at the root is a fourth artifact (XcodeGen-era generator) whose relevance is unverified.
- **R7 — Internal docs are dangerously stale where they matter.** `.agents/SYSTEM/ARCHITECTURE.md` (dated 2025-01-27) documents a phantom `CursorService.swift`, the wrong app group (`group.com.agenticindiedev.meterbar`), wrong keychain layout, placeholder endpoints, and macOS 13; `.agents/docs/IMPLEMENTATION_STATUS.md` lists a nonexistent `CodexService`; `AGENTS.md`/`CLAUDE.md`/`CODEX.md` all point to `.agent/` (dir is `.agents/`) and a nonexistent `.agent/TASKS/`; `.agents/SYSTEM/RULES.md` is mostly TypeScript rules (kebab-case files, no `any`, `I`-prefixed interfaces) in a pure Swift repo. An agent following these docs will act on wrong facts. By contrast, `.agents/docs/DEFERRED_WORK.md` and the 2026-06 session logs are accurate and current.
- **R8 — God files.** `UsageDashboardView.swift` 1,612 lines (30+ private types in one file), `CostTracker.swift` 1,029, `MenuBarView.swift` 1,024, `SettingsView.swift` 764. Combined with `file_length`/`type_body_length` lint rules disabled (`.swiftlint.yml:17-23`), nothing pushes back on growth.
- **R9 — Version/metadata inconsistencies.** `MARKETING_VERSION 1.6` vs checked-in `Info.plist` `1.0`; README badges (macOS 13, Swift 5.9, "App Store Coming Soon") vs macOS 26 unsigned reality; brand split shipshit.dev vs Agentic Indie Dev vs Quota Guard.

Minor/dead things noticed: unused `getMeEndpoint` constant (`CursorLocalService.swift:16`); `AuthenticationManager.isCursorAuthenticated` hardcoded `false` and unused meaningfully (`AuthenticationManager.swift:57-59`); `baseURL` constant in `ClaudeCodeLocalService.swift:11` unused; `create_xcode_project.sh` likely orphaned.

---

## 7. Suggested follow-up audit sessions

1. **CI/test enforcement audit** (highest leverage, small diff): remove the `|| echo` swallow, decide SwiftPM-vs-Xcode as the single test path, wire `scripts/check-coverage.sh` and SwiftLint into `ci.yml`, and measure real coverage of the untested list in §5. (R3)
2. **Shared-package extraction audit**: execute `.agents/docs/DEFERRED_WORK.md` §1 (`MeterBarShared` for the four duplicated types) and add cross-target decode round-trip tests. (R4, R6)
3. **Security & distribution audit**: reconcile README security claims with the non-sandboxed reality, evaluate Developer ID signing + notarization in `release.yml` (cert secrets exist? currently none referenced), and review the credential-scavenging surface (what is read, what could leak into logs — `AppLog` privacy annotations look deliberate but deserve a pass). (R2)
4. **Provider-contract resilience audit**: catalogue every parse assumption per provider (CLI output labels, JSON fields marked "discovered via testing"), add fixture-based contract tests + graceful-degradation paths, and consider a version canary. (R1)
5. **Pricing/quota data audit**: single source of truth for the price table (app vs CLI), date-stamp it, and flag invented limits (Cursor 500, 1.5× heuristics) in the UI as estimates. (R5)
6. **Docs truth-sync session**: delete or rewrite `.agents/SYSTEM/ARCHITECTURE.md`, `PROJECT-MAP.md`, `IMPLEMENTATION_STATUS.md`, fix the `.agent/` → `.agents/` pointers in all three entry files, and replace the TypeScript rules in `RULES.md` with the Swift conventions actually in force (`.swiftlint.yml`/`.swiftformat`). (R7)
7. **View-layer decomposition audit** (lowest urgency): split the three 1,000+ line view files; purely mechanical but blocked on nothing. (R8)

---

## Addendum (2026-07-02, same day): remediation status

Fixes landed in the follow-up pass on branch `claude/xenodochial-yonath-5d5f6d`:

- **R3 (partially fixed):** `ci.yml` rewritten — `swift test` is now a hard gate via `scripts/check-coverage.sh` (coverage floor starts at 40%, ratchet upward), SwiftLint 0.65.0 added as a `--strict` gate (tree was violation-free at time of adding), CLI build added. The bogus `xcodebuild test || echo` step is gone.
- **R2 (docs fixed, signing outstanding):** README no longer claims the app is sandboxed; badges corrected to macOS 26+. Signing/notarization deferred — needs Developer ID cert secrets (follow-up task spawned).
- **R4 (guarded, not fixed):** `MeterBarTests/CachedMetricsContractTests.swift` locks the shared JSON contract (keys, default date strategy, widget/CLI-shaped decode). Package extraction still deferred (needs full Xcode).
- **R1 (guarded):** `MeterBarTests/ProviderResponseContractTests.swift` adds decode fixtures for Codex, Cursor, and Claude Code OAuth responses.
- **R5 (annotated):** pricing tables date-stamped with sync notes between `CostTracker` and the CLI copy.
- **R7 (fixed):** `ARCHITECTURE.md`, `PROJECT-MAP.md`, `IMPLEMENTATION_STATUS.md`, `RULES.md` rewritten to match reality; all live `.agent/` → `.agents/` references fixed (historical session logs left untouched).
- Dead code removed: `getMeEndpoint`, unused `baseURL`, `isCursorAuthenticated`.
- **R6, R8:** untouched (follow-up tasks spawned: shared package, view split, signing).

**Environment caveat discovered during remediation:** this machine has Command Line Tools only — no XCTest module, so `swift test` cannot run locally here. Tests verify on CI (macos-26 runners). `swift build` (app library incl. views) and `MeterBarCLI` build pass locally.

**Evidence gaps / unverified items:**
- Whether the `VincentShipsIt/homebrew-tap` cask matches current release artifacts (external repo, not in this checkout).
- Whether `xcodebuild -scheme MeterBar` on CI auto-creates the unshared scheme (CI history not inspected from here; the pbxproj proves no test target either way).
- Whether `create_xcode_project.sh` is still used by anything (no references found in workflows or scripts).
- Actual current coverage percentage (requires running `swift test --enable-code-coverage`; not run during this read-only audit).
