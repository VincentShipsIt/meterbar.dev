import AppKit
@testable import MeterBar
import MeterBarShared
import SwiftUI
import XCTest

/// Coverage for the shared `MeterBarChip` and the five badges migrated onto it.
///
/// SwiftUI gives no public hook to read a rendered `Text`/tint back out, so the
/// tests split into two provable layers:
/// 1. The chip's own contract — it stores the caller's text/tint/style and
///    keeps ONE standardized padding + fill + stroke scale (guards drift).
/// 2. Each migrated badge still maps its state to the same label + tint it did
///    before, and still hosts without collapsing to zero size.
@MainActor
final class MeterBarChipTests: XCTestCase {
    // MARK: - Chip contract

    func testChipStoresCallerSemantics() {
        let chip = MeterBarChip("Ready", systemImage: "checkmark", tint: .green, style: .flat)

        XCTAssertEqual(chip.text, "Ready")
        XCTAssertEqual(chip.systemImage, "checkmark")
        XCTAssertEqual(chip.tint, .green)
        XCTAssertEqual(chip.style, .flat)
    }

    func testChipDefaultsToFlatWithoutIcon() {
        let chip = MeterBarChip("Off", tint: .secondary)

        XCTAssertNil(chip.systemImage)
        XCTAssertEqual(chip.style, .flat)
    }

    /// The whole point of the component: one padding scale, one fill, one
    /// stroke — now derived from `MeterBarTheme`'s shared tokens rather than
    /// local literals. Asserting against the tokens (not magic numbers, which
    /// `MeterBarThemeTests` already guards) catches two kinds of drift: someone
    /// re-hardcoding a Metric, and the derivation silently detaching from the
    /// theme scale.
    func testStandardizedMetricsDeriveFromThemeTokens() {
        XCTAssertEqual(MeterBarChip.Metrics.horizontalPadding, MeterBarTheme.Spacing.sm)
        // verticalPadding has no exact token (old 3pt); it snaps up to xs (4) per
        // the Spacing scale's round-up tie-break — the one sanctioned +1pt shift.
        XCTAssertEqual(MeterBarChip.Metrics.verticalPadding, MeterBarTheme.Spacing.xs)
        XCTAssertEqual(MeterBarChip.Metrics.iconTextSpacing, MeterBarTheme.Spacing.xs)
        XCTAssertEqual(MeterBarChip.Metrics.fillOpacity, MeterBarTheme.Fill.subtle, accuracy: 0.0001)
        XCTAssertEqual(MeterBarChip.Metrics.strokeOpacity, MeterBarTheme.Fill.hairline, accuracy: 0.0001)
        XCTAssertEqual(MeterBarChip.Metrics.strokeWidth, 1)
    }

    func testChipHostsForEveryStyleAndIconCombination() {
        assertHosts(MeterBarChip("On", systemImage: "circle.fill", tint: .orange, style: .flat))
        assertHosts(MeterBarChip("Ready", tint: .green, style: .flat))
        assertHosts(MeterBarChip("Default", tint: .accentColor, style: .glass))
        assertHosts(MeterBarChip("Scan", systemImage: "bolt.fill", tint: .blue, style: .glass))
    }

    // MARK: - ExtraUsageStatusPill migration

    func testExtraUsagePillPreservesLabelAndTint() {
        let on = ExtraUsageStatusPill(status: ExtraUsageStatus(state: .on))
        XCTAssertEqual(on.label, "On")
        XCTAssertEqual(on.color, MeterBarTheme.warning)

        let off = ExtraUsageStatusPill(status: ExtraUsageStatus(state: .off))
        XCTAssertEqual(off.label, "Off")
        XCTAssertEqual(off.color, MeterBarTheme.success)

        let unknown = ExtraUsageStatusPill(status: .unknown)
        XCTAssertEqual(unknown.label, "Unknown")
        XCTAssertEqual(unknown.color, .secondary)
    }

    func testExtraUsagePillHosts() {
        for state in [ExtraUsageStatus.State.on, .off, .unknown] {
            assertHosts(ExtraUsageStatusPill(status: ExtraUsageStatus(state: state)))
        }
    }

    // MARK: - ReadinessBadge migration

    func testReadinessBadgePreservesLabelAndTint() {
        XCTAssertEqual(ReadinessLevel.pass.badgeLabel, "Ready")
        XCTAssertEqual(ReadinessLevel.pass.tint, .green)
        XCTAssertEqual(ReadinessLevel.warn.badgeLabel, "Check")
        XCTAssertEqual(ReadinessLevel.warn.tint, .orange)
        XCTAssertEqual(ReadinessLevel.fail.badgeLabel, "Action needed")
        XCTAssertEqual(ReadinessLevel.fail.tint, .red)
    }

    func testReadinessBadgeHosts() {
        for level in ReadinessLevel.allCases {
            assertHosts(ReadinessBadge(level: level))
        }
    }

    // MARK: - ProviderStatusBadge migration

    func testProviderStatusBadgePreservesTintAndSymbol() {
        XCTAssertEqual(ProviderStatusIndicator.none.tint, MeterBarTheme.success)
        XCTAssertEqual(ProviderStatusIndicator.none.symbolName, "checkmark.circle.fill")
        XCTAssertEqual(ProviderStatusIndicator.minor.tint, MeterBarTheme.warning)
        XCTAssertEqual(ProviderStatusIndicator.critical.tint, MeterBarTheme.danger)
        XCTAssertEqual(ProviderStatusIndicator.unknown.tint, .secondary)
    }

    func testProviderStatusBadgeHosts() {
        assertHosts(ProviderStatusBadge(indicator: .none, label: "All systems operational"))
        assertHosts(ProviderStatusBadge(indicator: .critical, label: "Major outage"))
    }

    // MARK: - Helpers

    /// Renders a view in an off-screen host and asserts it lays out to a real,
    /// non-zero size — enough to catch a chip that fails to build or collapses.
    private func assertHosts(
        _ view: some View,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        host.layoutSubtreeIfNeeded()

        let size = host.fittingSize
        XCTAssertGreaterThan(size.width, 0, "chip should have non-zero width", file: file, line: line)
        XCTAssertGreaterThan(size.height, 0, "chip should have non-zero height", file: file, line: line)
    }
}
