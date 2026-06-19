---
version: beta
name: MeterBar Native Utility
description: Native macOS menu-bar utility for AI quota, usage, and local token spend, built on Liquid Glass.
platform:
  minimum: "macOS 26 (Tahoe)"
  appearance: "adaptive (light + dark); never force a color scheme"
principles:
  - "Glass is a system-owned chrome layer (menu bar, popover, toolbar, sidebar, floating controls). Never put glass in the content layer, never stack glass on glass, use it sparingly."
  - "Adopt by subtraction: use standard SwiftUI/AppKit containers and REMOVE custom backgrounds/materials/tints so the system supplies Liquid Glass automatically."
  - "Content uses semantic system colors and standard materials, not fixed hex. Foreground text/symbols on materials use vibrancy."
  - "Tint sparingly — only the single most important action. Provider/quota colors are semantic indicators, never surface washes."
colors:
  note: "Use semantic system colors so everything adapts to light/dark, accent, Increase Contrast, and Reduce Transparency. Do NOT define fixed graphite hex."
  text-primary: "Color.primary / NSColor.labelColor"
  text-secondary: "Color.secondary / NSColor.secondaryLabelColor"
  text-tertiary: ".tertiary"
  window-background: "Color(nsColor: .windowBackgroundColor)"
  content-surface: "Color(nsColor: .controlBackgroundColor)  # for non-grouped card fills"
  separator: "Color(nsColor: .separatorColor) / .quaternary"
  fill-subtle: ".quaternary  # tracks, inactive chips, zebra rows"
  accent: "Color.accentColor  # follows the user's system accent"
  # Brand + status accents are the ONLY custom colors. Define in Assets.xcassets
  # with Any/Dark + High-Contrast variants so they adapt.
  codex: "asset 'AccentCodex'  (cyan)"
  claude: "asset 'AccentClaude' (muted Anthropic orange)"
  cursor: "asset 'AccentCursor' (green)"
  success: ".green (asset 'StatusHealthy')"
  warning: ".yellow (asset 'StatusWarning')"
  danger: ".red (asset 'StatusDanger')"
typography:
  family: "system (SF) via SwiftUI Font APIs — never hardcode font names"
  title: ".title, semibold"
  section-title: ".title3 / .headline, semibold"
  body: ".body / .subheadline"
  label: ".caption, secondary"
  metric: ".system(size: ~24-26, weight: .bold) — primary text unless exhausted"
  note: "On materials use Regular/Medium/Semibold/Bold weights; thin glyphs lose legibility. Letter spacing is zero. Never scale text with viewport width."
rounded:
  note: "Prefer concentric / container-relative radii and Capsule over scattered fixed values. Native containers (List/GroupBox/Form) handle radii for you."
  control: ".rect(cornerRadius: 8, style: .continuous)"
  card: ".rect(cornerRadius: 12, style: .continuous) / GroupBox"
  pill-or-bar: "Capsule()"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "22px"
---

## Overview

MeterBar is a native macOS 26 utility, not a marketing surface. It should feel like a system app (Mail/Finder/System Settings): native containers, system materials, semantic colors, restrained accent. It has two surfaces:

- **Menu bar popover:** immediate quota health and fast refresh/dashboard access.
- **Companion window:** deeper limits, cost history, and settings, built on `NavigationSplitView`.

Both surfaces stay lean. Avoid decorative hero layouts, big nested cards, and explanatory copy that does not change the user's decision.

## How we adopt Liquid Glass

Liquid Glass is the system's **chrome layer** — the menu bar, the popover surface, toolbars, sidebars, and the occasional floating control. We get it for free by using standard components and **removing** custom chrome. The work is subtraction, not decoration:

- **Do not** paint popover/window backgrounds with a color + material. Let the system popover/window surface (and `NavigationSplitView` sidebar/toolbar) supply the glass.
- **Do not** wrap content cards in material + a manual hairline border ("fake glass"). Content is **not** a glass layer.
- **Never** stack a material over another material (glass-on-glass).
- For genuinely free-floating custom controls only, use a single `.glassEffect(.regular, in:)` inside a `GlassEffectContainer`. Use it sparingly.

## Colors

Use **semantic system colors** as the default so the UI adapts to light/dark, the user's accent, Increase Contrast, and Reduce Transparency. Never define fixed graphite hex for structural surfaces.

The only custom colors are **provider accents** (Codex cyan, Claude muted orange, Cursor green) and **quota status** (success/warning/danger). Define these in `Assets.xcassets` with light/dark + high-contrast variants. They are semantic indicators — used on glyphs, meter fills, and compact status labels — never as whole-surface themes. Large percentage and cost metrics use `.primary` text unless the value is exhausted.

## Typography

Native SF fonts via SwiftUI system font APIs. Keep text compact (see frontmatter). On materials, use Regular weight or heavier; avoid thin glyphs. Letter spacing is zero; never scale text with viewport width.

## Layout & Spacing

- Companion window: `NavigationSplitView` with a native `.sidebar` `List`; content in a `ScrollView` with ~22px padding; cards as `GroupBox`.
- Settings: native `Form` with `.formStyle(.grouped)` and `Section`s.
- Popover: a single dense overview (native `List`/`Section` or `GroupBox`), not a tab strip. Refresh/dashboard actions only.
- Repeated rows: 8–12px vertical spacing.

## Elevation & Depth

Depth comes from the system: the glass chrome layer floats above content, and content sits on system grouped/window backgrounds. Convey structure with standard materials, vibrancy, and spacing — not fixed dark surfaces, gradient orbs, or heavy shadows.

## Shapes

Prefer concentric / container-relative radii (`.rect(cornerRadius:style:.continuous)`, `ConcentricRectangle`, `containerShape`) and `Capsule` for bars/pills. Usage bars use a single clipped rounded (capsule) track so internal colored segments join seamlessly — never draw adjacent rounded segments that create cut-looking seams.

## Components

- Use SF Symbols for generic iconography (`Image(systemName:)`). Custom vector artwork is reserved for true brand logos via `ProviderLogoView`.
- Use native control styles: `.buttonStyle(.borderless/.bordered/.borderedProminent)`, `Button(role: .destructive)`, `.textFieldStyle(.roundedBorder)`, native `Toggle`, `LabeledContent`. Reserve at most one tinted/`.glassProminent` button for the primary action.
- Use `ContentUnavailableView` for empty/error/no-selection states and `ProgressView` for busy states.
- Refresh lives in the toolbar (`ToolbarItem(placement: .primaryAction)`), not a hand-animated custom button. Gate any retained animation on `accessibilityReduceMotion`.

Usage bars are remaining-mode:

- Full bar means 100% left; colored provider fill is current quota left.
- Red segment is the quota that should still exist if usage were on pace.
- Pace marker shows expected remaining unless the row is on pace.

Provider visibility belongs in companion Settings. Disabled providers must stop fetching, disappear from the popover and dashboard, stop affecting the menu bar percentage, and be excluded from local cost estimates.

## Do's and Don'ts

Do:

- Use native containers and let the system supply glass.
- Use semantic system colors and vibrancy; keep brand color to provider accents and quota status.
- Verify every surface in light and dark, and with Reduce Transparency, Increase Contrast, and Reduce Motion enabled.
- Use official provider logos; keep dashboards scan-friendly with aligned labels and values.

Don't:

- Force a color scheme, or paint fixed graphite backgrounds.
- Wrap content in fake-glass cards, or stack material on material.
- Use generic SF provider icons where bundled logos exist.
- Use web-only shadcn/Tailwind components or embed React in a web view.
- Auto-run heavy filesystem scans during initial window presentation.
