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

    // MARK: - Prepaid credits replace an exhausted subscription window

    func testExhaustedWeeklyWithBalanceOnlyKeepsANumericRemainder() throws {
        let metrics = try decode(exhaustedWindow(credits: #"{ "has_credits": true, "unlimited": false, "balance": 61586.14 }"#))
            .toUsageMetrics()

        XCTAssertNil(metrics.sessionLimit)
        XCTAssertNil(metrics.weeklyLimit)
        let credit = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(credit.label, "Credits")
        XCTAssertEqual(credit.reading, .remainder)
        XCTAssertEqual(credit.used, 0)
        XCTAssertEqual(credit.total, 61586.14)
        XCTAssertNil(credit.windowSeconds)
        XCTAssertFalse(credit.hasDepletingMeter)
        XCTAssertEqual(metrics.extraUsage?.detail, "61,586.14 in credits")
    }

    func testScalarSpendCapDoesNotDrawAnAllowance() throws {
        let decoded = try decode("""
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 200000,
                    "reset_at": 1750600000
                }
            },
            "credits": { "has_credits": true, "unlimited": false, "balance": 40 },
            "spend_control": { "reached": false, "individual_limit": 100 }
        }
        """)

        XCTAssertEqual(decoded.spendControl?.individualLimit, 100)
        XCTAssertNil(decoded.spendControl?.creditAllowance)
        let metrics = decoded.toUsageMetrics()
        XCTAssertNil(metrics.weeklyLimit)
        let credit = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(credit.reading, .remainder)
        XCTAssertEqual(credit.total, 40)
        XCTAssertFalse(credit.hasDepletingMeter)
        XCTAssertEqual(metrics.extraUsage?.detail, "40 in credits · cap $100.00")
    }

    func testWorkspaceAllowanceMatchingTheBalanceDrawsABar() throws {
        let decoded = try decode("""
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 200000,
                    "reset_at": 1750600000
                }
            },
            "code_review_rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 5,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 100000,
                    "reset_at": 1750700000
                }
            },
            "credits": { "has_credits": true, "balance": "963.20" },
            "spend_control": {
                "reached": false,
                "individual_limit": {
                    "source": "workspace_spend_controls",
                    "limit": "1000",
                    "used": "36.80",
                    "remaining": "963.20",
                    "used_percent": 4,
                    "remaining_percent": 96,
                    "reset_after_seconds": 2105558,
                    "reset_at": 1788220800
                }
            }
        }
        """)

        XCTAssertNil(decoded.spendControl?.individualLimit)
        let metrics = decoded.toUsageMetrics()
        XCTAssertNil(metrics.weeklyLimit)
        XCTAssertEqual(metrics.codeReviewLimit?.used, 5)
        let credit = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(credit.reading, .allowance)
        XCTAssertEqual(credit.used, 36.80, accuracy: 0.001)
        XCTAssertEqual(credit.total, 1000)
        XCTAssertEqual(credit.resetTime, Date(timeIntervalSince1970: 1_788_220_800))
        XCTAssertNil(credit.windowSeconds)
        XCTAssertTrue(credit.hasDepletingMeter)
        XCTAssertFalse(metrics.extraUsage?.detail?.contains("cap") ?? true)
    }

    func testWorkspaceAllowanceThatDisagreesWithTheBalanceStaysARemainder() throws {
        let metrics = try decode("""
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 1,
                    "reset_at": 1750600000
                }
            },
            "credits": { "has_credits": true, "balance": 62317 },
            "spend_control": {
                "reached": false,
                "individual_limit": { "limit": "1000", "remaining": "963.20", "used": "36.80" }
            }
        }
        """).toUsageMetrics()

        let credit = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(credit.reading, .remainder)
        XCTAssertEqual(credit.total, 62317)
        XCTAssertNil(credit.resetTime)
        XCTAssertFalse(credit.hasDepletingMeter)
    }

    func testWorkspaceAllowanceWithoutABalanceDrawsTheBar() throws {
        let metrics = try decode("""
        {
            "plan_type": "team",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 1,
                    "reset_at": 1750600000
                }
            },
            "credits": { "has_credits": false, "balance": null },
            "spend_control": {
                "reached": false,
                "individual_limit": { "limit": 1000, "used_percent": 4, "reset_at": 1788220800 }
            }
        }
        """).toUsageMetrics()

        let credit = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(credit.reading, .allowance)
        XCTAssertEqual(credit.total, 1000)
        XCTAssertEqual(credit.used, 40, accuracy: 0.001)
        XCTAssertEqual(credit.resetTime, Date(timeIntervalSince1970: 1_788_220_800))
        XCTAssertTrue(credit.hasDepletingMeter)
    }

    func testSpendCapSmallerThanTheBalanceIsNotAnAllowance() throws {
        let metrics = try decode("""
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 1,
                    "reset_at": 1750600000
                }
            },
            "credits": { "has_credits": true, "balance": 61586.14 },
            "spend_control": { "reached": false, "individual_limit": 40 }
        }
        """).toUsageMetrics()

        XCTAssertNil(metrics.weeklyLimit)
        let credit = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(credit.reading, .remainder)
        XCTAssertEqual(credit.total, 61586.14)
        XCTAssertFalse(credit.hasDepletingMeter)
        XCTAssertEqual(metrics.extraUsage?.detail, "61,586.14 in credits · cap $40.00")
    }

    func testUnlimitedCreditsDoNotDeplete() throws {
        let metrics = try decode("""
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 1,
                    "reset_at": 1750600000
                }
            },
            "credits": { "unlimited": true, "balance": 10 }
        }
        """).toUsageMetrics()

        XCTAssertNil(metrics.weeklyLimit)
        let credit = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(credit.reading, .unlimited)
        XCTAssertFalse(credit.hasDepletingMeter)
    }

    func testSubscriptionWindowWithQuotaStaysTheOnlyMeter() throws {
        let metrics = try decode("""
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 36,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 540000,
                    "reset_at": 1785880800
                }
            },
            "credits": { "has_credits": true, "unlimited": false, "balance": 61586.14 }
        }
        """).toUsageMetrics()

        XCTAssertEqual(metrics.weeklyLimit?.used, 36)
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
        XCTAssertEqual(metrics.extraUsage?.state, .on)
        XCTAssertEqual(metrics.extraUsage?.detail, "61,586.14 in credits")
    }

    func testLimitReachedKeepsAWindowThatStillHasQuota() throws {
        let metrics = try decode("""
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 3600,
                    "reset_at": 1750000000
                },
                "secondary_window": {
                    "used_percent": 16,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 400000,
                    "reset_at": 1750600000
                }
            },
            "credits": { "has_credits": true, "balance": 62317 }
        }
        """).toUsageMetrics()

        XCTAssertEqual(metrics.sessionLimit?.used, 100)
        XCTAssertEqual(metrics.weeklyLimit?.used, 16)
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    func testMalformedSpendAllowanceDoesNotBlankUsage() throws {
        let metrics = try decode("""
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 1,
                    "reset_at": 1750600000
                }
            },
            "credits": { "has_credits": true, "balance": 12.5 },
            "spend_control": { "reached": false, "individual_limit": { "limit": { "nested": true } } }
        }
        """).toUsageMetrics()

        XCTAssertNil(metrics.weeklyLimit)
        let credit = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(credit.reading, .remainder)
        XCTAssertEqual(credit.total, 12.5)
    }

    func testZeroBalanceDoesNotActivateAnUnrelatedAllowance() throws {
        let fixture = exhaustedWindow(credits: #"{ "has_credits": false, "balance": 0 }"#)
            .replacingOccurrences(
                of: #""plan_type": "plus","#,
                with: #""plan_type": "plus", "spend_control": { "reached": false, "individual_limit": { "limit": 1000, "used": 40 } },"#
            )
        let metrics = try decode(fixture).toUsageMetrics()

        XCTAssertTrue(metrics.additionalLimits.isEmpty)
        XCTAssertEqual(metrics.weeklyLimit?.used, 100)
    }

    func testMissingSubscriptionDoesNotPromoteCredits() throws {
        let metrics = try decode(#"{ "plan_type": "free", "rate_limit": null, "credits": { "balance": 40 } }"#)
            .toUsageMetrics()

        XCTAssertNil(metrics.sessionLimit)
        XCTAssertNil(metrics.weeklyLimit)
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    private func exhaustedWindow(credits: String) -> String {
        """
        {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 200000,
                    "reset_at": 1750600000
                }
            },
            "credits": \(credits)
        }
        """
    }
}
