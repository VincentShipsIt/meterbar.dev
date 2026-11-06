import Foundation
import XCTest
@testable import MeterBar

final class AccountOrderTests: XCTestCase {
    private let ids = ["a", "b", "c", "d"]

    func testMovesARowDownUsingThePreRemovalDestination() {
        XCTAssertEqual(AccountOrder.moving(ids, fromOffsets: IndexSet(integer: 0), toOffset: 3), ["b", "c", "a", "d"])
    }

    func testMovesARowToTheTop() {
        XCTAssertEqual(AccountOrder.moving(ids, fromOffsets: IndexSet(integer: 2), toOffset: 0), ["c", "a", "b", "d"])
    }

    func testMovesSeveralRowsTogetherInTheirOriginalOrder() {
        XCTAssertEqual(
            AccountOrder.moving(ids, fromOffsets: IndexSet([0, 2]), toOffset: 4),
            ["b", "d", "a", "c"]
        )
    }

    func testClampsADestinationPastTheEnd() {
        XCTAssertEqual(AccountOrder.moving(ids, fromOffsets: IndexSet(integer: 1), toOffset: 99), ["a", "c", "d", "b"])
    }

    func testRejectsAnOutOfRangeOffset() {
        XCTAssertNil(AccountOrder.moving(ids, fromOffsets: IndexSet(integer: 4), toOffset: 0))
    }

    func testRejectsAnEmptyList() {
        XCTAssertNil(AccountOrder.moving([String](), fromOffsets: IndexSet(), toOffset: 0))
    }
}
