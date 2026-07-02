# DRY / Slop Audit — MeterBar

**Date:** 2026-07-02
**Scope:** Entire repo — `MeterBar/` (app), `MeterBarWidget/`, `MeterBarCLI/`, `MeterBarTests/`, `scripts/`, `.github/workflows/`, docs and repo hygiene (~13k source lines).
**Method:** Every source file cited below was read in full this session; every dead-code claim was verified by repo-wide reference grep. No code was modified.

---

## 1. Executive summary

MeterBar's core app is in decent shape — `ServiceSupport`, `UsageFormat`, `MeterBarTheme`, and `meterBarCardSurface` show prior DRY passes that worked. The debt is concentrated in three structural problems:

1. **The model layer is forked across five compilation islands.** `UsageLimit`/`UsageMetrics`/`ServiceType` are independently redefined in the app, the widget, the CLI, and two standalone scripts, all decoding the same app-group JSON wire format. This duplication has **already caused a shipped bug** (CLI silently printed nothing because its `UsageLimit.used` was `Int` while the app writes `Double` — documented in [MeterBarCLI.swift:321](MeterBarCLI/Sources/MeterBarCLI.swift:321)) and has **already drifted** (the widget's `iconName` returns asset names while the app's returns SF Symbols; the widget's number formatter drops the M/B tiers the app's fixed).

2. **"What does 80% mean?" has four different answers.** Warning/critical severity is computed with four incompatible threshold schemes (UI: ≤10/≤25 percent-left; models/widget: ≥80/≥100 percent-used; notifications: ≥90/≥100; CLI: ≥50/≥80), plus three separate `percentLeft` implementations with different rounding, so the menu-bar title, popover, widget, notification, and CLI can disagree about the same quota at the same moment.

3. **The popover and dashboard are parallel implementations, not shared code.** Snapshot building, limit rows, status banding, and status copy are duplicated nearly verbatim between [MenuBarView.swift](MeterBar/Views/MenuBarView.swift) and [UsageDashboardView.swift](MeterBar/Views/UsageDashboardView.swift), with small semantic divergences (inverted third-limit label logic, an icon derived by string-matching rendered title copy) that are drift, not design.

Also significant: the CLI's `cost` subcommand re-implements the app's cost scan with no dedup, one scan root, and hardcoded Sonnet-only pricing, so **`meterbar cost` and the app's Costs tab report different numbers from the same logs**; CI's test step is `test || echo "Tests completed"`, which **swallows every test failure**; and there is a tail of confirmed-dead symbols, an unreferenced duplicate SVG, an obsolete bootstrap script, and agent docs pointing at a directory that doesn't exist.

Counts: **7 high-impact duplication clusters, 17 dead/obsolete candidates, 12 inconsistent-pattern findings.** Roughly half the cleanup is mechanical (safe deletes/moves); the valuable half (shared kit, threshold unification, CLI cost parity) is semantic and needs the test additions listed in §7.

---

## 2. High-impact duplication clusters

### Cluster A — Model layer forked across 5 compilation islands ⚠️ highest impact

The same domain types are independently declared in five places that cannot import each other under the current target layout:

| Copy | Location | Notes |
|---|---|---|
| Canonical | [UsageLimit.swift](MeterBar/Models/UsageLimit.swift), [UsageMetrics.swift](MeterBar/Models/UsageMetrics.swift), [ServiceType.swift](MeterBar/Models/ServiceType.swift) | Full-featured: `windowSeconds`, `pace()`, `ExtraUsageStatus`, `resetCreditsAvailable` |
| Widget | [UsageWidget.swift:4-170](MeterBarWidget/UsageWidget.swift:4) | Header literally says `// MARK: - Shared Types (duplicated for Widget target)`. Includes its own `SharedDataStore` copy (lines 144-170). |
| CLI | [MeterBarCLI.swift:314-342](MeterBarCLI/Sources/MeterBarCLI.swift:314) (`ServiceMetrics`, `UsageLimit`, `CostResult`) | Comment at line 321-323 documents the Int-vs-Double decode bug that "silently produced empty CLI output" — the drift cost has already been paid once. |
| Screenshot script | [render-readme-screenshots.swift:5-85](scripts/render-readme-screenshots.swift:5) | Own `UsageLimit`/`UsageStatus`/`ServiceType` (3-case!)/`UsageMetrics` |
| API test script | [APIAccessTest.swift:65-150](scripts/APIAccessTest.swift:65) | Re-declares `AnthropicUsageResponse`, `OpenAIUsageResponse`, `ClaudeCodeCredentials`, `ClaudeAiOAuth`, `ClaudeCodeUsageResponse`, `UsageWindow` from the services |

