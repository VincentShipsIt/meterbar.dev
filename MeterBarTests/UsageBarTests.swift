import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

/// Coverage for `UsageBar`'s off-pace overlay.
///
/// The bar's colored fill is quota *left*, so the two off-pace stages sit on
/// opposite sides of the pace marker: `.deficit` (burning fast) leaves a gap on
/// the empty track to the marker's left-of-fill side, `.reserve` (ahead of pace)
/// leaves that same amount *inside* the fill. `.reserve` used to draw no band at
/// all and a bare 2pt green marker on top of the accent, which made "ahead of
/// pace" indistinguishable from "on pace" — see the geometry assertions below.
///
/// All the math lives in the pure `UsageBar.BarGeometry` value type (the same
/// reason `LimitRow.RowContent` exists) so every stage is assertable without
/// hosting the view.
@MainActor
final class UsageBarGeometryTests: XCTestCase {
    private let width: CGFloat = 200

    private func pace(expectedUsed: Double, actualUsed: Double) -> UsagePace {
        UsagePace(
            expectedUsedPercent: expectedUsed,
            deltaPercent: actualUsed - expectedUsed,
            etaSeconds: nil,
            willLastToReset: true
        )
    }

    private func geometry(expectedUsed: Double, actualUsed: Double) -> UsageBar.BarGeometry {
        UsageBar.BarGeometry(
            width: width,
            usedPercentage: actualUsed,
            pace: pace(expectedUsed: expectedUsed, actualUsed: actualUsed)
        )
    }

    // MARK: - Fill

    func testFillTracksQuotaLeftNotQuotaUsed() {
        // 65% used → 35% of the bar is filled. The fill is what's left.
        XCTAssertEqual(geometry(expectedUsed: 67.7, actualUsed: 65).fillWidth, 70, accuracy: 0.001)
    }

    func testNilPaceDrawsFillOnlyWithNoOverlay() {
        let geometry = UsageBar.BarGeometry(width: width, usedPercentage: 40, pace: nil)
        XCTAssertEqual(geometry.fillWidth, 120, accuracy: 0.001)
        XCTAssertNil(geometry.band)
        XCTAssertNil(geometry.markerX)
    }

    // MARK: - Stages

    /// On pace deliberately draws nothing extra — no marker, no band.
    func testOnPaceDrawsNoMarkerOrBand() {
        let geometry = geometry(expectedUsed: 50, actualUsed: 51)
        XCTAssertNil(geometry.band, "on pace must stay a plain fill")
        XCTAssertNil(geometry.markerX, "on pace must not draw the marker")
    }

