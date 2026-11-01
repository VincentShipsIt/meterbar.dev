---
last_verified: 2026-11-01
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

## Shape and hierarchy

- Concentric corners: `Radius.shell` (24) minus the popover inset (`Spacing.md`, 12) equals `Radius.card` (12). Change one, change the others.
- Popover is **Tiles** (2026-11-01, Control Center style). The tightest measured provider is a wide hero tile; the rest share a two-column grid in display order (`PopoverTileLayout`). A blocked account with a banked reset keeps the full `ProviderStatusCard` so its reset-credit action stays reachable.
- Stay Awake and provider status are tiles under the providers (`PopoverControlTiles`). No glass pills. The bottom `safeAreaInset` is one plain text line: freshness left, refresh icon and "Open dashboard" right. `chromeHeight` is that line's height.
- Every figure names its direction: "52% left" / "48% used", never a bare percent. A bare number beside a ring was misread as usage.
- Right-click a tile: "Add to desktop as widget…" (macOS cannot place widgets itself; it explains the widget gallery and reloads timelines), "Float on screen" (an always-on-top panel, persisted, restored at launch), then the card commands.
- Tiles are content cards (`DashboardTile`, `Radius.card`), never nested inside another card. Hover window tiles are separate surfaces, not tiles inside a card.
- Hover details grow within the available screen height independently of the main popover cap. One shared viewport scrolls only overflowing content, so the final footer stays reachable.
- Usage hovers end with one compact footer: Extra usage and its read-only switch on the left, service health and its status-page link on the right, using the popover status monitor. Either side can appear alone; omit the footer when neither exists. Banked resets and peak/off-peak information remain above it.
- Labels, section headers, table column headers and status chips are sentence case, never `.uppercased()` / `.textCase(.uppercase)`. Share-card artwork is the exception.

## Color

Semantic system colors. Never fixed graphite hex.

Custom colors are **only** provider accents (`AccentCodex`, `AccentClaude`, `AccentCursor`) and quota status (`StatusHealthy` / `StatusWarning` / `StatusDanger`) in `Assets.xcassets` with Any/Dark + High Contrast. Use them on glyphs, meter fills, compact labels — never as surface themes. Large metrics stay `.primary` unless exhausted.

## Type and layout

System SF via SwiftUI font APIs. Regular or heavier on materials. Letter spacing zero. Do not scale type with viewport width.

- Companion: native `NavigationSplitView` sidebar `List`; content `ScrollView` ~22px padding.
- Settings: `Form` + `.formStyle(.grouped)`.
- Popover: one tile overview, not a tab strip.
- Usage bars are remaining-mode: full bar = 100% left. Red segment is the quota that should still exist if usage were on pace.

## Controls

SF Symbols for generic icons. Brand logos only via `ProviderLogoView`. Native button/toggle/field styles. At most one tinted / `.glassProminent` primary action. `ContentUnavailableView` for empty/error. Refresh in the toolbar. Gate retained animation on `accessibilityReduceMotion`.

Disabled providers stop fetching, leave popover and dashboard, leave the menu-bar percentage, and leave local cost estimates.

## Don’t

Force a color scheme. Fake-glass content cards. Generic SF provider icons when a logo exists. Web/shadcn/React. Heavy filesystem scans on first window presentation.