**Observed drift (not hypothetical):**
- `ServiceType.iconName` means *SF Symbol name* in the app ([ServiceType.swift:22-30](MeterBar/Models/ServiceType.swift:22): `"sparkles"`, `"terminal"`) but *asset-catalog image name* in the widget ([UsageWidget.swift:25-33](MeterBarWidget/UsageWidget.swift:25): `"ClaudeIcon"`). Same symbol, different contract — copy code between targets and it breaks silently.
- Widget `ServiceType` has `sortOrder` (line 35-43); the app's doesn't.
- Widget `formatNumber` ([UsageWidget.swift:445-450](MeterBarWidget/UsageWidget.swift:445)) handles only the `k` tier — the exact defect the `UsageFormat` doc comment says was fixed ("previously duplicated in four places — one of which silently dropped the billions tier", [UsageFormatting.swift:5-8](MeterBar/Models/UsageFormatting.swift:5)). The fork survived the fix.
- Widget `UsageStatus.color` is hardcoded `.green/.orange/.red` (lines 51-57) vs the app's appearance-adaptive `MeterBarTheme.success/warning/danger`.
- Widget/CLI copies lack `windowSeconds`/`extraUsage`/`resetCreditsAvailable`, so a renamed or restructured key in the app's encoder breaks them with no compile error — the shared wire contract (`cached_usage_metrics.json` in the app group) exists only as convention in 3 decoders.

**Impact:** every model change is a 3–5 file manual sync with silent-failure semantics across process boundaries.
**Fix:** shared `MeterBarKit` framework/SPM target (see §5.1). This clears the "must remove real complexity" bar — it replaces N hand-synced wire-format definitions with one.

### Cluster B — Cost accounting duplicated with user-visible divergence

The CLI's `Cost` subcommand ([MeterBarCLI.swift:214-280](MeterBarCLI/Sources/MeterBarCLI.swift:214)) re-implements [CostTracker.scanClaudeCodeSessions](MeterBar/Services/CostTracker.swift:227) with materially different behavior:

| Behavior | CostTracker (app) | CLI `meterbar cost` |
|---|---|---|
| Scan roots | `CLAUDE_CONFIG_DIR`, `~/.config/claude/projects`, `~/.claude/projects`, `~/.claude-*` profiles, per-account dirs ([CostTracker.swift:316-356](MeterBar/Services/CostTracker.swift:316)) | only `~/.claude/projects` (line 216-218) |
| Event dedup | by `messageID:requestID` ([CostTracker.swift:1025-1028](MeterBar/Services/CostTracker.swift:1025)) — retried events counted once | none — retried events double-counted |
| Cutoff | per-event timestamp ≥ cutoff (line 405-409) | file modification date only (line 240) — counts *all* lines in any recently-touched file |
| Pricing | per-model table incl. cache tiers ([CostTracker.swift:23-37](MeterBar/Services/CostTracker.swift:23)) | Sonnet constants hardcoded inline (lines 264-267) |
| Codex | scanned (archived sessions + SQLite logs) | not scanned at all |

**Impact:** the app's Costs tab and `meterbar cost` give different dollar figures for the same logs — a correctness/trust problem, not just a maintenance one.

Within CostTracker itself, [`calculateCost`](MeterBar/Services/CostTracker.swift:863) and [`calculateClaudeCost`](MeterBar/Services/CostTracker.swift:871) are near-duplicates: the Claude variant is a strict superset (adds the 1-hour cache tier) but also clamps negatives with `max(0, …)` while the generic one doesn't. `calculateCost(a,b,c,d,p)` ≡ `calculateClaudeCost(a,b,c,0,d,p)` except for that clamp — classic "almost the same with divergent behavior".

### Cluster C — Provider fetch pipeline: half-adopted abstraction

[`ServiceSupport.fetchDecoded`](MeterBar/Services/ServiceSupport.swift:37) exists precisely to centralize HTTP-status + decode boilerplate, but only [ClaudeService.swift:66](MeterBar/Services/ClaudeService.swift:66) and [OpenAIService.swift:61](MeterBar/Services/OpenAIService.swift:61) use it. The three local services hand-roll the same skeleton:

- `guard let httpResponse … else { throw .apiError("Invalid response type") }` + 401→`notAuthenticated` (set `hasAccess=false`) + non-2xx→`apiError` + `catch URLError → ServiceSupport.message(for:)` + catch-all→`.parsingError`, three times: [ClaudeCodeLocalService.swift:150-232](MeterBar/Services/ClaudeCodeLocalService.swift:150), [CodexCliLocalService.swift:114-214](MeterBar/Services/CodexCliLocalService.swift:114), [CursorLocalService.swift:311-338](MeterBar/Services/CursorLocalService.swift:311).
- **Divergence hidden in the split:** `fetchDecoded` defaults to `session: URLSession.shared` and neither admin service passes a session — so the admin services silently *skip* the `makeUsageSession()` configuration (30s/60s timeouts, `waitsForConnectivity`) that all three local services get. The helper built for consistency ships an inconsistency.
- Error copy differs per copy: `"HTTP 401: <full body>"` (Claude Code, line 168) vs `"HTTP \(code): <body prefix 100>"` (Codex, line 132) vs `"HTTP \(code)"` no body (Cursor, line 327) vs `"API error (401): <body>"` (`fetchDecoded`, line 53).
- `checkAccess()`'s main-thread `apply` closure is duplicated **verbatim** at [CodexCliLocalService.swift:69-77](MeterBar/Services/CodexCliLocalService.swift:69) and [CursorLocalService.swift:207-215](MeterBar/Services/CursorLocalService.swift:207); Claude Code's `checkAccess` instead runs synchronously in `init()` ([ClaudeCodeLocalService.swift:24-27](MeterBar/Services/ClaudeCodeLocalService.swift:24)) — a blocking keychain read on whatever thread constructs the singleton, while the other two deliberately defer to `Task.detached`.
- Browser-spoof `User-Agent` strings duplicated and different: Safari 17 UA at [CodexCliLocalService.swift:111](MeterBar/Services/CodexCliLocalService.swift:111) vs truncated AppleWebKit/537.36 UA at [CursorLocalService.swift:293](MeterBar/Services/CursorLocalService.swift:293).
- [ClaudeService](MeterBar/Services/ClaudeService.swift) and [OpenAIService](MeterBar/Services/OpenAIService.swift) are ~95% line-for-line clones (same 7-day window, same pagination loop with `maxUsagePages = 50`, same aggregation, same manufactured limit `max(totalTokens * 1.5, 1_000_000)` with the same comment, lines 85-89 / 82-86). Differences are data (endpoint, auth header, date format, bucket shape) — a config-driven single implementation, if these services are kept at all (see §3, "orphaned admin providers").

