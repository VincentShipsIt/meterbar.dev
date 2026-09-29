import XCTest
@testable import MeterBar

final class PublicProfilePublishPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFirstPublishGoesOutImmediately() {
        XCTAssertTrue(PublicProfilePublishPolicy.shouldPublish(
            now: t0, lastAttempt: nil, lastSuccess: nil, contentChanged: true
        ))
    }

    func testNothingGoesOutInsideTheMinimumIntervalEvenIfChanged() {
        XCTAssertFalse(PublicProfilePublishPolicy.shouldPublish(
            now: t0.addingTimeInterval(14 * 60), lastAttempt: t0, lastSuccess: t0, contentChanged: true
        ))
    }

    func testChangedContentGoesOutOnceTheIntervalHasPassed() {
        XCTAssertTrue(PublicProfilePublishPolicy.shouldPublish(
            now: t0.addingTimeInterval(15 * 60), lastAttempt: t0, lastSuccess: t0, contentChanged: true
        ))
    }

    func testUnchangedContentWaitsForTheHourlyHeartbeat() {
        XCTAssertFalse(PublicProfilePublishPolicy.shouldPublish(
            now: t0.addingTimeInterval(30 * 60), lastAttempt: t0, lastSuccess: t0, contentChanged: false
        ))
        XCTAssertTrue(PublicProfilePublishPolicy.shouldPublish(
            now: t0.addingTimeInterval(60 * 60), lastAttempt: t0, lastSuccess: t0, contentChanged: false
        ))
    }

    /// A failed attempt still spends the interval, so an outage is retried at
    /// the same slow cadence instead of on every refresh.
    func testFailedAttemptsAreThrottledLikeSuccesses() {
        XCTAssertFalse(PublicProfilePublishPolicy.shouldPublish(
            now: t0.addingTimeInterval(60), lastAttempt: t0, lastSuccess: nil, contentChanged: true
        ))
        XCTAssertTrue(PublicProfilePublishPolicy.shouldPublish(
            now: t0.addingTimeInterval(15 * 60), lastAttempt: t0, lastSuccess: nil, contentChanged: true
        ))
    }

    func testForceBypassesTheThrottle() {
        XCTAssertTrue(PublicProfilePublishPolicy.shouldPublish(
            now: t0.addingTimeInterval(1), lastAttempt: t0, lastSuccess: t0, contentChanged: false, force: true
        ))
    }
}
