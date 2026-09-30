# MeterBar recovery visual evidence — 2026-09-30

Author: Codex / GPT-6, OpenAI. Synthetic data only; no installed app, account payload, UI automation or live screen capture.

## Pinned sources

- PR #601 repaired Usage source: `66d9377566b9a92be1624ef9b9cf435e11f99af3`. Usage PNGs are real `DashboardUsageSection`/Limits views from the full-Xcode compiled module, using `DemoData` in the existing `CostsPageSnapshotRenderTests`. The extra boundary harness measures widths 834 and 1000. At 834 the main column is 520 points; Daily Details is contained within its horizontal scroll viewport and all columns remain in the content.
- PR #603 before: actual baseline `ede52a7fd16e827ab336a1f2d72ad306302cf970`.
- PR #603 after: exact head `6c54400fae64f1d0b8320010039ecae4f3b1dc7b`. Its source was not edited.
- Rendering host: Mac Studio, macOS 27.0.1, Xcode 27.0; full-Xcode SwiftPM builds, NSHostingView and offscreen NSWindow, never ordered on screen.

## #603 fixture method

`dashboard-overview` instantiates the actual DashboardOverviewSection with five fixed synthetic provider snapshots, no account IDs, timestamps or reset timers, and no cost scan. It checks the rendered casing, cards and typography. `settings-components` composes actual SettingsPanelSection/SettingsRowView components with constant controls; it is not a full Settings window. `icon-template` uses actual MenuBarIconRenderer images inside a synthetic material strip; it is not NSStatusItem or the system menu bar.

The popover harness extracts the actual MenuBarView mainColumn/header and status-dot view body from each pinned source. Only data/actions are replaced: fixed provider cards using real DashboardTile/ProviderCardHeader/LimitRow; a constant Stay Awake toggle; Session Wake omitted; fixed operational status dots; no refresh task, stores or monitors. The Python generator and resulting Swift harnesses are included so these fixture substitutions are reviewable. Actual production layout and theme methods are compiled from each source tree.

## Limitations — required native acceptance remains open

The offscreen renderer cannot capture the native visual-effect/compositor surfaces honestly. Before/after popover images are **diagnostics, not acceptance screenshots**: both chrome backgrounds are black; dark baseline cards have an incorrect white material; the after safeAreaBar scroll content does not rasterize. These artifacts do not establish a product defect because the detached render lacks a real visible compositor hierarchy. No workaround removed or replaced production safeAreaBar/glass in order to manufacture a passing image.

Settings content and icon templates are captured, but native switch state/tint, glass button contrast, full Settings/dashboard window chrome, actual NSStatusItem surroundings, hover, keyboard handling, scrolling under the floating bar, and popover system backdrop remain unverified. In particular, light-mode refresh glass appears faint in this capture. No claim is made that this represents its on-screen rendering.

The oldest supported macOS 26 runtime is not installed on this host. Existing CI at the original exact #603 head was green on macOS 26, and 56 focused real XCTest cases pass locally; that does not prove native on-screen visual acceptance. Required popover/menu-bar/system-chrome verification remains a blocker until an authorized native runtime review is available.

## #601 verification

Five new regressions were observed failing before repair: unavailable premium signal with mixed legacy attribution, common totals for saturated stacks, bounded inconsistent attribution, actual origin date containment, and a fully covered saturated trend with truthful baseline copy. 181 focused real XCTest cases pass after repair (with snapshots enabled); strict SwiftLint reports zero violations; real Debug app/widget and CLI builds pass; git diff --check is clean. Native runtime acceptance and final independent different-lab review remain separate gates. The new-head historical Secret Scan failure is documented on issue #593; it is not suppressed in these artifacts.

## Files

- `601/`: repaired Usage wide/narrow, 834/1000 boundary, Overview and Limits fixture PNGs plus boundary harness.
- `603/`: before/after light/dark dashboard, settings components, icon template and incomplete popover diagnostic PNGs plus harnesses and generator.

No source ownership is retained by this artifact branch. It contains review evidence only; app/model/view/CLI/test source repairs were released after #601 publication.
