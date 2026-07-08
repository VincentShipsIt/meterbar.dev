# UI Fix Brief — 2026-07-08

Audit of the toolbar popover + companion dashboard after the 07-07/07-08 sessions.
This is the contract for the next UI pass. Do ONE pass against this brief; do not
invent a new chrome approach mid-task. If something here conflicts with reality,
stop and report instead of improvising.

## Why the last 13 sessions looped (read first)

Sessions 1, 3, 4, 7, 8, 10, 11 (07-07) all reworked the same titlebar; sessions
5 and 6 flip-flopped glass on/off; session 8 set `titlebarAppearsTransparent = false`
and session 10 reverted it. Root cause: the dashboard window hand-rolls ALL of its
chrome — fake SwiftUI titlebar overlay, fake sidebar with manual width animation,
zero-safe-area hosting view hack, manual `layer.cornerRadius` clip — and every
session patched one symptom of that decision, which surfaced the next symptom.

**The fix is architectural, not cosmetic: go back to native AppKit/SwiftUI chrome
(NavigationSplitView + native toolbar) and let macOS 26 provide the Finder look,
the sidebar collapse, and the scroll-edge blur for free. Delete the hand-rolled
chrome instead of patching it.**

Current state (2026-07-08): the churn is committed as baseline `0da923c` on
branch `ui-fix-baseline`. ONE uncommitted, NON-COMPILING partial edit exists in
`MeterBar/Views/MenuBarDetailPanel.swift` (someone started A2/A4: changed
`present(anchor:preferredHeight:content:)` to `present(anchor:content:)` with
`fittingSize` measurement, but never updated the caller in `MenuBarView.swift:163`).
**First action: `git checkout -- MeterBar/Views/MenuBarDetailPanel.swift` to get
back to a compiling tree, then implement A2/A4 properly per this brief.**

---

## Part A — Toolbar popover (small, surgical fixes)

### A1. Secondary panel touches the primary panel
`MeterBar/Views/MenuBarDetailPanel.swift:47` positions the detail panel at
`x: anchorFrame.minX - width` — flush against the primary panel. Add a gap
constant (10pt) to `MeterBarMenuDetailPanelLayout` and use
`anchorFrame.minX - width - gap`. Keep the tops aligned as today.

### A2. Panel heights must fit content exactly — no clipping, no dead space
`MenuBarProviderDetailContent.preferredHeight(for:)`
(`MenuBarDetailPanel.swift:236-242`) estimates height with magic numbers
(`206 + count*84 + 106 + 52`). When it underestimates, `.clipped()` (line 44)
cuts content at the edge; when it overestimates (or `minDetailHeight: 260`
kicks in), the panel shows dead space below the content.

Fix: measure the real content instead of estimating —
- Render the content in the `NSHostingView`, fix its width to `detailWidth`,
  and use `fittingSize.height` (or a `GeometryReader` + `PreferenceKey`, the
  same pattern `MenuBarView` already uses via `MenuContentHeightPreferenceKey`)
  to size the panel.
- Delete `preferredHeight(for:)`, delete `.clipped()`, drop `minDetailHeight`
  (or lower it to ~120 as a floor for the empty state).
- Keep the screen-height cap; only if capped, fall back to the internal
  ScrollView (the `ViewThatFits` already does this) — indicators hidden.

### A3. No scrollbars in either panel
`MenuBarView.swift:60` — the primary panel's `ScrollView` shows indicators.
Add `.scrollIndicators(.hidden)`. Content-sized panels (A2) should make
scrolling a screen-height-cap fallback only.

### A4. Compact the headers
- Primary panel header (`MenuBarView.swift:114-146`): drop the decorative
  chart-line brand icon; keep only the dashboard + refresh icon buttons,
  right-aligned, and reduce the header to ~40pt. Update `chromeHeight`
  (`MenuBarView.swift:8`, hardcoded 56) to match — or better, measure it.
- Detail panel (`MenuBarDetailPanel.swift`): keep the provider name +
  "Open Full View" header, but DELETE the "Status / Updated" summary card
  (`summaryRow`, lines 203-229) — it duplicates what the primary card already
  shows. The detail panel should only add depth: per-window rows, reset
  counters, badges.

---

## Part B — Companion dashboard window (architectural)

### B1. Replace hand-rolled chrome with native NavigationSplitView
Target: Finder-like native window on macOS 26 (min deployment target is
macOS 26, Liquid Glass is available everywhere).

Delete:
- `MeterBarFullSizeHostingView` (safe-area hack), `UsageDashboardView.swift:7-13`
- `applyCompanionWindowRadius` manual corner clip, `UsageDashboardView.swift:60-65`
  (macOS 26 windows already have continuous rounded corners; masking to 14
  fights the native shape)
