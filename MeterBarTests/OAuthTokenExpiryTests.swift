import XCTest
@testable import MeterBar
import MeterBarShared

final class OAuthTokenExpiryTests: XCTestCase {
    func testJWTExpiryUsesGraceInterval() {
        let now = Date(timeIntervalSince1970: 1_800)
        let tokenExpiringSoon = makeJWT(expiration: 1_830)
        let tokenExpiringLater = makeJWT(expiration: 1_920)

        XCTAssertTrue(OAuthTokenExpiry.isExpired(jwt: tokenExpiringSoon, graceInterval: 60, now: now))
        XCTAssertFalse(OAuthTokenExpiry.isExpired(jwt: tokenExpiringLater, graceInterval: 60, now: now))
    }

    func testMalformedJWTIsTreatedAsUnknownNotExpired() {
        XCTAssertFalse(OAuthTokenExpiry.isExpired(jwt: "not-a-jwt", now: Date(timeIntervalSince1970: 1_800)))
    }

    func testUnixTimestampSupportsSeconds() {
        let seconds = Int64(1_800)

        XCTAssertEqual(
            OAuthTokenExpiry.expirationDate(fromUnixTimestamp: seconds),
            Date(timeIntervalSince1970: 1_800)
        )
    }

    func testLargeUnixTimestampSupportsMilliseconds() {
        let milliseconds = Int64(1_800_000_000_000)

        XCTAssertEqual(
            OAuthTokenExpiry.expirationDate(fromUnixTimestamp: milliseconds),
            Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func makeJWT(expiration: TimeInterval) -> String {
        let payload = #"{"exp":\#(Int(expiration))}"#
        return "header.\(base64URL(payload)).signature"
    }

    private func base64URL(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
