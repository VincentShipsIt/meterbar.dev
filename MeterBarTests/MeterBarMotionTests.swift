import SwiftUI
import XCTest
@testable import MeterBar

/// Invariants for the shared motion vocabulary (`MeterBarTheme.Motion`) — the
/// testable seam for refresh/micro-motion, since the view modifiers themselves
/// aren't inspectable without ViewInspector. The Reduce-Motion contract lives
/// entirely in these accessors, so every animated surface routes through them.
final class MeterBarMotionTests: XCTestCase {
    private typealias MB = MeterBarTheme.Motion

    // MARK: Tokens exist and keep their calibrated feel

    func testMotionTokensMatchCalibratedCurves() {
        XCTAssertEqual(MB.quick, .snappy(duration: 0.18))
        XCTAssertEqual(MB.disclosure, .snappy(duration: 0.18))
        XCTAssertEqual(MB.standard, .smooth(duration: 0.32))
        XCTAssertEqual(MB.panel, .smooth(duration: 0.22))
        XCTAssertEqual(MB.standardCurve, .smooth(duration: 0.35))
        XCTAssertEqual(MB.snappyCurve, .smooth(duration: 0.22))
    }

    func testStandardCurveAndSnappyCurveAreDistinct() {
        XCTAssertNotEqual(MB.standardCurve, MB.snappyCurve)
    }

    // MARK: Reduce Motion collapses to an instant (nil) animation

    func testResolveSuppressesAnimationWhenReduceMotionOn() {
        XCTAssertNil(MB.resolve(MB.quick, reduceMotion: true))
        XCTAssertNil(MB.resolve(MB.standard, reduceMotion: true))
        XCTAssertNil(MB.resolve(MB.panel, reduceMotion: true))
        XCTAssertNil(MB.resolve(MB.standardCurve, reduceMotion: true))
        XCTAssertNil(MB.snappy(reduceMotion: true))
    }

    // MARK: Motion on: the accessor resolves to its curve

    func testResolvePassesThroughWhenReduceMotionOff() {
        XCTAssertEqual(MB.resolve(MB.quick, reduceMotion: false), MB.quick)
        XCTAssertEqual(MB.resolve(MB.standardCurve, reduceMotion: false), MB.standardCurve)
    }

    func testSnappyResolvesToCurveWhenMotionAllowed() {
        XCTAssertEqual(MB.snappy(reduceMotion: false), MB.snappyCurve)
    }

    func testResolveIsUsableAsWithAnimationArgument() {
        var animatedValue = 0
        withAnimation(MB.resolve(MB.quick, reduceMotion: true)) {
            animatedValue = 1
        }
        XCTAssertEqual(animatedValue, 1)
    }
}
