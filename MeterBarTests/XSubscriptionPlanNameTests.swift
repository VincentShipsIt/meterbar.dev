@testable import MeterBar
import XCTest

/// The Grok CLI still reports retired SuperGrok SKU names; MeterBar shows the
/// X Subscription name the Grok app and Cursor use for the same plan.
final class XSubscriptionPlanNameTests: XCTestCase {
    func testRetiredSuperGrokNamesMapToXSubscriptionTiers() {
        XCTAssertEqual(XSubscriptionPlanName.current(for: "SuperGrok Heavy"), "Ultra")
        XCTAssertEqual(XSubscriptionPlanName.current(for: "SuperGrok Plus"), "Super")
        XCTAssertEqual(XSubscriptionPlanName.current(for: "SuperGrok Lite"), "Plus")
        XCTAssertEqual(XSubscriptionPlanName.current(for: "SuperGrok"), "Premium")
    }

    func testTokenShapeDoesNotMatter() {
        XCTAssertEqual(XSubscriptionPlanName.current(for: "SUPERGROK_HEAVY"), "Ultra")
        XCTAssertEqual(XSubscriptionPlanName.current(for: "supergrok-heavy"), "Ultra")
        XCTAssertEqual(XSubscriptionPlanName.current(for: "  SuperGrok  Heavy "), "Ultra")
    }

    func testCurrentAndUnknownNamesPassThrough() {
        XCTAssertEqual(XSubscriptionPlanName.current(for: "Ultra"), "Ultra")
        XCTAssertEqual(XSubscriptionPlanName.current(for: "X Premium"), "X Premium")
        XCTAssertEqual(XSubscriptionPlanName.current(for: "Business"), "Business")
    }

    func testEmptyTokenHasNoName() {
        XCTAssertNil(XSubscriptionPlanName.current(for: nil))
        XCTAssertNil(XSubscriptionPlanName.current(for: "   "))
    }
}