### Cluster D — Popover vs dashboard: parallel UI stacks

[MenuBarView.swift](MeterBar/Views/MenuBarView.swift) and [UsageDashboardView.swift](MeterBar/Views/UsageDashboardView.swift) each define a private snapshot pipeline that is the same design pasted twice:

- `PopoverProviderSnapshot`/`PopoverLimit` ([MenuBarView.swift:341-416](MeterBar/Views/MenuBarView.swift:341)) vs `DashboardProviderSnapshot`/`DashboardLimit` ([UsageDashboardView.swift:451-492](MeterBar/Views/UsageDashboardView.swift:451)). `percentLeft` is **verbatim identical** in both (`max(0, 100-used)`, `== 0 ? 0 : max(1, Int(ceil(…)))` — lines 412-415 vs 488-491).
- Snapshot assembly (provider order, per-account Claude titles `account.isDefault && accounts.count == 1 ? "Claude" : account.name`, empty-state copy) duplicated: [MenuBarView.swift:189-238](MeterBar/Views/MenuBarView.swift:189) vs [UsageDashboardView.swift:310-339](MeterBar/Views/UsageDashboardView.swift:310).
- Status banding text `"Out"/"Critical"/"Tight"/"Healthy"` duplicated verbatim: [MenuBarView.swift:430-436](MeterBar/Views/MenuBarView.swift:430) vs [UsageDashboardView.swift:556-562](MeterBar/Views/UsageDashboardView.swift:556). Hero title/detail copy (`"Quota needs attention"` etc.) duplicated: [MenuBarView.swift:253-273](MeterBar/Views/MenuBarView.swift:253) vs [UsageDashboardView.swift:369-391](MeterBar/Views/UsageDashboardView.swift:369).
- **Divergences that are drift, not design:** the third-limit label logic is inverted — popover: `logoKind == .claude ? "Sonnet" : "Code Review"` (line 374); dashboard: `service == .codexCli ? "Code Review" : "Sonnet"` (line 468). And [`DashboardStatusHero.iconName`](MeterBar/Views/UsageDashboardView.swift:501) re-derives severity by **string-matching its own rendered title** (`localizedCaseInsensitiveContains("exhausted")`…) while the popover picks the icon from the numeric band ([MenuBarView.swift:279-287](MeterBar/Views/MenuBarView.swift:279)). Change the copy, break the icon.
- `paceContext` derived by string-matching the display title (`title.localizedCaseInsensitiveContains("weekly")`) in both files (MenuBarView:537-539, Dashboard:787-789) — semantics recovered from UI strings, twice.
- Genuinely shared components (`UsageBar`, `ProviderLogoView`, `ProviderLogoKind`, `ProviderLogoImageCache`, `ExtraUsageStatusPill`, `ResetCountdownLabel`, `NextResetCountdownLabel`, `BlockingLimitResetCounter`) live *inside* MenuBarView.swift (lines 4-35, 576-1008) and are consumed by the dashboard and settings — the popover file is accidentally the design system.

### Cluster E — Four incompatible severity/threshold schemes

| Surface | Scheme | Source |
|---|---|---|
| Popover/dashboard/theme | percent-**left** ≤ 10 danger, ≤ 25 warning | [MeterBarTheme.quotaStatusColor](MeterBar/Views/MeterBarTheme.swift:49) + the duplicated `statusText` bands (Cluster D) |
| Models + widget | percent-**used** ≥ 80 `isNearLimit`, ≥ 100 `isAtLimit` | [UsageLimit.swift:32-48](MeterBar/Models/UsageLimit.swift:32), widget copy [UsageWidget.swift:82-98](MeterBarWidget/UsageWidget.swift:82) |
| Notifications | percent-used ≥ 90 warn, ≥ 100 critical | [MeterBarApp.swift:274-291](MeterBar/App/MeterBarApp.swift:274) |
| CLI | percent-used ≥ 50 ⚠, ≥ 80 ✗ | [MeterBarCLI.swift:175-179](MeterBarCLI/Sources/MeterBarCLI.swift:175) |

