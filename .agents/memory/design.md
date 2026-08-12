---
last_verified: 2026-08-12
status: active
---

# Design

Native macOS 26 utility. It should feel like Mail / Finder / System Settings: native containers, system materials, semantic colors, restrained accent.

## Surfaces

- Menu bar popover: immediate quota health, refresh, dashboard.
- Companion window: limits, costs, settings on `NavigationSplitView`.

Keep both lean. No decorative heroes, no nested-card theater, no copy that does not change a decision.

## Liquid Glass

Glass is the **chrome** layer (menu bar, popover, toolbar, sidebar, occasional floating control). Adopt by subtraction:

- Do not paint popover/window backgrounds. Let the system surface supply glass.
- Do not paint content cards with product-colored washes. Use `MeterBarTheme.Surface.content`.
- Content is not glass. Never stack material on material.
- For a genuinely free-floating custom control only: one `.glassEffect(.regular, in:)` inside a `GlassEffectContainer`.

## Color

Semantic system colors. Never fixed graphite hex.

Custom colors are **only** provider accents (`AccentCodex`, `AccentClaude`, `AccentCursor`) and quota status (`StatusHealthy` / `StatusWarning` / `StatusDanger`) in `Assets.xcassets` with Any/Dark + High Contrast. Use them on glyphs, meter fills, compact labels — never as surface themes. Large metrics stay `.primary` unless exhausted.

## Type and layout

System SF via SwiftUI font APIs. Regular or heavier on materials. Letter spacing zero. Do not scale type with viewport width.

- Companion: native `NavigationSplitView` sidebar `List`; content `ScrollView` ~22px padding.
- Settings: `Form` + `.formStyle(.grouped)`.
- Popover: one dense overview, not a tab strip.
- Usage bars are remaining-mode: full bar = 100% left. Red segment is the quota that should still exist if usage were on pace.

## Controls

SF Symbols for generic icons. Brand logos only via `ProviderLogoView`. Native button/toggle/field styles. At most one tinted / `.glassProminent` primary action. `ContentUnavailableView` for empty/error. Refresh in the toolbar. Gate retained animation on `accessibilityReduceMotion`.

Disabled providers stop fetching, leave popover and dashboard, leave the menu-bar percentage, and leave local cost estimates.

## Don’t

Force a color scheme. Fake-glass content cards. Generic SF provider icons when a logo exists. Web/shadcn/React. Heavy filesystem scans on first window presentation.