    /// Burning faster than pace: the band spans the empty track between the fill's
    /// edge and the marker — the quota you *should* still have.
    func testDeficitBandRunsFromFillEdgeOutToTheMarker() {
        let geometry = geometry(expectedUsed: 40, actualUsed: 60)
        // 60% used → fill 80pt. 40% expected-used → marker at 120pt.
        XCTAssertEqual(geometry.fillWidth, 80, accuracy: 0.001)
        XCTAssertEqual(geometry.band?.kind, .deficit)
        XCTAssertEqual(geometry.band?.x ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(geometry.band?.width ?? -1, 40, accuracy: 0.001)
    }

    /// Ahead of pace: the mirror band spans from the marker to the fill's edge —
    /// the quota you have *beyond* pace. Without it, `.reserve` renders as a bare
    /// marker buried inside the accent fill and reads as "no marker at all".
    func testReserveBandRunsFromTheMarkerInToTheFillEdge() {
        let geometry = geometry(expectedUsed: 60, actualUsed: 40)
        // 40% used → fill 120pt. 60% expected-used → marker at 80pt.
        XCTAssertEqual(geometry.fillWidth, 120, accuracy: 0.001)
        XCTAssertEqual(geometry.band?.kind, .reserve)
        XCTAssertEqual(geometry.band?.x ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(geometry.band?.width ?? -1, 40, accuracy: 0.001)
    }

    /// The live case that surfaced the bug: a Grok weekly window at 65% used
    /// against 67.7% expected is `.reserve` by 2.7 points — past the ±2 on-pace
    /// filter, so it must draw a band rather than silently render as on pace.
    func testSmallReserveDeltaStillDrawsAVisibleBand() {
        let geometry = geometry(expectedUsed: 67.69, actualUsed: 65)
        XCTAssertEqual(geometry.band?.kind, .reserve)
        XCTAssertEqual(geometry.band?.x ?? -1, 64.62, accuracy: 0.01)
        XCTAssertEqual(geometry.band?.width ?? -1, 5.38, accuracy: 0.01)
    }

    /// Mirrored deltas must produce mirrored bands — the reserve band carries the
    /// same weight as the deficit band it mirrors.
    func testMirroredDeltasProduceEquallyWideBands() {
        let deficit = geometry(expectedUsed: 50, actualUsed: 65)
        let reserve = geometry(expectedUsed: 50, actualUsed: 35)

        XCTAssertEqual(deficit.band?.kind, .deficit)
        XCTAssertEqual(reserve.band?.kind, .reserve)
        XCTAssertEqual(deficit.band?.width ?? -1, reserve.band?.width ?? -2, accuracy: 0.001)
        // Both bands terminate at the same marker, from opposite sides.
        XCTAssertEqual(deficit.markerX ?? -1, reserve.markerX ?? -2, accuracy: 0.001)
    }

    /// `.offset` doesn't grow a layout, so the fill + band stack is only as wide
    /// as its widest *laid-out* child — the fill. The deficit band is offset past
    /// that edge, so without an explicit painted width the capsule clip swallowed
    /// it whole and the red block never reached the screen.
    func testPaintedWidthCoversTheWholeDeficitBand() {
        let geometry = geometry(expectedUsed: 35, actualUsed: 60)
        let band = geometry.band
        XCTAssertGreaterThan(band?.width ?? 0, 0)
        XCTAssertGreaterThanOrEqual(
            geometry.paintedWidth,
            (band?.x ?? 0) + (band?.width ?? 0),
            "the deficit band must not be clipped off the end of the fill"
        )
    }

    /// Reserve paints inside the fill, so the painted region stays the fill.
    func testPaintedWidthMatchesTheFillWhenAheadOfPace() {
        let geometry = geometry(expectedUsed: 60, actualUsed: 40)
        XCTAssertEqual(geometry.paintedWidth, geometry.fillWidth, accuracy: 0.001)
    }

    // MARK: - Marker placement

    func testMarkerIsCenteredOnTheExpectedPosition() {
        let geometry = geometry(expectedUsed: 40, actualUsed: 60)
        let expectedX: CGFloat = 120
        XCTAssertEqual(
            (geometry.markerX ?? -1) + UsageBar.BarGeometry.markerWidth / 2,
            expectedX,
            accuracy: 0.001
        )
    }

    /// The marker is a real shape with width, so it has to stay inside the bar at
    /// both ends instead of hanging off the cap.
    func testMarkerStaysInsideTheBarAtBothExtremes() {
        let markerWidth = UsageBar.BarGeometry.markerWidth
        let atStart = geometry(expectedUsed: 100, actualUsed: 0)
        let atEnd = geometry(expectedUsed: 0, actualUsed: 100)

        XCTAssertEqual(atStart.markerX ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(atEnd.markerX ?? -1, width - markerWidth, accuracy: 0.001)
    }

    /// A zero-width bar (first layout pass) must not produce negative geometry.
    func testZeroWidthBarProducesNoNegativeGeometry() {
        let geometry = UsageBar.BarGeometry(
            width: 0,
            usedPercentage: 40,
            pace: pace(expectedUsed: 60, actualUsed: 40)
        )
        XCTAssertEqual(geometry.fillWidth, 0)
        XCTAssertGreaterThanOrEqual(geometry.band?.width ?? 0, 0)
        XCTAssertGreaterThanOrEqual(geometry.markerX ?? 0, 0)
    }

    /// Percentages arriving out of range (a provider over-reporting) clamp rather
    /// than painting outside the bar.
    func testOutOfRangeInputsClamp() {
        let over = UsageBar.BarGeometry(
            width: width,
            usedPercentage: 140,
            pace: pace(expectedUsed: 180, actualUsed: 140)
        )
        XCTAssertEqual(over.fillWidth, 0)
        XCTAssertGreaterThanOrEqual(over.band?.width ?? 0, 0)
        XCTAssertLessThanOrEqual(
            (over.markerX ?? 0) + UsageBar.BarGeometry.markerWidth,
            width
        )
    }
}

/// The reserve band and the pace marker are drawn *on top of* the provider accent
/// fill, so hue alone can't carry them: Cursor's and OpenAI's accents are already
/// green. Both tokens must therefore separate from every accent by luminance, in
/// light and dark appearance.
@MainActor
final class UsageBarContrastTests: XCTestCase {
    private let accents: [(String, Color)] = [
        ("codex", MeterBarTheme.codexAccent),
        ("claude", MeterBarTheme.claudeAccent),
        ("cursor", MeterBarTheme.cursorAccent),
        ("openai", MeterBarTheme.openaiAccent),
        ("openRouter", MeterBarTheme.openRouterAccent),
        ("grok", MeterBarTheme.grokAccent)
    ]

    func testReserveBandSeparatesFromEveryAccentInBothAppearances() {
        assertContrast(
            overlay: MeterBarTheme.reserveBand,
            opacity: UsageBar.bandOpacity,
            minimumLuminanceDelta: 0.15
        )
    }

    func testMarkerCasingSeparatesFromEveryAccentInBothAppearances() {
        assertContrast(
            overlay: MeterBarTheme.paceMarkerCasing,
            opacity: UsageBar.markerCasingOpacity,
            minimumLuminanceDelta: 0.3
        )
    }

    /// The casing also has to separate the marker from the reserve band it sits
    /// against, not just from the raw accent.
    func testMarkerCasingSeparatesFromTheReserveBand() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let band = composite(
                overlay: MeterBarTheme.reserveBand,
                opacity: UsageBar.bandOpacity,
                over: MeterBarTheme.cursorAccent,
                appearanceName: name
            )
            let casing = composite(
                overlay: MeterBarTheme.paceMarkerCasing,
                opacity: UsageBar.markerCasingOpacity,
                over: MeterBarTheme.reserveBand,
                appearanceName: name
            )
            XCTAssertGreaterThan(
                abs(luminance(casing) - luminance(band)),
                0.3,
                "marker casing blends into the reserve band in \(name.rawValue)"
            )
        }
    }

    private func assertContrast(
        overlay: Color,
        opacity: Double,
        minimumLuminanceDelta: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for (label, accent) in accents {
                let accentLuminance = luminance(resolved(accent, appearanceName: name))
                let overlayLuminance = luminance(
                    composite(overlay: overlay, opacity: opacity, over: accent, appearanceName: name)
                )
                XCTAssertGreaterThan(
                    abs(overlayLuminance - accentLuminance),
                    minimumLuminanceDelta,
                    "overlay is invisible on the \(label) accent in \(name.rawValue)",
                    file: file,
                    line: line
                )
            }
        }
    }