- the fake `dashboardTitlebar` overlay + `titlebarContentInset` padding
  (`UsageDashboardView.swift:214-251`, ZStack zIndex hack at 204-209)
- the manual sidebar (`sidebar`, `sidebarCollapseButton`, `DashboardSidebarRow`
  hover/selection painting with `Color.white.opacity` — broken in light mode)
- `MeterBarWindowChrome.titlebarContentInset`, `sidebarTitlebarWidth`,
  `collapsedSidebarWidth`, `MeterBarTitlebarGlass`,
  `MeterBarSidebarTitlebarBackground`, `MeterBarSidebarSurface`,
  `MeterBarSidebarBackground`, `MeterBarDashboardWindowBacking`

Build instead:
- `NavigationSplitView(columnVisibility:)` with the sidebar as a
  `List(selection:)` using `.listStyle(.sidebar)` — this gives the native
  translucent Finder-style sidebar, native row selection/hover, native
  collapse (system sidebar-toggle toolbar button, full collapse with
  animation — remove the custom icons-only 72pt rail entirely).
- Native toolbar: `.navigationTitle(activeSection.rawValue)` +
  `.navigationSubtitle(activeSection.titlebarSubtitle)`, refresh button as
  `ToolbarItem(placement: .primaryAction)`. Window keeps
  `.titled .closable .miniaturizable .resizable`; keep `fullSizeContentView`
  ONLY if the native toolbar needs content under it — default to NOT setting
  it and let AppKit manage the titlebar. Do not set `toolbar = nil`,
  `titleVisibility = .hidden`, or `titlebarAppearsTransparent` manually.

### B2. Scroll-under titlebar = native scroll-edge effect, not a painted strip
The current `MeterBarTitlebarGlass` is an always-on 48pt strip of
`.thinMaterial` + 0.58 solid dark tint → the "hardcut" transition. With the
native toolbar from B1, macOS 26 applies the progressive scroll-edge blur
automatically as content scrolls under the toolbar (tunable with
`.scrollEdgeEffectStyle(.soft, for: .top)`). At rest the titlebar is clean;
scrolled, it blurs gradually. Do not reimplement this with overlays.

### B3. Glassmorphism: follow the conventions, stop stacking tints
Current state: five different glass recipes (`MeterBarDetailBackground`,
`MeterBarSidebarBackground`, `MeterBarSidebarSurface`, `MeterBarTitlebarGlass`,
`MeterBarCompanionSurface`), each = material + a solid near-black overlay at
0.42–0.82 opacity + an accent gradient. The heavy solid tint kills the
material blur — that's why the app reads flat/dark instead of glass.

Conventions (macOS 26 / HIG):
- Backgrounds get standard materials only: sidebar gets its material from
  `.listStyle(.sidebar)`; the detail area can use
  `.containerBackground(.thinMaterial, for: .window)` or stay
  `windowBackgroundColor`. No solid tint layers above 0.2 opacity on top of
  a material; prefer no tint at all. The subtle brand gradient may stay at
  current opacities (≤0.15) if desired.
- `glassEffect(.regular, in:)` is for floating chrome/controls (the popover
  panels, buttons), NOT stacked on top of an `.ultraThinMaterial` fill
  (currently double-glassed in `MeterBarSidebarSurface`,
  `MeterBarTheme.swift:204-208`). One glass layer per surface.
- One card recipe: keep `meterBarCardSurface` / `MeterBarCompanionSurface`
  as THE card/panel surface; delete the redundant recipes listed in B1.
- Adaptive appearance is a hard requirement: kill hardcoded
  `MeterBarWindowChrome.color` (fixed near-black) as a window/light-mode
  background and every `Color.white.opacity(...)` selection/hover fill.
  Native `List` selection replaces the hand-painted sidebar row states.
  Verify every surface in BOTH light and dark mode plus
  Reduce Transparency before calling it done.

### B4. Remove the API Usage page
- Delete the `apiUsage` case from `DashboardSection` and its sidebar entry
  (`UsageDashboardView.swift:72, 88-89, 108-110, 461-477`).
- Move the org-admin-key spend into the **Costs** page as a trailing section,
  rendered only when `apiUsageStore.hasAnyAuthenticated`
  (`ApiUsageSection(store:embedded:)` already supports this). Label it
  "API spend (billed)" and keep it visually separate from the local-log
  estimates — one is real invoiced dollars, the other is an estimate; never
  sum them.
