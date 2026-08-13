import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Grok usage-limit resets arrive from grok.com `ConsumerUiSvc/GetRemainingResets`
/// as grpc-web protobuf. Weekly quota still comes from official `_x.ai/billing`.
final class GrokResetCreditsTests: XCTestCase {
    /// Captured 2026-08-13 from a SuperGrok Heavy account with one reset
    /// expiring 2026-09-12T18:49:00Z (`restok_vpYDqo`).
    private static let liveGrpcWebResponse = Data([
        0x00, 0x00, 0x00, 0x00, 0x23,
        0x52, 0x21, 0x52, 0x0D, 0x72, 0x65, 0x73, 0x74, 0x6F, 0x6B, 0x5F,
        0x76, 0x70, 0x59, 0x44, 0x71, 0x6F,
        0xA2, 0x01, 0x06, 0x08, 0x9C, 0x80, 0xF3, 0xD3, 0x06,
        0xF2, 0x01, 0x06, 0x08, 0x9C, 0xBD, 0x96, 0xD5, 0x06,
        0x80, 0x00, 0x00, 0x00, 0x0F,
        0x67, 0x72, 0x70, 0x63, 0x2D, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x3A, 0x30, 0x0D, 0x0A
    ])

    func testLiveGrpcWebFixtureDecodesOneUnexpiredReset() throws {
        let now = try XCTUnwrap(FlexibleISO8601.date(from: "2026-08-13T12:00:00Z"))
        let resets = try GrokResetCredits.decode(grpcWeb: Self.liveGrpcWebResponse, now: now)

        XCTAssertEqual(resets.tokens.map(\.tokenID), ["restok_vpYDqo"])
        XCTAssertEqual(resets.tokens.first?.validFrom, Date(timeIntervalSince1970: 1_786_560_540))
        XCTAssertEqual(resets.tokens.first?.expiresAt, Date(timeIntervalSince1970: 1_789_238_940))
        XCTAssertEqual(resets.availableCount, 1)
    }

    func testExpiredTokensAreNotCountedAsAvailable() throws {
        let afterExpiry = try XCTUnwrap(FlexibleISO8601.date(from: "2026-09-13T00:00:00Z"))
        let resets = try GrokResetCredits.decode(grpcWeb: Self.liveGrpcWebResponse, now: afterExpiry)

        XCTAssertEqual(resets.tokens.count, 1)
        XCTAssertEqual(resets.availableCount, 0)
    }

    func testEmptyProtobufMessageMeansZeroResets() throws {
        let empty = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        let resets = try GrokResetCredits.decode(grpcWeb: empty, now: Date())

        XCTAssertTrue(resets.tokens.isEmpty)
        XCTAssertEqual(resets.availableCount, 0)
    }

    func testAccessTokenIsReadFromTheCachedLoginWithoutRequiringAJWTShape() {
        let data = Data(#"{"https://auth.x.ai::client":{"key":"cached-access-token","auth_mode":"oidc"}}"#.utf8)

        XCTAssertEqual(GrokResetCredits.accessToken(from: data), "cached-access-token")
    }

    func testExpiredJWTAccessTokenIsIgnored() {
        // exp = 1_000_000_000 → 2001-09-09. Malformed tokens stay usable so the
        // server can still be the source of truth; a parseable past exp must not.
        let payload = Data(#"{"exp":1000000000}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJub25lIn0.\(payload).sig"
        let data = Data(#"{"https://auth.x.ai::client":{"key":"\#(jwt)"}}"#.utf8)

        XCTAssertNil(GrokResetCredits.accessToken(from: data, now: Date()))
    }

    func testMissingOrEmptyAuthFileYieldsNoToken() {
        XCTAssertNil(GrokResetCredits.accessToken(from: nil))
        XCTAssertNil(GrokResetCredits.accessToken(from: Data(#"{}"#.utf8)))
        XCTAssertNil(GrokResetCredits.accessToken(from: Data(#"{"https://auth.x.ai::client":{}}"#.utf8)))
    }

    func testMapAttachesResetCountWhenProvided() throws {
        let result = try JSONDecoder().decode(
            GrokBillingResult.self,
            from: Data(#"{"config":{"creditUsagePercent":16,"billingPeriodStart":"2026-08-12T15:05:27Z","billingPeriodEnd":"2026-08-19T15:05:27Z"}}"#.utf8)
        )

        let metrics = try GrokCLIUsageService.map(result).withResetCreditsAvailable(1)

        XCTAssertEqual(metrics.weeklyLimit?.used, 16)
        XCTAssertEqual(metrics.resetCreditsAvailable, 1)
    }

    func testFetchAttachesResetCountAndSurvivesAResetTransportFailure() async throws {
        let billing = try JSONDecoder().decode(
            GrokBillingResult.self,
            from: Data(#"{"config":{"creditUsagePercent":16,"billingPeriodStart":"2026-08-12T15:05:27Z","billingPeriodEnd":"2026-08-19T15:05:27Z"}}"#.utf8)
        )
        let auth = Data(#"{"https://auth.x.ai::client":{"key":"cached-access-token"}}"#.utf8)

        let ok = GrokCLIUsageService(
            binaryPathProvider: { "/usr/local/bin/grok" },
            authAvailableProvider: { _ in true },
            billingResultProvider: { _, _ in billing },
            authFileDataProvider: { _ in auth },
            remainingResetsProvider: { token in
                XCTAssertEqual(token, "cached-access-token")
                return 1
            }
        )
        let okMetrics = try await ok.fetchUsageMetrics()
        XCTAssertEqual(okMetrics.resetCreditsAvailable, 1)

        let failed = GrokCLIUsageService(
            binaryPathProvider: { "/usr/local/bin/grok" },
            authAvailableProvider: { _ in true },
            billingResultProvider: { _, _ in billing },
            authFileDataProvider: { _ in auth },
            remainingResetsProvider: { _ in nil }
        )
        let failedMetrics = try await failed.fetchUsageMetrics()
        XCTAssertEqual(failedMetrics.weeklyLimit?.used, 16)
        XCTAssertNil(failedMetrics.resetCreditsAvailable)
    }
}
