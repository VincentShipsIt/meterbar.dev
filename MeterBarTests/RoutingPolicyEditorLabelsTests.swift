import MeterBarShared
import XCTest

@testable import MeterBar

final class RoutingPolicyEditorLabelsTests: XCTestCase {
    func testEveryChoiceHasAUniqueReadableTitle() {
        assertUnique(RoutingProviderScope.allCases.map(\.title))
        assertUnique(RoutingAccountSelection.allCases.map(\.title))
        assertUnique(RoutingModelTier.allCases.map(\.title))
        assertUnique(RoutingCostPreference.allCases.map(\.title))
        assertUnique(RoutingFallbackOrder.allCases.map(\.title))
    }

    func testTitlesNeverExposeTheStoredRawValue() {
        XCTAssertFalse(RoutingProviderScope.allCases.map(\.title).contains("preferredOnly"))
        XCTAssertFalse(RoutingFallbackOrder.allCases.map(\.title).contains("policyPreference"))
    }

    func testHelpTextExistsWhereTheEditorShowsIt() {
        for scope in RoutingProviderScope.allCases { XCTAssertFalse(scope.help.isEmpty) }
        for selection in RoutingAccountSelection.allCases { XCTAssertFalse(selection.help.isEmpty) }
        for cost in RoutingCostPreference.allCases { XCTAssertFalse(cost.help.isEmpty) }
    }

    private func assertUnique(_ titles: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty }, file: file, line: line)
        XCTAssertEqual(Set(titles).count, titles.count, file: file, line: line)
    }
}
