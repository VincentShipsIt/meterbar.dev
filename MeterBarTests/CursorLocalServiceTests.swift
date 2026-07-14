import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Direct coverage for `CursorLocalService`'s pure slices — the summary →
/// `UsageMetrics` mapping and the JWT `sub` → userId extraction — neither of
/// which requires Cursor's SQLite DB or the dashboard API.
final class CursorLocalServiceTests: XCTestCase {

    private func decodeSummary(_ json: String) throws -> CursorUsageSummaryResponse {
        try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: Data(json.utf8))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeJWT(sub: String) -> String {
        let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
        let body = base64URL(try! JSONSerialization.data(withJSONObject: ["sub": sub]))
        return "\(header).\(body).sig"
    }

    // MARK: - Summary mapping

    func testMapSummaryUsesPlanUsageForWeeklyLimit() throws {
        let json = """
        {
          "billingCycleStart": "2026-07-01T00:00:00Z",
          "billingCycleEnd": "2026-08-01T00:00:00Z",
          "membershipType": "pro",
          "individualUsage": {
            "plan": { "used": 137, "total": 500 },
            "onDemand": { "used": 4, "limit": 20, "enabled": true }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.service, .cursor)
        XCTAssertEqual(metrics.weeklyLimit?.used, 137)
        XCTAssertEqual(metrics.weeklyLimit?.total, 500)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, false)
        XCTAssertEqual(metrics.weeklyLimit?.resetTime, FlexibleISO8601.date(from: "2026-08-01T00:00:00Z"))
        XCTAssertEqual(metrics.sessionLimit?.used, 4)
        XCTAssertEqual(metrics.sessionLimit?.total, 20)
        XCTAssertEqual(metrics.sessionLimit?.isEstimated, false)
    }

    func testMapSummarySubstitutesDefaultPlanTotalWhenMissing() throws {
        // When the API omits the plan total, the assumed monthly quota (500) is used.
        let json = """
        { "individualUsage": { "plan": { "used": 50 } } }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertEqual(metrics.weeklyLimit?.used, 50)
        XCTAssertEqual(metrics.weeklyLimit?.total, 500)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, true)
    }

    func testMapSummaryOmitsSessionLimitWhenOnDemandDisabled() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 10, "total": 500 },
            "onDemand": { "used": 5, "limit": 20, "enabled": false }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertNil(metrics.sessionLimit)
    }

    func testMapSummaryUsesHeadroomEstimateWhenOnDemandLimitZero() throws {
        // enabled + used>0 but limit==0 → total falls back to used * 1.5 headroom.
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 10, "total": 500 },
            "onDemand": { "used": 8, "limit": 0, "enabled": true }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertEqual(metrics.sessionLimit?.used, 8)
        XCTAssertEqual(metrics.sessionLimit?.total ?? 0, 12, accuracy: 0.0001)
        XCTAssertEqual(metrics.sessionLimit?.isEstimated, true)
    }

    func testMapSummaryOmitsSessionLimitWhenOnDemandAllZero() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 10, "total": 500 },
            "onDemand": { "used": 0, "limit": 0, "enabled": true }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertNil(metrics.sessionLimit)
    }

    // MARK: - JWT userId extraction

    func testExtractUserIdSplitsAuth0PrefixedSub() {
        let token = makeJWT(sub: "auth0|user-abc123")
        XCTAssertEqual(CursorLocalService.extractUserIdFromJWT(token), "user-abc123")
    }

    func testExtractUserIdReturnsPlainSub() {
        let token = makeJWT(sub: "user-xyz")
        XCTAssertEqual(CursorLocalService.extractUserIdFromJWT(token), "user-xyz")
    }

    func testExtractUserIdReturnsNilForMalformedToken() {
        XCTAssertNil(CursorLocalService.extractUserIdFromJWT("not-a-jwt"))
    }
}
