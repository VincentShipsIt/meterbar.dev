import MeterBarShared
import XCTest
@testable import MeterBar

/// Parser fixtures are redacted. The idle payload's keys were captured live on
/// 2026-10-13 with `subs_usage` absent; the values here are placeholders.
/// Every payload that includes `subs_usage` is documented/synthetic — that
/// shape comes from CodexBar's Muse plugin and was not captured live.
final class MuseCodeUsageParserTests: XCTestCase {
    private let leakedEmail = "person@example.invalid"
    private let leakedKey = "mk-inference-secret-value"

    func testLiveCapturedIdleOmitsUsageAndKeepsPlan() throws {
        let outcome = try MuseCodeUsageParser.parse(Data(liveCapturedIdle.utf8))
        XCTAssertEqual(outcome, .idle(plan: "Muse Code High Usage"))
        XCTAssertFalse(String(describing: outcome).contains(leakedEmail))
        XCTAssertFalse(String(describing: outcome).contains(leakedKey))
    }

    func testSubsUsageNullIsIdle() throws {
        let outcome = try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_tier_name":"Muse Code High Usage","subs_usage":null}"#
                .utf8
        ))
        XCTAssertEqual(outcome, .idle(plan: "Muse Code High Usage"))
    }

    func testSubsUsageAbsentIsIdle() throws {
        let outcome = try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_tier_name":"Plan"}"#.utf8
        ))
        XCTAssertEqual(outcome, .idle(plan: "Plan"))
    }

    func testSyntheticCompletePayloadReadsBothWindows() throws {
        guard case let .quota(plan, session, weekly) = try MuseCodeUsageParser.parse(Data(syntheticComplete.utf8)) else {
            return XCTFail("expected quota")
        }
        XCTAssertEqual(plan, "Muse Code High Usage")
        XCTAssertEqual(session?.used, 40)
        XCTAssertEqual(session?.total, 100)
        XCTAssertEqual(session?.windowSeconds, 300 * 60)
        XCTAssertEqual(session?.periodKind, .session)
        XCTAssertEqual(session?.resetTime, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(weekly?.used, 12)
        XCTAssertEqual(weekly?.windowSeconds, 7 * 24 * 3_600)
        XCTAssertEqual(weekly?.periodKind, .weekly)
        XCTAssertEqual(weekly?.resetTime, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertFalse(String(describing: session).contains(leakedKey))
    }

    func testSyntheticWeeklyOnlyKeepsWeeklyWindow() throws {
        guard case let .quota(_, session, weekly) = try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":{"weekly":{"used_percent":15,"resets_at":1900000000}}}"#.utf8
        )) else {
            return XCTFail("expected quota")
        }
        XCTAssertNil(session)
        XCTAssertEqual(weekly?.used, 15)
        XCTAssertEqual(weekly?.periodKind, .weekly)
    }

    func testPercentAbove100ClampsTheBarAndMarksExhausted() throws {
        guard case let .quota(_, session, _) = try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":{"window":{"used_percent":150,"window_duration_mins":300}}}"#.utf8
        )) else {
            return XCTFail("expected quota")
        }
        XCTAssertEqual(session?.used, 100)
        XCTAssertEqual(session?.total, 100)
        XCTAssertEqual(session?.percentage, 100)
        XCTAssertEqual(session?.isAtLimit, true)
        XCTAssertNil(session?.resetTime)
    }

    func testOutOfRangeResetDropsOnlyTheReset() throws {
        guard case let .quota(_, session, weekly) = try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":{"window":{"used_percent":10,"resets_at":0},"weekly":{"used_percent":20,"resets_at":64092211201}}}"#
                .utf8
        )) else {
            return XCTFail("expected quota")
        }
        XCTAssertEqual(session?.used, 10)
        XCTAssertNil(session?.resetTime)
        XCTAssertEqual(weekly?.used, 20)
        XCTAssertNil(weekly?.resetTime)
    }

    func testValidResetBoundaryIsKept() throws {
        guard case let .quota(_, session, _) = try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":{"window":{"used_percent":"8","resets_at":64092211200}}}"#.utf8
        )) else {
            return XCTFail("expected quota")
        }
        XCTAssertEqual(session?.resetTime, Date(timeIntervalSince1970: 64_092_211_200))
    }

    func testNonfiniteNegativeAndFractionalPercentsDropTheWindow() throws {
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":{"window":{"used_percent":-1},"weekly":{"used_percent":1.5}}}"#.utf8
        )))
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":{"window":{"used_percent":"NaN"}}}"#.utf8
        )))
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":{"window":{"used_percent":1e309}}}"#.utf8
        )))
        guard case let .quota(_, session, weekly) = try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":{"window":{"used_percent":true},"weekly":{"used_percent":4}}}"#.utf8
        )) else {
            return XCTFail("expected weekly quota")
        }
        XCTAssertNil(session)
        XCTAssertEqual(weekly?.used, 4)
    }

    func testUnknownExtraFieldsAreIgnored() throws {
        guard case let .quota(plan, session, _) = try MuseCodeUsageParser.parse(Data(syntheticComplete.utf8)) else {
            return XCTFail("expected quota")
        }
        XCTAssertEqual(plan, "Muse Code High Usage")
        XCTAssertEqual(session?.used, 40)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data("not-json".utf8)))
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data("[]".utf8)))
    }

    func testWrongBoolTypesThrow() {
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":1,"subs_usage":null}"#.utf8
        )))
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":"true","require_payment":false}"#.utf8
        )))
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":"yes"}"#.utf8
        )))
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data(#"{"require_payment":false}"#.utf8)))
    }

    func testInactiveSubscriptionHasNoUsage() throws {
        let outcome = try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":false,"require_payment":false,"subs_tier_name":"","subs_usage":{"window":{"used_percent":10}}}"#.utf8
        ))
        XCTAssertEqual(outcome, .inactive(plan: nil))
    }

    func testPaymentRequiredWinsOverUsage() throws {
        let outcome = try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":true,"subs_tier_name":"Muse Code High Usage","subs_usage":{"window":{"used_percent":10}}}"#
                .utf8
        ))
        XCTAssertEqual(outcome, .paymentRequired(plan: "Muse Code High Usage"))
    }

    func testPresentUsageObjectWithNoReadableWindowIsDrift() {
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":{"window":{}}}"#.utf8
        )))
        XCTAssertThrowsError(try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":"weekly"}"#.utf8
        )))
    }

    func testMissingDurationDoesNotInventFiveHours() throws {
        guard case let .quota(_, session, _) = try MuseCodeUsageParser.parse(Data(
            #"{"is_subs_active":true,"require_payment":false,"subs_usage":{"window":{"used_percent":3}}}"#.utf8
        )) else {
            return XCTFail("expected quota")
        }
        XCTAssertNil(session?.windowSeconds)
        XCTAssertEqual(session?.periodKind, .session)
    }

    /// Live-captured top-level keys from 2026-10-13. Values are placeholders.
    private var liveCapturedIdle: String {
        """
        {
          "action_url": "https://example.invalid/subscribe",
          "api_key": "\(leakedKey)",
          "base_url": "https://example.invalid",
          "can_subscribe": false,
          "has_payment_method": true,
          "is_subs_active": true,
          "is_subs_upgrade_available": false,
          "payment_method": {"brand": "redacted"},
          "require_payment": false,
          "show_subs_upsell": false,
          "subs_tier_id": "redacted-tier",
          "subs_tier_name": "Muse Code High Usage",
          "user_avatar_url": "https://example.invalid/avatar",
          "user_email": "\(leakedEmail)",
          "user_full_name": "Redacted Person"
        }
        """
    }

    /// Documented/synthetic `subs_usage` plus the live-captured extra keys.
    private var syntheticComplete: String {
        """
        {
          "api_key": "\(leakedKey)",
          "user_email": "\(leakedEmail)",
          "payment_method": {"brand": "redacted"},
          "is_subs_active": true,
          "require_payment": false,
          "subs_tier_name": "Muse Code High Usage",
          "unexpected_field": {"ignore": true},
          "subs_usage": {
            "window": {"used_percent": 40, "window_duration_mins": 300, "resets_at": 1800000000},
            "weekly": {"used_percent": 12, "resets_at": 1900000000}
          }
        }
        """
    }
}
