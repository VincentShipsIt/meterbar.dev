import SwiftUI
import XCTest
@testable import MeterBar

/// Invariants for the shared motion vocabulary (`MeterBarTheme.Motion`) — the
/// testable seam for refresh/micro-motion, since the view modifiers themselves
/// aren't inspectable without ViewInspector. The Reduce-Motion contract lives
/// entirely in these accessors, so every animated surface routes through them.
final class MeterBarMotionTests: XCTestCase {
    // MARK: Tokens exist and keep their calibrated feel

    func testMotionTokensMatchCalibratedCurves() {
        XCTAssertEqual(MeterBarTheme.Motion.quick, .snappy(duration: 0.18))
        XCTAssertEqual(MeterBarTheme.Motion.disclosure, .snappy(duration: 0.18))
        XCTAssertEqual(MeterBarTheme.Motion.standard, .smooth(duration: 0.3))
        XCTAssertEqual(MeterBarTheme.Motion.panel, .smooth(duration: 0.22))
        XCTAssertEqual(MeterBarTheme.Motion.standardCurve, .smooth(duration: 0.35))
        XCTAssertEqual(MeterBarTheme.Motion.snappyCurve, .smooth(duration: 0.22))
    }

    func testStandardCurveAndSnappyCurveAreDistinct() {
        XCTAssertNotEqual(
            MeterBarTheme.Motion.standardCurve,
            MeterBarTheme.Motion.snappyCurve
        )
    }

    // MARK: Reduce Motion collapses to an instant (nil) animation

    func testResolveSuppressesAnimationWhenReduceMotionOn() {
        XCTAssertNil(MeterBarTheme.Motion.resolve(.quick, reduceMotion: true))
        XCTAssertNil(MeterBarTheme.Motion.resolve(.standard, reduceMotion: true))
        XCTAssertNil(MeterBarTheme.Motion.resolve(.panel, reduceMotion: true))
        XCTAssertNil(MeterBarTheme.Motion.resolve(.standardCurve, reduceMotion: true))
        XCTAssertNil(MeterBarTheme.Motion.snappy(reduceMotion: true))
    }

    // MARK: Motion on: the accessor resolves to its curve

    func testResolvePassesThroughWhenReduceMotionOff() {
        XCTAssertEqual(
            MeterBarTheme.Motion.resolve(.quick, reduceMotion: false),
            MeterBarTheme.Motion.quick
        )
        XCTAssertEqual(
            MeterBarTheme.Motion.resolve(.standardCurve, reduceMotion: false),
            MeterBarTheme.Motion.standardCurve
        )
    }

    func testSnappyResolvesToCurveWhenMotionAllowed() {
        XCTAssertEqual(
            MeterBarTheme.Motion.snappy(reduceMotion: false),
            MeterBarTheme.Motion.snappyCurve
        )
    }

    func testResolveIsUsableAsWithAnimationArgument() {
        var animatedValue = 0
        withAnimation(MeterBarTheme.Motion.resolve(.quick, reduceMotion: true)) {
            animatedValue = 1
        }
        XCTAssertEqual(animatedValue, 1)
    }
}