Plus a **third `percentLeft` implementation** in [AppDelegate.percentLeft](MeterBar/App/MeterBarApp.swift:404) that uses `.rounded()` where the view copies use `ceil` + `max(1, …)` — the menu-bar title can read "12%" while the popover reads "13% left" for the same limit. It also re-derives `rawPercentage` inline instead of calling `limit.rawPercentage`.

The same quota therefore renders green in one surface and amber in another. One `QuotaBands`/`percentLeft` definition (in the shared kit) should own this.

### Cluster F — Small parsing/serialization helpers duplicated

1. **JWT base64url payload decode** — [OAuthTokenExpiry.decodeBase64URL](MeterBar/Services/OAuthTokenExpiry.swift:39) vs [CursorLocalService.extractUserIdFromJWT](MeterBar/Services/CursorLocalService.swift:166) (same pad-and-replace dance) + a third copy in [APIAccessTest.swift:343](scripts/APIAccessTest.swift:343).
2. **Fractional/plain ISO8601 formatter pair with fallback** — [CostTracker.swift:47-57](MeterBar/Services/CostTracker.swift:47) (+`parseISO8601`, line 481) vs [CursorLocalService.swift:28-38](MeterBar/Services/CursorLocalService.swift:28) (+ inline `??` fallback, line 246).
3. **`[ServiceType: UsageMetrics] ↔ [String: UsageMetrics]` mapping ×4** — encode+decode in [UsageDataManager.swift:231-252](MeterBar/Services/UsageDataManager.swift:231), encode+decode in [SharedDataStore.swift:32-67](MeterBar/Services/SharedDataStore.swift:32), decode in widget [UsageWidget.swift:159-168](MeterBarWidget/UsageWidget.swift:159), decode in CLI [MeterBarCLI.swift:108-122](MeterBarCLI/Sources/MeterBarCLI.swift:108).
4. **Raw `SecItemCopyMatching` query boilerplate** — [KeychainManager.get](MeterBar/Services/KeychainManager.swift:38) vs [ClaudeCodeLocalService.getCredentials](MeterBar/Services/ClaudeCodeLocalService.swift:55) vs two more copies in [APIAccessTest.swift:16-61](scripts/APIAccessTest.swift:16).
5. **Read-only SQLite open/prepare/step/close** — [CursorLocalService.getAccessTokenFromDatabase](MeterBar/Services/CursorLocalService.swift:114) vs [CostTracker.scanCodexSQLiteLogs](MeterBar/Services/CostTracker.swift:643). Two call sites; a helper is optional — fold only if a third reader appears.
6. **Currency formatting** — [`UsageFormat.cost`](MeterBar/Models/UsageFormatting.swift:44) vs [`ExtraUsageStatus.formatAmount`](MeterBar/Models/UsageMetrics.swift:33) (same `String(format: "$%.2f")` for USD); CLI re-allocates a `RelativeDateTimeFormatter` per call ([MeterBarCLI.swift:181-185](MeterBarCLI/Sources/MeterBarCLI.swift:181)) — the exact perf antipattern `UsageFormat.relative`'s cached formatter exists to prevent.

### Cluster G — Dual metrics cache with a dead fallback

`UsageDataManager.refreshAll` persists metrics **twice** on every refresh: to `UserDefaults` key `"cached_usage_metrics"` ([UsageDataManager.swift:244-252](MeterBar/Services/UsageDataManager.swift:244)) and to the app-group file `cached_usage_metrics.json` via [SharedDataStore.saveMetrics](MeterBar/Services/SharedDataStore.swift:24). The CLI reads the file, then "falls back" to `UserDefaults.standard` ([MeterBarCLI.swift:107-114](MeterBarCLI/Sources/MeterBarCLI.swift:107)) — but the CLI is a separate unbundled process, so `UserDefaults.standard` there does not see the app's defaults domain; the fallback is dead code that can only ever return `[:]`. The app itself could read/write only the shared file (or only UserDefaults + a file mirror in one place), collapsing two cache paths and two of the four map-encode copies from Cluster F.3.

---

## 3. Dead / obsolete code candidates

Verified by repo-wide grep; "test-only" means the only references outside the declaration are the symbol's own unit tests.

**Unreferenced symbols (safe deletes):**
1. [ClaudeCodeLocalService.swift:11](MeterBar/Services/ClaudeCodeLocalService.swift:11) — `private let baseURL` never used (endpoint is a separate literal).
2. [AuthenticationManager.swift:57-59](MeterBar/Services/AuthenticationManager.swift:57) — `isCursorAuthenticated`, always `false`, zero references.
3. [KeychainManager.swift:70-72](MeterBar/Services/KeychainManager.swift:70) — `hasKey(key:)`, zero references.
4. [UsageDataManager.swift:290-302](MeterBar/Services/UsageDataManager.swift:290) — `getNextRefreshTime()`, zero references.
5. [AppLog.swift:16](MeterBar/Services/AppLog.swift:16) — `network` logger category, zero references.
6. [UsageWidget.swift:387-451](MeterBarWidget/UsageWidget.swift:387) — `ServiceDetailView` + `LimitDetailView`: `ServiceDetailView` is referenced by nothing; `LimitDetailView` only by `ServiceDetailView`. Both dead in the widget.
7. [MeterBarApp.swift:373-376](MeterBar/App/MeterBarApp.swift:373) — `selectedStatus` returns a tuple whose label is the constant `"overview primary quota"`; vestigial indirection.

