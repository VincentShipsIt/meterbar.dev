# Issue backlog — verified state + implementation specs

**Audited:** 2026-07-03 against `master` @ `3991b1d` (post-#74 integration, latest release `v1.6`).
Every open issue and PR was checked against the *actual* code, not its description.
This is the hand-off doc for the implementation pass: work top-to-bottom within each tier.

Context that invalidates several issue bodies: [#74](https://github.com/VincentShipsIt/meterbar.app/pull/74)
merged the content of PRs #63/#64/#65/#66/#69/#70 in one integration commit, but those six PRs
were **closed, not merged** — so their `Closes #N` triggers never fired and several "open"
issues are already done.

---

## Tier 0 — Hygiene (no code, do first)

### Close as done/obsolete
| Issue | Why |
|---|---|
| [#17](https://github.com/VincentShipsIt/meterbar.app/issues/17) CI hard-fail + coverage | Done via #66→#74. `ci.yml` has no `\|\| echo` masking; `scripts/check-coverage.sh` gates at `COVERAGE_THRESHOLD: 8`; SwiftLint `--strict` enforced. Only unshipped fragment: no daily `schedule:` run — folded into #18's spec below. |
| [#24](https://github.com/VincentShipsIt/meterbar.app/issues/24) docs truth-sync | Done via #66→#74. README badges, setup, non-sandboxed posture, CLI docs all verified accurate. `.agents/SYSTEM/ARCHITECTURE.md` rewritten 2026-07-02. |
| [#21](https://github.com/VincentShipsIt/meterbar.app/issues/21) v1.5.1 version alignment | Superseded — `v1.6` shipped. `MARKETING_VERSION = 1.6` consistent across all 4 pbxproj instances; `release.yml:48-59` blocks releases on app↔CLI version drift; Homebrew cask auto-updated by `update-homebrew.yml`. |
| [#28](https://github.com/VincentShipsIt/meterbar.app/issues/28) print → Logger | Done. Zero `print(` in `MeterBar/` + `MeterBarWidget/`; `AppLog` (os.Logger) abstraction exists; custom SwiftLint rule `no_print_statements` enforces it. CLI `print` calls are legitimate stdout output, correctly out of lint scope. |

### Rewrite issue bodies (stale claims)
- **[#71](https://github.com/VincentShipsIt/meterbar.app/issues/71) post-audit queue** — "#69/#70 in review, merge-order warning" is moot; both landed via #74. Remaining live items: service-layer tests + coverage ratchet (see Tier 3), signing (#47, stays deferred). Note: #71 claims "View-file split (R8) — #70 landed", but `UsageDashboardView.swift` is still a 1539-line monolith — R8 is *not* finished for that file.
- **[#13](https://github.com/VincentShipsIt/meterbar.app/issues/13)** — half done. `WidgetCenter.reloadTimelines` IS called (`SharedDataStore.swift:42-49,61-67`). Remaining scope is only the duplicate widget-side store (Tier 1 below).
- **[#40](https://github.com/VincentShipsIt/meterbar.app/issues/40)** — the `secondaryWindow!` force-unwrap is already fixed (`CodexCliLocalService.swift:154-159`). Remaining: dashboard badges + function split (Tier 1).
- **[#26](https://github.com/VincentShipsIt/meterbar.app/issues/26)** — mostly done. `meterbar cost` reports Claude+Codex (via the app's cached `CostSummaryStore`) and supports `--json`. Remaining: `--days` (Tier 1).
- **[#23](https://github.com/VincentShipsIt/meterbar.app/issues/23)** — dedup/cooldown already implemented (`MeterBarApp.swift:271-311`, band-crossing keyed `notifiedLimitKeys`). Remaining: user preferences (Tier 2).
- **[#29](https://github.com/VincentShipsIt/meterbar.app/issues/29)** — wire-format contract tests exist (`CachedMetricsContractTests`, `CachedMetricsReplicaContractTests`) and reload-on-write is verified. Remaining: widget *rendering* validation — merged into #18's spec (Tier 3).
- **[#31](https://github.com/VincentShipsIt/meterbar.app/issues/31) website refactor** — **unactionable in this repo.** The meterbar.app site source is not here (no `website/` dir, no gh-pages branch, no separate GitHub repo under VincentShipsIt). Either transfer the issue to wherever the site lives or add the location to the issue body. Do not start it from this repo.
- **[#47](https://github.com/VincentShipsIt/meterbar.app/issues/47) signing/notarization** — keep deferred as labeled. Body is accurate and self-contained; no action.

---

## Tier 1 — Small, well-scoped fixes (batch into one PR)

### 1a. Finish widget `SharedDataStore` unification (remainder of #13)
`MeterBarWidget/UsageWidget.swift:19-41` still defines its own private `class SharedDataStore`
with duplicated app-group/metrics-key string literals, even though it already imports
`MeterBarShared` and uses `MetricsCodec.decode`.
- Move a read-only store (or at least the `appGroupIdentifier` / `metricsKey` constants) into
  `Packages/MeterBarShared` (e.g. `StorageKeys`), and make the widget consume it.
- The app-side `MeterBar/Services/SharedDataStore.swift` keeps the write path +
  `reloadWidgetTimelines()`; only the constants/decode path should be shared.
- Test: extend the existing contract tests to read via the shared constants so a key rename
  breaks CI.

### 1b. Dashboard badge parity (remainder of #40)
Popover provider cards show two badges the dashboard cards lack:
- "N reset(s) available" — `MenuBarView.swift:305-320` (`snapshot.resetCreditsAvailable`)
- "Extra usage" pill — `MenuBarView.swift:322-333` (`snapshot.extraUsage`, `ExtraUsageStatusPill`)

Add both to the dashboard provider cards in `UsageDashboardView.swift` (~lines 488-540, 630-663).
`ProviderSnapshot` already carries both fields — view-only change. **DRY requirement:** extract the
badge row into a shared component under `MeterBar/Views/Components/` used by both surfaces;
do not copy-paste the popover implementation.

### 1c. Split `CodexCliLocalService.fetchUsageMetrics()` (remainder of #40)
Still one ~112-line function (`CodexCliLocalService.swift:81-192`): request build + headers +
decode + mapping of three `UsageLimit`s inline. Extract the response→`UsageMetrics` mapping into
a pure helper and unit-test it with a fixture JSON (this also chips at the untested-service gap).

### 1d. `meterbar cost --days N` (remainder of #26)
Add `@Option var days: Int?` to the `Cost` subcommand (`MeterBarCLI/Sources/MeterBarCLI.swift:164-226`).
The cached `CostSummaryStore` carries daily breakdowns — filter the cached daily entries to the
window rather than triggering a rescan. If the cache's `periodDays` is smaller than the request,
say so in the output instead of silently under-reporting.

### 1e. Delete stale `MeterBar/Info.plist` (remainder of #20)
The build uses `GENERATE_INFOPLIST_FILE = YES`; the checked-in `MeterBar/Info.plist` is dead
weight that hardcodes `CFBundleShortVersionString = 1.0` (vs actual 1.6) — the R9 inconsistency
from the audit. Delete it (verify nothing references it via `INFOPLIST_FILE` — confirmed absent)
and close #20 noting the remaining nice-to-have (a local `scripts/package.sh` mirroring
`release.yml`'s inline packaging steps) if not doing it.

### 1f. Finish R8: split `UsageDashboardView.swift`
1539 lines, single struct, despite #70 "view split" having landed. Split per-type like the
existing `ApiUsageCard.swift` / `RefreshingIcon.swift` / `ProviderSnapshot.swift` precedents
(dashboard provider card, section chrome, cost views, etc.). **Do this before or together with
the PR #73 rework (Tier 4) — otherwise #73 re-appends ~500 lines to the monolith.**
`SettingsView.swift` (808 lines) is the next candidate but lower priority.

---

## Tier 2 — Features with a shared core

### 2a. Provider readiness core → powers #22 (onboarding) + #25 (diagnostics/doctor)
These two issues are one feature with three surfaces. Build the core once:

`ProviderReadiness` service (new, in `MeterBar/Services/`, pure/testable):
per provider (Claude Code, Codex CLI, Cursor) evaluate ordered checks —
installed (CLI on PATH / app present) → auth present (`claude` login state, `~/.codex/auth.json`
+ token expiry via existing `OAuthTokenExpiry`, Cursor DB readable) → data readable →
last refresh result/error. Output: `pass/warn/fail` + plain-language recovery action
(`claude login`, `codex login`, open Cursor, rescan). Redact all secret values.

Surfaces, in build order:
1. **`meterbar doctor`** CLI subcommand (#25) — cheapest UI, exercises the core end-to-end.
   Reuse the CLI's existing output/JSON conventions. Output must be safe to paste into an issue.
2. **Diagnostics view** in the app (#25) — renders the same check results; add to Settings or
   dashboard nav.
3. **First-run/empty-state checklist** (#22) — the current "Not Connected" empty state renders
   the same per-provider checks with recovery actions; collapses once providers are healthy.

Caveat: the CLI target can't link app-only code — put the readiness logic in `MeterBarShared`
(or a new shared target) so app + CLI genuinely share it, mirroring how metrics types were unified.
Tests: fixture-driven unit tests per check (missing auth file, expired token, unreadable DB, etc.).

### 2b. Notification preferences (remainder of #23)
Keep the existing band-crossing dedup. Add to Settings (persist via the existing settings
storage pattern in `SettingsView.swift`):
- Global notifications on/off.
- Warning/critical threshold selection — wire into `QuotaBand.forLimit` evaluation rather than
  a parallel threshold path (the bands are in `MeterBarShared/QuotaBands.swift`).
- Skip notifications for disabled providers (check current provider-enable flags before notify).
- No notification from stale cached data (compare metric timestamp before firing).
Tests: threshold-crossing matrix on a pure decision function extracted from `checkAndNotify`.

### 2c. Launch at Login (#27)
Small, standalone: `SMAppService.mainApp` register/unregister toggle in Settings, reflect
`SMAppService.mainApp.status` on appear (it can change behind the app's back in
System Settings), surface registration errors inline. One settings row + a thin service wrapper;
unit-test the wrapper with a protocol seam.

---

## Tier 3 — Test hardening (from #71 + #18 + #29)

### 3a. Service-layer tests + coverage ratchet
Confirmed untested at HEAD: `UsageDataManager` (zero refs in tests), `KeychainManager` (zero),
`CursorLocalService`/`CodexCliLocalService` (only credential-gated `XCTSkip` integration tests),
`CostTracker` orchestration (only pure slices tested), `SharedDataStore` I/O path (contract-level only).
- Add seams (protocol injection for file I/O, process exec, keychain) — follow the existing
  fixture patterns in `CostTrackerTests` / contract tests.
- After each batch lands, raise `COVERAGE_THRESHOLD` in `.github/workflows/ci.yml` to just
  under the new measured baseline. Never lower it.

### 3b. UI/e2e smoke suite (#18, absorbs the rest of #29)
Nothing exists: no XCUITest target, no app scheme even checked in (only
`MeterBarWidgetExtension.xcscheme`). Spec:
- Add a shared `MeterBar` scheme + XCUITest target.
- First flow (from the issue): launch app → inject fixture usage data → open popover/settings →
  change refresh interval → assert persistence + shared-data update.
- Widget rendering validation (#29's remainder): fixture-driven checks that small/medium/large
  widget views render non-empty for Claude/Codex/Cursor fixture metrics — snapshot or
  view-model-level assertions are acceptable if full widget UI automation is impractical; plus a
  short manual QA checklist (empty/error/populated/stale states) in `.agents/docs/TESTING.md`.
- CI: run a deterministic subset on PRs + add the repo's **first `schedule:` workflow** — daily
  e2e + coverage run (also satisfies the scheduled-run fragments of #17/#18). No credentials;
  fixtures only. Note macOS runner cost: daily, not per-push.

---

## Tier 4 — Product features

### 4a. Rework PR #73 (social share card) — do NOT merge as-is
[PR #73](https://github.com/VincentShipsIt/meterbar.app/pull/73) is `CONFLICTING` with master
(branched pre-#74). CI green is misleading — it hasn't seen master's refactor. Verified findings:
- **Keep unchanged:** `MeterBar/Models/SocialShareCardContent.swift` (~170-line pure model) +
  `SocialShareCardContentTests.swift` (5 solid tests). Clean, no privacy leaks (token totals,
  public provider display names, repo URL only), correct UTC filename handling, correct
  main-thread `ImageRenderer` usage.
- **Rework the dashboard glue:** the PR re-derives `tightestDashboardLimit` with its own local
  `DashboardProviderSnapshot`/`DashboardLimit` structs — master already provides exactly this as
  `providerSnapshots.tightestLimit` (`MeterBar/Views/ProviderSnapshot.swift:188`, `SnapshotLimit`).
  Use the canonical API; do not reintroduce the parallel types #74 consolidated away.
- **Extract, don't append:** the PR appends ~500 lines (8 private view types + handlers) to
  `UsageDashboardView.swift`. Land the card views in their own file(s)
  (`MeterBar/Views/SocialShareCard.swift`), per Tier 1f.
- **Optional DRY:** `SocialShareTokenChart` hand-rolls a second bar chart next to the existing
  `DailyUsageChart` (`UsageDashboardView.swift:307`). Compose/theme the existing one, or keep the
  branded variant deliberately — decide, don't drift.
- Trivial conflict in `.agents/SESSIONS/2026-07-02.md` (both sides added it) — merge both entries.
- Estimated 1–2 h rebase/rework, not a rewrite.

### 4b. Token optimization insights page (#72)
Issue body is well-specified and current (written 2026-07-02, aware of `CostTracker`'s existing
breakdowns). Analytics/UI layer over existing local data — no pipeline changes:
- New dashboard nav section (post-Tier-1f file layout: own view file from day one).
- KPIs from `CostTracker` summary: token burn by model (7/30d), premium-model share,
  input/output ratio, cache-efficiency (creation vs reuse), top sessions/projects.
- Plain-English recommendations computed locally from usage metadata only (privacy boundary:
  no prompt contents, nothing uploaded).
- Pure recommendation-engine functions in a model file with unit tests (same pattern as
  `SocialShareCardContent`).
- Empty/loading states explain how to run a local scan.

---

## Dependency notes for sequencing

- Tier 1f (dashboard split) **before** 4a and 4b — both land new dashboard sections.
- 2a core **before** its three surfaces; CLI surface first.
- 3a can proceed anytime; 3b after 1a (widget store unification changes what fixtures target).
- #47 stays deferred; nothing in this backlog depends on signing.
