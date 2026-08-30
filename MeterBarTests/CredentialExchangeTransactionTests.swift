import Foundation
import XCTest
@testable import MeterBar

final class CredentialExchangeTransactionTests: XCTestCase {
    func testExchangesPayloadsWithoutCreatingAThirdCopy() throws {
        var storage = ["live": Data("primary".utf8), "fallback": Data("secondary".utf8)]

        try CredentialExchangeTransaction.exchange(
            source: "live",
            target: "fallback",
            read: { storage[$0] },
            write: { storage[$0] = $1 }
        )

        XCTAssertEqual(storage["live"], Data("secondary".utf8))
        XCTAssertEqual(storage["fallback"], Data("primary".utf8))
        XCTAssertEqual(Set(storage.keys), ["live", "fallback"])
    }

    func testSecondWriteFailureRollsBackFirstStore() {
        enum Failure: Error { case write }
        var storage = ["live": Data("primary".utf8), "fallback": Data("secondary".utf8)]

        XCTAssertThrowsError(
            try CredentialExchangeTransaction.exchange(
                source: "live",
                target: "fallback",
                read: { storage[$0] },
                write: { location, payload in
                    if location == "fallback" { throw Failure.write }
                    storage[location] = payload
                }
            )
        )

        XCTAssertEqual(storage["live"], Data("primary".utf8))
        XCTAssertEqual(storage["fallback"], Data("secondary".utf8))
    }

    func testMissingCredentialFailsBeforeAnyWrite() {
        var writes = 0

        XCTAssertThrowsError(
            try CredentialExchangeTransaction.exchange(
                source: "live",
                target: "fallback",
                read: { $0 == "live" ? Data("primary".utf8) : nil },
                write: { _, _ in writes += 1 }
            )
        )

        XCTAssertEqual(writes, 0)
    }
}
