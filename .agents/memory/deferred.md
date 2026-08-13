---
last_verified: 2026-08-12
status: active
---

# Deferred work

Only items that are still open. Shipped audit findings belong on GitHub, not here.

## Still open on the board

- **#387** — Costs dashboard month-to-date picker, provider-independent model rollup, `cost --json` top-level rollup, serve `/cost` MTD.
- **#389** / **#427** / **#428** / **#429** — next providers (Kimi, Z.ai/GLM, Copilot).
- **#433** — burn-down widget strings into the widget catalog (this branch).
- **#434** — CodeRabbit rate-limit must not report pass.

## Structural debt (no issue required to remember)

- **R6** — three build systems (Xcode app/widget, root SwiftPM tests, CLI package).
- **R8** — files still over 1k lines: `UsageDataManager.swift`, `CodexCostScanner.swift`, `WidgetSettingsView.swift`, `ProviderSettingsView.swift`. Split only when a feature has to touch them.
- **R5** — `ModelPricing` is a hardcoded table. Cursor still invents a 500-request total when the API omits one.
- No crash reporting. Intentional until someone asks.

## Done — do not re-open as debt

MeterBarShared extraction. CI test/lint hard gates. View-file split of the old dashboard monolith. Signing/notarization. Aug 8 correctness batch (#374–#386, #422). Localization groundwork (#431). Burn-down widget family (#432).
