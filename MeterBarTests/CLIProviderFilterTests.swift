import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// `--provider` is a substring filter shared by `meterbar usage` and
/// `meterbar doctor`. A filter that matches nothing selects nothing, and both
/// commands say so — an empty report otherwise reads like "no quota data".
final class CLIProviderFilterTests: XCTestCase {
    func testNoFilterSelectsEveryProvider() {
        XCTAssertEqual(CLIProviderFilter.select(nil), Set(ServiceType.allCases))
        XCTAssertEqual(CLIProviderFilter.select(""), Set(ServiceType.allCases))
        XCTAssertEqual(CLIProviderFilter.select("   "), Set(ServiceType.allCases))
    }

    func testFilterMatchesRawValueOrDisplayNameCaseInsensitively() {
        XCTAssertEqual(CLIProviderFilter.select("claude"), [.claudeCode])
        XCTAssertEqual(CLIProviderFilter.select("CLAUDE"), [.claudeCode])
        XCTAssertEqual(CLIProviderFilter.select(" Cursor "), [.cursor])
        XCTAssertEqual(CLIProviderFilter.select("router"), [.openRouter])
    }

    func testAnUnmatchedFilterSelectsNothingRatherThanEverything() {
        XCTAssertTrue(CLIProviderFilter.select("clod").isEmpty)
        XCTAssertTrue(CLIProviderFilter.select("gpt-4").isEmpty)
    }

    func testTheEmptySelectionMessageIsSharedSoBothCommandsAgree() {
        XCTAssertFalse(CLIProviderFilter.noMatchesMessage.isEmpty)
    }

    func testAnEmptyReportBlamesTheTypoOnlyWhenTheFilterNamesNoProvider() {
        XCTAssertEqual(CLIProviderFilter.emptyReportMessage(for: "clod"), CLIProviderFilter.noMatchesMessage)
        XCTAssertEqual(CLIProviderFilter.emptyReportMessage(for: "gpt-4"), CLIProviderFilter.noMatchesMessage)
    }

    func testAKnownProviderWithNoCachedDataSaysSoInsteadOfDenyingItExists() {
        let message = CLIProviderFilter.emptyReportMessage(for: "cursor")

        XCTAssertNotEqual(message, CLIProviderFilter.noMatchesMessage)
        XCTAssertTrue(message.contains(ServiceType.cursor.displayName), message)
        XCTAssertTrue(message.contains("meterbar refresh"), message)
    }

    func testTheEmptyReportMessageNamesEveryProviderTheFilterSelected() {
        // "code" matches more than one provider, so the advice has to cover
        // all of them rather than pick one arbitrarily.
        let selected = CLIProviderFilter.select("code")
        XCTAssertGreaterThan(selected.count, 1)

        let message = CLIProviderFilter.emptyReportMessage(for: "code")
        for service in selected {
            XCTAssertTrue(message.contains(service.displayName), "\(service) missing from: \(message)")
        }
    }

    func testSelectionFiltersACachedMetricsSnapshot() {
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: metric(.claudeCode),
            .cursor: metric(.cursor)
        ]

        XCTAssertEqual(Set(CLIProviderFilter.apply("cursor", to: metrics).keys), [.cursor])
        XCTAssertEqual(Set(CLIProviderFilter.apply(nil, to: metrics).keys), [.claudeCode, .cursor])
        XCTAssertTrue(CLIProviderFilter.apply("clod", to: metrics).isEmpty)
    }

    private func metric(_ service: ServiceType) -> UsageMetrics {
        UsageMetrics(
            service: service,
            weeklyLimit: UsageLimit(used: 1, total: 100, resetTime: nil),
            lastUpdated: Date()
        )
    }
}