    /// Source-over composite of `overlay` at `opacity` onto `base`, both resolved
    /// for the given appearance. The bands are translucent, so contrast has to be
    /// measured on what actually reaches the screen.
    private func composite(
        overlay: Color,
        opacity: Double,
        over base: Color,
        appearanceName: NSAppearance.Name
    ) -> NSColor {
        let top = resolved(overlay, appearanceName: appearanceName)
        let bottom = resolved(base, appearanceName: appearanceName)
        let alpha = CGFloat(opacity)
        return NSColor(
            srgbRed: top.redComponent * alpha + bottom.redComponent * (1 - alpha),
            green: top.greenComponent * alpha + bottom.greenComponent * (1 - alpha),
            blue: top.blueComponent * alpha + bottom.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private func luminance(_ color: NSColor) -> Double {
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private func resolved(_ color: Color, appearanceName: NSAppearance.Name) -> NSColor {
        guard let appearance = NSAppearance(named: appearanceName) else {
            XCTFail("Missing \(appearanceName.rawValue) appearance")
            return .clear
        }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        guard let resolved else {
            XCTFail("Could not resolve color in sRGB")
            return .clear
        }
        return resolved
    }
}

/// The bar's only textual explanation is its tooltip — the popover footer is
/// reset-only at `.compact` density, so hovering is the sole place the overlay is
/// spelled out. Both bands need a line there, not just the red one.
@MainActor
final class UsageBarTooltipTests: XCTestCase {
    private func bar(expectedUsed: Double, actualUsed: Double) -> UsageBar {
        UsageBar(
            usedPercentage: actualUsed,
            accentColor: .blue,
            pace: UsagePace(
                expectedUsedPercent: expectedUsed,
                deltaPercent: actualUsed - expectedUsed,
                etaSeconds: nil,
                willLastToReset: true
            ),
            paceContext: .session
        )
    }

    func testTooltipExplainsTheDeficitBand() {
        let tooltip = bar(expectedUsed: 40, actualUsed: 60).tooltipText ?? ""
        XCTAssertTrue(tooltip.contains("Red is quota you should still have at this pace."), tooltip)
        XCTAssertFalse(tooltip.contains("Green is"), tooltip)
    }

    func testTooltipExplainsTheReserveBand() {
        let tooltip = bar(expectedUsed: 60, actualUsed: 40).tooltipText ?? ""
        XCTAssertTrue(tooltip.contains("Green is quota you have beyond this pace."), tooltip)
        XCTAssertFalse(tooltip.contains("Red is"), tooltip)
    }

    func testOnPaceTooltipExplainsNeitherBand() {
        let tooltip = bar(expectedUsed: 50, actualUsed: 51).tooltipText ?? ""
        XCTAssertFalse(tooltip.contains("Green is"), tooltip)
        XCTAssertFalse(tooltip.contains("Red is"), tooltip)
    }

    func testEveryStageRenders() {
        let stages: [(String, Double, Double)] = [
            ("onPace", 50, 51),
            ("reserve", 60, 40),
            ("deficit", 40, 60)
        ]
        for (label, expected, actual) in stages {
            let host = NSHostingView(rootView: bar(expectedUsed: expected, actualUsed: actual).frame(width: 200))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0, "UsageBar(\(label)) should lay out")
        }
    }
}