- API key entry/management lives in Settings → Accounts (it's already
  conceptually there; make sure the empty-state copy on Costs doesn't
  advertise it — subs-only users should never see an API empty state).
- Remove `ApiUsageSection` from the popover (`MenuBarView.swift:244`) — the
  popover is quota-at-a-glance only.

---

## Part C — Deep cleanup (verified findings; do alongside Part B)

### C1. Delete dead code (all verified unreferenced)
- `MeterBarDashboardWindowBacking` — `MeterBar/Views/MeterBarTheme.swift:145-161`
- `MeterBarSidebarBackground` — `MeterBarTheme.swift:163-189`
- `MeterBarSidebarTitlebarBackground` — `MeterBarTheme.swift:256-263`
  (only referenced from the dead view above)
- The ENTIRE `meterBarSurfaceStyle` environment plumbing —
  `MeterBarTheme.swift:295-297, 304-318` (`MeterBarSurfaceStyle`,
  `MeterBarSurfaceStyleKey`, private `EnvironmentValues` extension, View
  modifier) plus its two no-op call sites `MenuBarView.swift:39` and
  `MenuBarDetailPanel.swift:42`. It is WRITTEN but never READ — no
  `@Environment(\.meterBarSurfaceStyle)` exists anywhere. The session-5
  "toolbar vs dashboard surface split" it was built for never functioned.

### C2. Consolidate duplicates (behavior-preserving)
- `dashboardCardBackground(cornerRadius:)` (`DashboardCard.swift:99-105`) is a
  pure pass-through alias of `meterBarCardSurface`. Delete it and update the
  4 call sites (`DashboardCard.swift:34`, `MenuBarDetailPanel.swift:152/228/298`).
- `updatedText` is byte-identical in `ProviderOverviewStatusCard`
  (`DashboardProviderCards.swift:115`) and `ProviderLimitsCard` (`:164`) —
  hoist onto `ProviderSnapshot`.
- The exhausted-provider branch (`isEmpty / hasExhaustedWeeklyLimit →
  BlockingLimitResetCounter / else ForEach`) is duplicated verbatim at
  `DashboardProviderCards.swift:78-98` and `:137-152` — extract one view.
- `DailyUsageMetricCell` / `DailyUsageCostCell` (`DailyUsageChart.swift:553-575`)
  differ only by frame width — collapse into one cell with a width parameter.

### C3. CostTracker cleanup (`MeterBar/Services/CostTracker.swift`)
- Delete the six test-only shim methods at lines 196-263 (`parseSessionFile`,
  `claudePricing`, `normalizeClaudeModel`, `scanCodexArchivedSessions`,
  `calculateCost`, `calculateClaudeCost`) — zero production callers; they exist
  only so `CostTrackerTests` can call instance methods. Migrate the tests to
  the static `CostTracker.` calls instead.
- Remove the `nonisolated` keyword throughout — `CostTracker` is a plain class,
  not an actor, so every `nonisolated` in the file is a no-op that fakes
  actor-isolation. Keep `static`.
- Document (code comment) that `isLocalDirectory` intentionally skips
  network/mounted volumes so "my usage disappeared" reports are triaged fast.

### C4. Extra-usage indicator regression (`MeterBar/Services/ClaudeCodeLocalService.swift:236`)
The new `guard isOAuthFallbackEnabled else { return .unknown }` means every
normal user (fallback defaults to OFF) now permanently sees "unknown" for
Claude's Extra usage state — the on/off pill silently died. The keychain-prompt
motivation is valid, so keep the gate, but make the UI honest: when the state
is `.unknown` AND the fallback is disabled, HIDE the extra-usage row/badge
(popover, detail panel, settings pill) instead of rendering a dead "unknown"
indicator. Live usage metrics are unaffected (separate CLI path).

### C5. Light-mode fixes (beyond B3)
- `DashboardProviderCards.swift:18` — icon well changed from `.quaternary` to
  `Circle().fill(MeterBarTheme.glassCardTint)`; glassCardTint is a white-alpha
  overlay tint, near-invisible over a light card. Revert to `.quaternary`.
- After B1/B3, grep the codebase for `Color.white.opacity` and
  `MeterBarWindowChrome.color` — every survivor needs a semantic replacement.

### C6. Smaller debts
- `DailyUsageTableLayout` (`DailyUsageChart.swift:346-352`) hard-codes a
  ~668pt minimum table width; numeric cells only shrink to 75% then truncate.
  Acceptable for now at the 900pt min window — fix only if window min shrinks.
- `ProviderOverviewStatusCard` (`DashboardProviderCards.swift:46-58`): add
  `.accessibilityElement(children: .combine)` + an `.accessibilityLabel` so
  VoiceOver reads one named button, not an untitled group.
