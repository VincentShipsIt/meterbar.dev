---
last_verified: 2026-09-29
status: active
---

# Deferred work

Only items that are still open. Shipped audit findings belong on GitHub, not here.

## Still open on the board

- **#389** — provider epic. Vincent lifted the 2026-09-12 deferral on 2026-09-29 and asked for the whole backlog. Kimi Code (#427), Z.ai/GLM (#428, with the peak/off-peak indicator), and GitHub Copilot (#429, bounded billing coverage) have implementations tracked on their respective issues. Close #389 only after all three land on `master` and acceptance evidence is recorded; implementation alone does not complete the epic. Antigravity stays on hold (no machine-readable quota API); Gemini CLI is out (Google forbids third-party reuse of its OAuth/backend).
- **#513** — local workload router epic. Phase 1 (contracts, pure router, `meterbar route`) implemented 2026-09-29, with original-five routing on the eight-provider tracking contract. Open: policy editor + routing preview (Phase 2 requires separate prepared approval), popover recommendation, `meterbar run` decision, HTTP/MCP exposure.

## Structural debt (no issue required to remember)

- **R6** — three build systems (Xcode app/widget, root SwiftPM tests, CLI package).
- **R8** — files still over 1k lines: `UsageDataManager.swift`, `CodexCostScanner.swift`, `WidgetSettingsView.swift`, `ProviderSettingsView.swift`. Split only when a feature has to touch them.
- **R5** — `ModelPricing` is a hardcoded table. Cursor still invents a 500-request total when the API omits one.
- No crash reporting. Intentional until someone asks.

## Done — do not re-open as debt

MeterBarShared extraction. CI test/lint hard gates. View-file split of the old dashboard monolith. Signing/notarization. Aug 8 correctness batch (#374–#386, #422). Localization groundwork (#431). Burn-down widget family (#432). Burn-down widget catalog (#433). Costs dashboard MTD/rollup (#387). CodeRabbit rate-limit reporting (#434). iCloud rollup retention pruning (#518).
