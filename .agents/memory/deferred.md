---
last_verified: 2026-08-16
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

## Done — do not re-open as debt

MeterBarShared extraction. CI test/lint hard gates. View-file split of the old dashboard monolith. Signing/notarization. Aug 8 correctness batch (#374–#386, #422). Localization groundwork (#431). Burn-down widget family (#432). Burn-down widget catalog (#433). Costs dashboard MTD/rollup (#387). CodeRabbit rate-limit reporting (#434).
