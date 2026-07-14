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
        XCTAssertEqual(M.quick, .snappy(duration: 0.18))
        XCTAssertEqual(M.disclosure, .snappy(duration: 0.18))
        XCTAssertEqual(M.standard, .smooth(duration: 0.3))
        XCTAssertEqual(M.panel, .smooth(duration: 0.22))
        XCTAssertEqual(M.standardCurve, .smooth(duration: 0.35))
        XCTAssertEqual(M.snappyCurve, .smooth(duration: 0.22))
    }

    func testStandardCurveAndSnappyCurveAreDistinct() {
        XCTAssertNotEqual(M.standardCurve, M.snappyCurve)
    }

    // MARK: Reduce Motion collapses to an instant (nil) animation

    func testResolveSuppressesAnimationWhenReduceMotionOn() {
        XCTAssertNil(M.resolve(M.quick, reduceMotion: true))
        XCTAssertNil(M.resolve(M.standard, reduceMotion: true))
        XCTAssertNil(M.resolve(M.panel, reduceMotion: true))
        XCTAssertNil(M.resolve(M.standardCurve, reduceMotion: true))
        XCTAssertNil(M.snappy(reduceMotion: true))
    }

    // MARK: Motion on: the accessor resolves to its curve

    func testResolvePassesThroughWhenReduceMotionOff() {
        XCTAssertEqual(M.resolve(M.quick, reduceMotion: false), M.quick)
        XCTAssertEqual(M.resolve(M.standardCurve, reduceMotion: false), M.standardCurve)
    }

    func testSnappyResolvesToCurveWhenMotionAllowed() {
        XCTAssertEqual(M.snappy(reduceMotion: false), M.snappyCurve)
    }

    func testResolveIsUsableAsWithAnimationArgument() {
        var animatedValue = 0
        withAnimation(M.resolve(M.quick, reduceMotion: true)) {
            animatedValue = 1
        }
        XCTAssertEqual(animatedValue, 1)
    }
}