**Test-only life support (delete symbol + its test, or start using it):**
8. [UsageMetrics.overallStatus](MeterBar/Models/UsageMetrics.swift:107) and [`hasData`](MeterBar/Models/UsageMetrics.swift:117) — app UI uses percent-left bands instead; only `UsageMetricsTests` calls these (the widget uses its *own copies*).
9. [UsageLimit.statusColor](MeterBar/Models/UsageLimit.swift:38) and the app-side [`UsageStatus` enum + `.color`](MeterBar/Models/UsageLimit.swift:214) — the `statusColor` references in views are unrelated private properties; the model chain is only exercised by tests. (Keep the *widget's* copies until Cluster A lands; then one shared version becomes genuinely used.)
10. [ExtraUsageStatus.isOn](MeterBar/Models/UsageMetrics.swift:31) — test-only.
11. [MeterBarTheme.metricColor](MeterBar/Views/MeterBarTheme.swift:55) — test-only; meanwhile both limit rows re-implement a *variant* inline (`isOut ? MeterBarTheme.danger : .primary`, [MenuBarView.swift:552](MeterBar/Views/MenuBarView.swift:552), [UsageDashboardView.swift:805](MeterBar/Views/UsageDashboardView.swift:805)) with a *different* threshold (≤0 vs ≤10). Either adopt it in the rows or delete it.

**Dead/obsolete files & config:**
12. [docs/icon.svg](docs/icon.svg) — byte-identical to `docs/logo.svg` (verified with `diff`), referenced nowhere. Delete.
13. [create_xcode_project.sh](create_xcode_project.sh) — instructs manual creation of a "QuotaGuard" Xcode project, references a `QuotaGuard/` folder and `XCODE_SETUP.md` that don't exist; `MeterBar.xcodeproj` is checked in. Delete.
14. CLI UserDefaults fallback ([MeterBarCLI.swift:107-114](MeterBarCLI/Sources/MeterBarCLI.swift:107)) — cross-process dead path (Cluster G). Delete.
15. `"ClaudeCodeEnableOAuthFallback"` ([ClaudeCodeLocalService.swift:14](MeterBar/Services/ClaudeCodeLocalService.swift:14)) — read in three places, **written nowhere** (no Settings toggle). Hidden `defaults write`-only flag gating the whole legacy-OAuth path (~150 lines). Decide: expose it in Settings, or delete flag + fallback path.
16. **Orphaned admin providers** — `.claude`/`.openai` metrics are fetched ([UsageDataManager.swift:50-58, 75-83](MeterBar/Services/UsageDataManager.swift:50)), cached, and shared, but rendered **nowhere in the app**: both snapshot builders (Cluster D) and the menu-bar title ([MeterBarApp.swift:379-397](MeterBar/App/MeterBarApp.swift:379)) hard-exclude them. Their manufactured limit `total = max(used × 1.5, 1M)` caps `percentage` at ~66.7%, so the ≥90% notification path can mathematically never fire for them. Only the widget (via its own type copies) and Settings' connection pill can surface them. Decide: wire them into the dashboard, or remove the two services + Settings sections + `AuthenticationManager` (≈450 lines and one keychain dependency).
17. Stale doc pointers — [AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md), and [CODEX.md](CODEX.md) all direct agents to `.agent/…` (`.agent/SYSTEM/RULES.md`, `.agent/SESSIONS/`); the directory is actually `.agents/`. Every referenced path 404s. Also three near-identical entry files where one + two pointers would do.

---

## 4. Inconsistent local patterns

1. **CI swallows test failures** — [ci.yml:36-44](.github/workflows/ci.yml:36): `xcodebuild … test || echo "Tests completed (some may require credentials)"`. Any red test still exits 0. The credential-gated tests already `XCTSkip` themselves ([APIIntegrationTests.swift:26,73,120,203,280](MeterBarTests/APIIntegrationTests.swift:26)), so the guard is unnecessary *and* disables the repo's own "run tests before committing" policy. Meanwhile [scripts/check-coverage.sh](scripts/check-coverage.sh) (80% gate) exists but is wired into no workflow.
2. **Two build systems, split duties** — CI + release build via `MeterBar.xcodeproj`; coverage script + CLI build via SwiftPM ([Package.swift](Package.swift) excludes the app entry point to stay compilable). Workable, but undocumented; `Package.swift` pins `macOS(.v26)`/tools 6.2 while [MeterBarCLI/Package.swift](MeterBarCLI/Package.swift) pins `macOS(.v13)`/tools 5.9.
3. **README drift** — badges say *macOS 13.0+ / Swift 5.9* ([README.md:12-13](README.md:12)) vs actual macOS 26 target; features list an "Accordion UI" the current popover doesn't have; auth described as "OAuth token from `claude login`" though the app is CLI-`/usage`-first with OAuth as a hidden fallback; screenshots are renders of the hand-maintained replica UI in [render-readme-screenshots.swift](scripts/render-readme-screenshots.swift) (which lacks pace markers, extra-usage pills, reset counters — i.e., the README shows a UI the app no longer has).
4. **Branding split: QuotaGuard vs MeterBar vs shipshit** — keychain service `com.agenticindiedev.quotaguard` ([KeychainManager.swift:7](MeterBar/Services/KeychainManager.swift:7)), `quotaguard-scripts` ([scripts/package.json](scripts/package.json)), "Quota Guard" headers in [CLAUDE.md](CLAUDE.md)/[generate-social-preview.ts](scripts/generate-social-preview.ts)/[APIAccessTest.swift](scripts/APIAccessTest.swift)/[test-api-access.sh](scripts/test-api-access.sh) vs `group.dev.shipshit.meterbar`, `dev.shipshit.meterbar.*` queue labels, and `app.meterbar` log fallback. (Keychain service and app-group IDs are migration-sensitive — document rather than rename.)
5. **Error taxonomy abuse** — both catch-alls map unknown errors to `.parsingError` ([ClaudeCodeLocalService.swift:226](MeterBar/Services/ClaudeCodeLocalService.swift:226), [CodexCliLocalService.swift:211](MeterBar/Services/CodexCliLocalService.swift:211)), so users see "Failed to parse response" for non-parsing failures. `ServiceError.invalidURL` exists but local services throw `apiError("Invalid usage endpoint URL")` instead ([ClaudeCodeLocalService.swift:139](MeterBar/Services/ClaudeCodeLocalService.swift:139), Codex:92, Cursor:299).
6. **Shared types homed inside unrelated files** — `ServiceError` lives at the bottom of [ClaudeService.swift:136](MeterBar/Services/ClaudeService.swift:136); `ProviderLogoKind`/`ProviderLogoImageCache` live in [MenuBarView.swift:4-35,872-897](MeterBar/Views/MenuBarView.swift:4) but are used by dashboard + settings; countdown components ditto (Cluster D).
7. **Logging asymmetry** — Codex/Cursor log HTTP failures via `AppLog.usage` ([CodexCliLocalService.swift:131](MeterBar/Services/CodexCliLocalService.swift:131), [CursorLocalService.swift:326](MeterBar/Services/CursorLocalService.swift:326)); Claude Code's HTTP path logs nothing.
8. **Home-directory resolution split** — services use `ServiceSupport.realHomeDirectory()` explicitly *because* sandboxed `homeDirectoryForCurrentUser` points at the container ([ServiceSupport.swift:59-64](MeterBar/Services/ServiceSupport.swift:59)); but [CostTracker.swift:318,555](MeterBar/Services/CostTracker.swift:318) and the CLI cost scan use `FileManager.default.homeDirectoryForCurrentUser`. If the app is ever sandboxed, cost scanning silently finds zero logs while quota fetching keeps working. Align on `realHomeDirectory()`.
9. **`refresh(service:)` re-implements `refreshAll` per provider** — [UsageDataManager.swift:128-221](MeterBar/Services/UsageDataManager.swift:128): the `.codexCli` and `.cursor` catch blocks are literally identical (173-187 vs 188-202); `.claude`/`.openai` lack the cache-preserve behavior the other providers get in the same function. One `fetch(for:)` provider-strategy map would collapse both methods and equalize fallback semantics.
10. **APIAccessTest drift** — the "does the API work" diagnostic script tests Cursor via `https://cursor.com/api/usage` ([APIAccessTest.swift:432](scripts/APIAccessTest.swift:432)) while the app moved to `/api/usage-summary` ([CursorLocalService.swift:15](MeterBar/Services/CursorLocalService.swift:15)). The tool that exists to validate endpoints validates the wrong one. It also duplicates ~200 lines of keychain/DB/JWT plumbing (Cluster F). Note `MeterBarTests/APIIntegrationTests.swift` already covers the same ground *using the real services* — the standalone script + [test-api-access.sh](scripts/test-api-access.sh) are candidates for deletion in favor of the test target.
11. **Trivial over-abstractions to delete, not generalize** — `SettingsDivider` ([SettingsView.swift:625-629](MeterBar/Views/SettingsView.swift:625)) wraps `Divider()` verbatim; `cardSurface()`/`dashboardCardBackground()` are two private aliases of `meterBarCardSurface` (harmless but one name would do); `Color.adaptive`'s `lightHighContrast`/`darkHighContrast` params ([MeterBarTheme.swift:90-107](MeterBar/Views/MeterBarTheme.swift:90)) are never passed by any caller — speculative generality.
12. **UserDefaults keys as scattered literals** — `"refreshInterval"`, `"cached_usage_metrics"`, `"HiddenProviderServices"`, `"ShowMeterBarInDock"`, `"ClaudeCodeEnableOAuthFallback"`, `"ClaudeCodeCustomAccounts"` each declared inline in a different file. One `StorageKeys` namespace prevents the classic typo'd-key cache bug and documents the persistence surface. SwiftLint's `file_length`/`type_body_length` disabled rules ([.swiftlint.yml:17-23](.swiftlint.yml:17)) are what allow 1,600-line view files — consider per-file `swiftlint:disable` instead of global.

---

## 5. Recommended shared modules / components

Only abstractions that remove real, demonstrated complexity:

### 5.1 `MeterBarKit` (shared framework target) — the big one
Members: `ServiceType`, `UsageMetrics`, `UsageLimit` (+ `UsagePace`, `UsageDurationText`), `ExtraUsageStatus`, `UsageFormat`, a single `QuotaBands` severity definition (one `percentLeft(for:)`, one band enum with `color`/`label`/`icon`), `SharedMetricsStore` (app-group read/write + the String-keyed map codec), and the `TokenPricing` table.
Consumers: app, widget, CLI (and `render-readme-screenshots` if kept). Kills Clusters A, E, F.3, F.6 and finding §3.8-11 simultaneously. This is target-membership work in `MeterBar.xcodeproj` plus making `MeterBarCLI` consume it (either fold the CLI into the root package as a second product, or vend MeterBarKit as a local SPM dependency).

### 5.2 `ProviderSnapshot` view-model (app target)
One snapshot/limit type + one builder (provider ordering, Claude multi-account titles, empty-state copy, third-limit label rule, `primaryLimit`) consumed by popover, dashboard, and `AppDelegate.mostConstrainedPrimaryLimit`. Kills Cluster D's logic duplication and the popover/menu-bar rounding disagreement. Status copy ("Quota is tight", "Critical") moves next to `QuotaBands` so icon/color/text always agree.

### 5.3 `Views/Components/` extraction (mechanical move)
Move `UsageBar`, `ProviderLogoView`+`ProviderLogoKind`+`ProviderLogoImageCache`, `ExtraUsageStatusPill`, `ResetCountdownLabel`/`NextResetCountdownLabel`/`BlockingLimitResetCounter`, `RefreshingIcon` out of `MenuBarView.swift` into a components directory. No behavior change; makes the design system discoverable and shrinks MenuBarView to the actual popover.

### 5.4 `ServiceSupport` completion (not a new abstraction — finish the existing one)
- Make the local services use `fetchDecoded` (add a `validate`-only variant for the two that need custom headers/published-state side effects), and pass the configured session explicitly everywhere so admin + local services share timeout behavior.
- Add `JWT.payloadDate(_:)`/`JWT.claim(_:)` beside `OAuthTokenExpiry` and point `CursorLocalService.extractUserIdFromJWT` at it.
- Add `ISO8601.parseFlexible(_:)` (fractional→plain fallback) used by CostTracker + CursorLocalService.

### 5.5 Explicit non-recommendations
- **Do not** build a `SQLiteReader` abstraction for two call sites — revisit at a third reader.
- **Do not** generalize `ProviderVisibilityStore`/`DockVisibilityStore` into a generic settings store — they're small, clear, and differently shaped.
- **Do** delete rather than generalize: `SettingsDivider`, the `Color.adaptive` high-contrast params, `selectedStatus`'s tuple.

---

## 6. Refactor roadmap (ordered by ROI)

| # | Work item | Effort | Payoff |
|---|---|---|---|
| 1 | **Mechanical deletes + doc fixes**: §3 items 1-7, 12-14, 17 dead symbols/files; fix `.agent/` → `.agents/` in the three agent docs; fix README badges/claims | S | Removes ~700 lines of misleading surface; zero behavior change |
| 2 | **CI hardening**: drop `|| echo` from ci.yml test step; wire `check-coverage.sh` into CI | S | Every later refactor is only safe if tests can actually fail CI — do this first among behavior-touching work |
| 3 | **`QuotaBands` + single `percentLeft`** (app-local first, moves to Kit later): replace the 3 `percentLeft` copies and 4 threshold schemes; adopt in notifications + CLI | M | Ends cross-surface severity disagreement — the most user-visible inconsistency |
| 4 | **`ProviderSnapshot` unification** (§5.2) + component extraction (§5.3) | M | Deletes ~400 duplicated view-logic lines; fixes inverted Sonnet/Code-Review labels and string-matched icon/pace derivation |
| 5 | **`MeterBarKit`** (§5.1): models + formatting + shared store first; widget adopts; CLI adopts second | L | Ends the 5-way model fork and the silent wire-format contract; the widget formatter/color drift disappears by construction |
| 6 | **CLI `cost` parity**: preferred — have the CLI read the app's cached `CostSummary` (`cost-summary-v1.json`) instead of re-scanning; fallback — port dedup/pricing/cutoff from CostTracker | M | `meterbar cost` stops contradicting the app |
| 7 | **Service pipeline completion** (§5.4): `fetchDecoded` adoption, shared session, error-message + `.parsingError` taxonomy fix, shared `checkAccess` apply helper, Claude Code async init | M | One place to change HTTP/auth/error behavior for all five providers |
| 8 | **CostTracker internals**: merge `calculateCost` into `calculateClaudeCost(…, oneHour: 0)` w/ consistent clamping; `realHomeDirectory()` in CostTracker + CLI; `StorageKeys` namespace | S-M | Correctness alignment + future-sandbox safety |
| 9 | **Decide `.claude`/`.openai` fate** (§3.16): render them or remove services+settings+AuthenticationManager | M | Either a feature ships or ~450 half-dead lines leave |
| 10 | **Scripts consolidation**: delete `APIAccessTest.swift` + `test-api-access.sh` in favor of `APIIntegrationTests`; either port `render-readme-screenshots` to import Kit views or replace with real-app screenshots; QuotaGuard→MeterBar renames in scripts/docs (leave keychain/app-group IDs alone) | M | Ends replica-UI screenshot drift and endpoint-drifted diagnostics |

Items 1-2 are a safe first PR. Items 3-5 are the structural core and should land in that order (bands → view-model → kit), since each reduces the surface the next one has to move.

---

## 7. Risk level & test coverage needed per refactor

| Roadmap item | Type | Risk | Existing coverage | Coverage needed before/with the change |
|---|---|---|---|---|
| 1. Mechanical deletes | Mechanical | **Low** — all targets unreferenced (grep-verified); deleting test-only symbols removes their tests too | n/a | Full build of app + widget + CLI targets (widget/CLI aren't covered by `swift test`) |
| 2. CI hardening | Mechanical | **Low** — may surface already-red tests; that's the point | [ci.yml](.github/workflows/ci.yml) | One green run on master before merging dependent PRs |
| 3. QuotaBands / percentLeft | **Semantic** — thresholds & rounding are user-visible; picking canonical bands changes some surfaces' colors/notification timing | **Medium** | [MeterBarThemeTests](MeterBarTests/MeterBarThemeTests.swift) covers `quotaStatusColor` bands | New: table-driven `QuotaBands` tests (band edges 0/10/25/80/90/100, rounding at fractional percents); notification-threshold test around `checkAndNotify` re-arm logic (currently untested) |
| 4. ProviderSnapshot + component moves | Mostly mechanical, some **semantic** (resolving the inverted Sonnet/Code-Review rule is a deliberate behavior pick) | **Medium** | [ResetCountdownTests](MeterBarTests/ResetCountdownTests.swift) covers countdown selection | New: snapshot-builder unit tests (multi-account titles, empty states, third-limit label per service, `primaryLimit` selection). Screenshot/manual pass on popover + dashboard |
| 5. MeterBarKit | **Semantic** at the wire boundary — Codable shape must stay byte-compatible with existing `cached_usage_metrics.json` | **High** | Model tests exist ([UsageLimitTests](MeterBarTests/UsageLimitTests.swift), [UsageMetricsTests](MeterBarTests/UsageMetricsTests.swift)) but no encode/decode golden tests | New: golden-file round-trip test against a captured current JSON payload (app-written → widget/CLI-decoded); widget decode test with missing optional keys; CLI integration smoke (`meterbar usage --json` against a fixture container) |
| 6. CLI cost parity | **Semantic** — numbers change (they become correct) | **Medium** | None — CLI has zero tests | New: fixture JSONL dir test asserting CLI total == CostTracker total; dedup regression test (same messageID+requestID twice) |
| 7. Service pipeline | **Semantic** — error copy & retry/session behavior changes | **Medium** | [APIIntegrationTests](MeterBarTests/APIIntegrationTests.swift) (cred-gated), [OAuthTokenExpiryTests](MeterBarTests/OAuthTokenExpiryTests.swift) | New: `fetchDecoded` unit tests with stubbed `URLProtocol` (401 → notAuthenticated + published-state, non-2xx message format, timeout mapping); one test per service asserting session config is the shared one |
| 8. CostTracker internals | Mostly mechanical; clamp alignment is a small **semantic** fix | **Low-Med** | **None — CostTracker parsing/pricing/dedup is currently untested** (biggest gap in the suite) | New before touching: fixture-based tests for `parseSessionFile` (dedup, cutoff, one-hour cache split), `claudePricing` model matching, `normalizeClaudeModel` |
| 9. Admin providers decision | **Semantic** (feature add or removal) | **Medium** — keychain data & Settings UI involved on removal | Settings flows untested | If removing: migration note (leave stored keys untouched); if wiring in: replace the `×1.5` manufactured totals first — bands are meaningless against fake totals |
| 10. Scripts consolidation | Mechanical | **Low** — scripts are dev-only | n/a | Manual: regenerate screenshots, run social-preview once |

**Overall test-suite gaps this audit exposed regardless of refactoring:** CostTracker (0 tests for ~1,000 lines of money math), the CLI target (0 tests), the widget target (0 tests), and notification threshold logic — these are the same places the duplication-drift bugs live, which is not a coincidence.
