---
version: alpha
name: MeterBar Native Utility
description: Compact macOS utility UI for AI quota, usage, and local token spend.
colors:
  primary: "#F4F4F5"
  secondary: "#B4B4BC"
  muted: "#6B6B78"
  background: "#050607"
  surface: "#0C0D10"
  surface-elevated: "#131518"
  surface-hover: "#20232A"
  border: "rgba(255,255,255,0.10)"
  border-strong: "rgba(255,255,255,0.18)"
  accent: "#38BDF8"
  accent-foreground: "#050607"
  codex: "#45D6F0"
  claude: "#D97757"
  cursor: "#35E66B"
  success: "#10B981"
  warning: "#EAB308"
  danger: "#EF4444"
typography:
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Display, system-ui, sans-serif"
    fontSize: "28px"
    fontWeight: 650
    lineHeight: 1.15
    letterSpacing: "0px"
  section-title:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, system-ui, sans-serif"
    fontSize: "18px"
    fontWeight: 650
    lineHeight: 1.25
    letterSpacing: "0px"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: "0px"
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0px"
  metric:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Display, system-ui, sans-serif"
    fontSize: "24px"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "0px"
rounded:
  sm: "4px"
  md: "8px"
  lg: "10px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "22px"
components:
  panel:
    backgroundColor: "{colors.surface-elevated}"
    textColor: "{colors.primary}"
    rounded: "{rounded.md}"
    padding: "{spacing.lg}"
  sidebar-item:
    backgroundColor: "transparent"
    textColor: "{colors.secondary}"
    rounded: "{rounded.md}"
    padding: "8px 14px"
  sidebar-item-active:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.accent-foreground}"
    rounded: "{rounded.md}"
    padding: "8px 14px"
  usage-bar-track:
    backgroundColor: "rgba(255,255,255,0.16)"
    rounded: "{rounded.sm}"
    height: "7px"
  usage-bar-deficit:
    backgroundColor: "{colors.danger}"
    rounded: "{rounded.sm}"
    height: "7px"
  icon-button:
    backgroundColor: "{colors.surface-hover}"
    textColor: "{colors.primary}"
    rounded: "{rounded.md}"
    size: "32px"
---

## Overview

MeterBar is a native macOS utility, not a marketing surface. It should feel like a compact Shipcode sibling: dark graphite shell, low-opacity borders, tight controls, restrained accent color, and dense but readable quota information.

The app has two surfaces:

- Menu bar popover: immediate quota health and fast refresh/dashboard access.
- Companion window: deeper limits, cost history, and settings.

Both surfaces must stay lean. Avoid decorative hero layouts, big cards, nested panels, and explanatory copy that does not change the user's decision.

## Colors

Use Shipcode-style dark tokens as the default. Surfaces are near-black graphite with subtle elevation, not blue-purple gradients. Borders should remain quiet at 10-18% white.

Provider accents are semantic and stable:

- Codex: cyan.
- Claude: Anthropic orange `#d97757`.
- Cursor: green.
- Deficit: red only where quota is missing versus expected pace.
- Reserve: green only for positive pace state.

Do not let provider colors take over the whole UI. They are indicators, not themes.

## Typography

Use native SF fonts through SwiftUI system font APIs. Keep text compact:

- Dashboard title: `.title`, semibold, not `.largeTitle` unless it is the only focal point.
- Panel titles: title3/headline semibold.
- Row labels: subheadline semibold.
- Metadata: caption, secondary color.

Letter spacing is always zero. Do not scale text with viewport width.

## Layout & Spacing

Prefer a native utility layout:

- Sidebar width around 178-190px.
- Dashboard content padding around 22px.
- Card/panel padding around 14px.
- Repeated rows use 8-12px vertical spacing.
- Radius is usually 8px; 10px is the upper bound for companion-window panels.

The menu bar popover is denser than the companion app. It is a single all-in-one overview, not a provider tab strip.

## Elevation & Depth

Use macOS material sparingly for sidebars and popover chrome. Main content should rely on quiet dark surfaces and thin borders.

Avoid blurred decorative backgrounds, gradient orbs, and nested card stacks. Depth comes from material, border, and spacing, not heavy shadows.

## Shapes

Cards, tabs, and controls use 8px radius. Usage bars use a single clipped rounded track so internal colored segments join seamlessly. Never draw adjacent rounded segments that create cut-looking seams.

## Components

Provider labels use `ProviderLogoView` with bundled SVG assets. Do not fall back to generic terminal/system symbols when official provider artwork is available.

Usage bars are remaining-mode:

- Full bar means 100% left.
- Colored provider fill is current quota left.
- Red segment is the quota that should still exist if usage were on pace.
- Pace marker shows expected remaining unless the row is on pace.

Settings belong in the companion app. The popover should expose dashboard and refresh actions only.

Provider visibility belongs in companion Settings. Disabled providers must stop fetching, disappear from the menu popover and dashboard, stop affecting the menu bar percentage, and be excluded from local cost estimates.

## Do's and Don'ts

Do:

- Keep controls compact and native.
- Prefer one surface per purpose: popover for quick glance, companion for details/settings.
- Use official provider logos.
- Keep dashboards scan-friendly with aligned labels and values.
- Make expensive scans explicit or backgrounded so windows open immediately.

Don't:

- Use web-only shadcn components directly in SwiftUI.
- Embed React in a web view just to get Tailwind/shadcn styling.
- Use generic SF provider icons where bundled logos exist.
- Auto-run heavy filesystem scans during initial window presentation.
- Let deficit bars look like separated pills.
