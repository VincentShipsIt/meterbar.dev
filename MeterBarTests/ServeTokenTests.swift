import XCTest
@testable import MeterBar

final class ServeTokenTests: XCTestCase {
    func testGeneratedTokensAreSixtyFourHexCharacters() {
        let token = ServeToken.generate()

        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
    }

    func testGeneratedTokensAreNotRepeated() {
        let first = ServeToken.generate()
        let second = ServeToken.generate()

        XCTAssertNotEqual(first, second)
    }

    func testMatchesAcceptsCorrectBearerToken() {
        XCTAssertTrue(ServeToken.matches(presented: "Bearer secret-token", expected: "secret-token"))
    }

    func testMatchesRejectsWrongToken() {
        XCTAssertFalse(ServeToken.matches(presented: "Bearer wrong-token", expected: "secret-token"))
    }

    func testMatchesRejectsMissingHeader() {
        XCTAssertFalse(ServeToken.matches(presented: nil, expected: "secret-token"))
    }

    func testMatchesRejectsHeaderWithoutBearerScheme() {
        XCTAssertFalse(ServeToken.matches(presented: "secret-token", expected: "secret-token"))
        XCTAssertFalse(ServeToken.matches(presented: "Basic secret-token", expected: "secret-token"))
    }

    func testMatchesRejectsDifferingLengthTokens() {
        XCTAssertFalse(ServeToken.matches(presented: "Bearer short", expected: "much-longer-secret-token"))
    }

    func testMatchesRejectsEmptyPresentedToken() {
        XCTAssertFalse(ServeToken.matches(presented: "Bearer ", expected: "secret-token"))
    }
}
