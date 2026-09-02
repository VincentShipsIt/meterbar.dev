---
last_verified: 2026-09-02
status: active
---

# Deferred work

Only items that are still open. Shipped audit findings belong on GitHub, not here.

## Still open on the board

- **#389** / **#427** / **#428** / **#429** — next providers (Kimi, Z.ai/GLM, Copilot).

## Structural debt (no issue required to remember)

- **R6** — three build systems (Xcode app/widget, root SwiftPM tests, CLI package).
- **R8** — files still over 1k lines: `UsageDataManager.swift`, `CodexCostScanner.swift`, `WidgetSettingsView.swift`, `ProviderSettingsView.swift`. Split only when a feature has to touch them.
- **R5** — `ModelPricing` is a hardcoded table. Cursor still invents a 500-request total when the API omits one.
- No crash reporting. Intentional until someone asks.
- **iCloud rollup records are never pruned.** `CloudKitUsageRepository.synchronize` always passes `deleting: []`; only `removeDevice` deletes, and it deletes whole zones. Meanwhile `ICloudUsageAggregation.localRollups` only writes the local 30-day scan window and `fold` clips to `visibleDayCount = 30`, so every zone accumulates one record per (provider, local day) forever and a full resync downloads all of them to throw the old ones away. One provider for a year is ~365 dead records per zone; five is ~1,825. This — not launch frequency — is what would make the accepted one-full-resync-per-launch expensive, so it is the thing to fix rather than a persisted local cache (see [decisions.md](decisions.md)). PR #515 renamed rollups to `rollup-<provider>-<yyyy-MM-dd>`, so the stale set is derivable from record names without decoding. Deleting records from the user's iCloud is irreversible, so this needs an explicit go-ahead before it ships.

## Done — do not re-open as debt

MeterBarShared extraction. CI test/lint hard gates. View-file split of the old dashboard monolith. Signing/notarization. Aug 8 correctness batch (#374–#386, #422). Localization groundwork (#431). Burn-down widget family (#432). Burn-down widget catalog (#433). Costs dashboard MTD/rollup (#387). CodeRabbit rate-limit reporting (#434).