- Delete stale `MeterBar/Info.plist` (dead file, hardcodes version 1.0;
  generated plist wins — remainder of issue #20).
- Issue #86: one unresolved CodeRabbit thread on
  `MeterBar/Services/AccountActivityInspector.swift:52` from PR #85 — verify
  against master and resolve while in there.

---

## Suggested run order (budget-aware)

1. Revert the non-compiling partial edit (see "Current state" above).
2. **Part A** (popover) + C4 + C5 first — small, high-visibility, cheap to verify.
3. **Part B** (native chrome rewrite) + C1 (most dead code IS the old chrome).
4. **C2/C3/C6** cleanup pass, then release chores.

Commit each step separately on top of `ui-fix-baseline` so any step can be
reverted alone.

---

## Acceptance criteria (verify each, in the running app)

Popover:
- [ ] Secondary panel has a visible ~10pt gap from the primary panel; tops aligned.
- [ ] Neither panel ever shows a scrollbar; both hug their content height
      exactly (no clipped bottom edge, no dead space) for: provider with 1
      window, 2 windows, exhausted provider, provider with no data.
- [ ] Primary header is a single compact row (no brand icon); detail panel
      has no Status/Updated card.

Dashboard:
- [ ] Window uses a native toolbar + native sidebar; the system sidebar
      toggle collapses/expands with the standard animation (no icon rail).
- [ ] At rest, no visible titlebar strip; scrolling content blurs
      progressively under the toolbar (no hard edge).
- [ ] Sidebar looks/behaves like Finder's: native material, native selection
      highlight, correct in light AND dark mode and with Reduce Transparency.
- [ ] No `safeAreaRect`/`safeAreaInsets` overrides, no manual layer corner
      radius, no fake titlebar views left in the codebase.
- [ ] Sidebar has no "API Usage" item; Costs shows the API spend section only
      when an admin key is authenticated; popover has no API section.

Cleanup:
- [ ] Grep proves zero references to: MeterBarDashboardWindowBacking,
      MeterBarSidebarBackground, MeterBarSidebarTitlebarBackground,
      MeterBarSurfaceStyle, meterBarSurfaceStyle, dashboardCardBackground,
      preferredHeight(for:), and the six CostTracker shims.
- [ ] Claude Extra-usage row is hidden (not "unknown") when OAuth fallback is
      disabled; shows real on/off when enabled.
- [ ] `swift test` passes (including migrated CostTrackerTests); Release build
      succeeds.

Non-goals: do not touch the data layer, providers, cost scanning, snapshot
builders, or card content/copy beyond what's listed. Do not redesign cards.
Do not add new surface recipes.

---

## Part D — Quality pass on sessions 6–13 output (added after audit #4)

DRY fixes, all small and behavior-preserving:

1. Delete `OverviewSummaryTile` (private, bottom of `UsageDashboardView.swift`)
   — it clones `DashboardMetricTile` (`DashboardCard.swift:69-97`) with the
   same props and anatomy. Extend `DashboardMetricTile` with an optional
   size/style variant (value font, spacing, minHeight, lineLimit/minScale)
   and use it in `OverviewSummaryStrip`.
2. `configurePanelClipping(_:)` is duplicated byte-for-byte in
   `MeterBar/App/MeterBarMenuPanelController.swift` and
   `MeterBar/Views/MenuBarDetailPanel.swift`. Extract ONE shared helper
   (e.g. `extension NSPanel { func applyCompanionClipping() }`) driven by
   `MeterBarTheme.companionShellRadius`.
3. `SettingsView.swift`: the path-pill view (~line 1055) hand-inlines the same
   thinMaterial + glassCardStroke recipe as `SettingsInputModifier`; reuse
   `settingsInput()` or extract the surface part of the modifier. Also fold
   the one-off material capsule at ~line 951 into the same helper if visually
   identical.
4. Window chrome is configured twice (creation in
   `UsageDashboardWindowController.show()` and updates in the
   `MeterBarMenuWindowAccessor` callback) — title, subtitle, titleVisibility,
   toolbarStyle in both. Extract `applyWindowChrome(_ window:, section:)` and
   call it from both sites.

Acceptance: grep shows one `DashboardMetricTile`-based tile family, one
panel-clipping helper, zero inline thinMaterial recipes in SettingsView
outside the shared modifier, and window title/toolbar config written in
exactly one function. `swift test` + Release build still pass.

Deferred (post-release, do NOT do now): split `SettingsView.swift` (~1,100
lines) and `UsageDashboardView.swift` (~890 lines) into per-section files.
