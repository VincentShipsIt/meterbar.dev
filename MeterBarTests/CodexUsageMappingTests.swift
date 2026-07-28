import XCTest
import MeterBarShared
@testable import MeterBar

/// Unit tests for the pure `CodexCliUsageResponse.toUsageMetrics()` mapping,
/// extracted from `CodexCliLocalService.fetchUsageMetrics()` (issue #40). These
/// exercise the window→limit math with fixture JSON and never touch the network.
final class CodexUsageMappingTests: XCTestCase {
    private func decode(_ json: String) throws -> CodexCliUsageResponse {
        try JSONDecoder().decode(CodexCliUsageResponse.self, from: Data(json.utf8))
    }

    // MARK: - Paid account: all three windows present

    func testMapsPrimarySecondaryAndCodeReviewWindows() throws {
        // reset_at values are Unix seconds; the mapping converts them verbatim.
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 42.5,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 3600,
                    "reset_at": 1750000000
                },
                "secondary_window": {
                    "used_percent": 12.0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 200000,
                    "reset_at": 1750600000
                }
            },
            "code_review_rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 5.0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 100000,
                    "reset_at": 1750700000
                }
            },
            "rate_limit_reset_credits": { "available_count": 3 },
            "credits": {
                "has_credits": true,
                "unlimited": false,
                "overage_limit_reached": false,
                "balance": 12.5
            }
        }
        """

        let metrics = try decode(json).toUsageMetrics()

        XCTAssertEqual(metrics.service, .codexCli)

        let session = try XCTUnwrap(metrics.sessionLimit)
        XCTAssertEqual(session.used, 42.5)
        XCTAssertEqual(session.total, 100.0)
        XCTAssertEqual(session.windowSeconds, 18000)
        XCTAssertEqual(session.resetTime, Date(timeIntervalSince1970: 1_750_000_000))

        let weekly = try XCTUnwrap(metrics.weeklyLimit)
        XCTAssertEqual(weekly.used, 12.0)
        XCTAssertEqual(weekly.windowSeconds, 604800)
        XCTAssertEqual(weekly.resetTime, Date(timeIntervalSince1970: 1_750_600_000))

        let codeReview = try XCTUnwrap(metrics.codeReviewLimit)
        XCTAssertEqual(codeReview.used, 5.0)
        XCTAssertEqual(codeReview.resetTime, Date(timeIntervalSince1970: 1_750_700_000))

        XCTAssertEqual(metrics.resetCreditsAvailable, 3)
        XCTAssertEqual(metrics.extraUsage?.state, .on)
    }

    // MARK: - Independently reported windows

    func testSessionOnlyResponseOmitsWeeklyLimit() throws {
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 10.0,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 3600,
                    "reset_at": 1750000000
                }
            }
        }
        """

        let metrics = try decode(json).toUsageMetrics()

        XCTAssertEqual(metrics.sessionLimit?.used, 10.0)
        XCTAssertNil(metrics.weeklyLimit)
        XCTAssertNil(metrics.codeReviewLimit)
    }

    func testWeeklyOnlyResponseMapsPrimaryWindowToWeeklyLimit() throws {
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 36.0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 540000,
                    "reset_at": 1785880800
                }
            }
        }
        """

        let metrics = try decode(json).toUsageMetrics()

        XCTAssertNil(metrics.sessionLimit)
        let weekly = try XCTUnwrap(metrics.weeklyLimit)
        XCTAssertEqual(weekly.used, 36.0)
        XCTAssertEqual(weekly.windowSeconds, 604800)
        XCTAssertEqual(weekly.resetTime, Date(timeIntervalSince1970: 1_785_880_800))
        XCTAssertNil(metrics.codeReviewLimit)
    }

    func testWindowMappingDoesNotDependOnPrimarySecondaryOrder() throws {
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 36.0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 540000,
                    "reset_at": 1785880800
                },
                "secondary_window": {
                    "used_percent": 8.0,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 12000,
                    "reset_at": 1785352800
                }
            }
        }
        """

        let metrics = try decode(json).toUsageMetrics()

        XCTAssertEqual(metrics.sessionLimit?.used, 8.0)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 18000)
        XCTAssertEqual(metrics.weeklyLimit?.used, 36.0)
        XCTAssertEqual(metrics.weeklyLimit?.windowSeconds, 604800)
    }

    // MARK: - Free account: null rate_limit

    func testFreeAccountHasNoWindows() throws {
        let json = """
        {
            "plan_type": "free",
            "rate_limit": null,
            "credits": {
                "has_credits": false,
                "unlimited": false,
                "overage_limit_reached": false,
                "balance": 0
            }
        }
        """

        let metrics = try decode(json).toUsageMetrics()

        XCTAssertEqual(metrics.service, .codexCli)
        XCTAssertNil(metrics.sessionLimit)
        XCTAssertNil(metrics.weeklyLimit)
        XCTAssertNil(metrics.codeReviewLimit)
        XCTAssertNil(metrics.resetCreditsAvailable)
        // credits present + explicitly empty ⇒ overage authoritatively Off.
        XCTAssertEqual(metrics.extraUsage?.state, .off)
    }
}
