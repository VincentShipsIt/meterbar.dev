---
last_verified: 2026-10-21
status: active
---

# Deferred work

Only items that are still open. Shipped audit findings belong on GitHub, not here.

Delivery state lives in the [GitHub issue queue](https://github.com/VincentShipsIt/meterbar.dev/issues), not a second checklist here. Integration boundaries are in [providers.md](providers.md).

## Structural debt (no issue required to remember)

- **R6** — three build systems (Xcode app/widget, root SwiftPM tests, CLI package).
- **R8** — files still over 1k lines: `UsageDataManager.swift`, `CodexCostScanner.swift`, `WidgetSettingsView.swift`, `ProviderSettingsView.swift`. Split only when a feature has to touch them.
- **R5** — `ModelPricing` is a hardcoded table. the legacy Cursor request-count source estimates a 500-request total when the API omits one, explicitly marked `isEstimated`.
- No crash reporting. Intentional until someone asks.
