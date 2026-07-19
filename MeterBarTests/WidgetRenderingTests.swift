import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Widget rendering validation (issue #18, absorbing #29's remainder).
///
/// The widget views (`MeterBarWidget/UsageWidget.swift`) live in the app-extension
/// target, which is not part of the SwiftPM package the CI test target builds, so
/// the SwiftUI views cannot be imported and rendered here. Instead this validates
/// the exact **data → presentation contract** those views render from — every
/// value the small / medium / large layouts display for a provider derives from
/// the `MeterBarShared` primitives asserted below — plus the per-family service
/// selection the layouts apply. A regression in any of these (a nil percentage, an
/// empty display name, a broken sort, a lost provider) would blank a widget row.
///
/// The family caps below exercise the same shared budget used by
/// `WidgetPresentationPlanner`; focused preference/window/state coverage lives
/// in `WidgetPresentationTests`.
final class WidgetRenderingTests: XCTestCase {
    private enum WidgetFamily: CaseIterable {
        case small, medium, large

        func visibleRowCount(totalRowCount: Int) -> Int {
            WidgetFamilyRowBudget.plan(
                totalRowCount: totalRowCount,
                family: presentationFamily
            ).visibleRowCount
        }

        private var presentationFamily: WidgetPresentationFamily {
            switch self {
            case .small: return .small
            case .medium: return .medium
            case .large: return .large
            }
        }
    }

    /// Mirrors `UsageWidgetEntry.sortedServices` + the per-family prefix cap.
    private func renderedServices(
        _ metrics: [ServiceType: UsageMetrics],
        family: WidgetFamily
    ) -> [ServiceType] {
        let sorted = metrics.keys.sorted { $0.sortOrder < $1.sortOrder }
        return Array(sorted.prefix(family.visibleRowCount(totalRowCount: sorted.count)))
    }

    /// Asserts a single provider's metrics yield a fully-populated widget row.
    private func assertRowRendersNonEmpty(
        _ service: ServiceType,
        metrics: UsageMetrics,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(metrics.service, service, file: file, line: line)
        XCTAssertFalse(service.displayName.isEmpty, "empty displayName for \(service)", file: file, line: line)
        XCTAssertFalse(service.assetName.isEmpty, "empty widget asset for \(service)", file: file, line: line)

        // Every layout renders the weekly progress bar + percentage label.
        let weekly = metrics.weeklyLimit
        XCTAssertNotNil(weekly, "missing weeklyLimit for \(service)", file: file, line: line)
        if let weekly {
            XCTAssertTrue(weekly.percentage.isFinite, "non-finite percentage for \(service)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(weekly.percentage, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(weekly.clampedTotal, weekly.clampedUsed, file: file, line: line)
        }

        // The status dot must resolve to a defined state. An exhaustive switch
        // (rather than Equatable, which UsageStatus doesn't declare) also forces
        // this assertion to be revisited if a status case is ever added.
        let statusIsDefined: Bool
        switch metrics.overallStatus {
        case .good, .warning, .critical:
            statusIsDefined = true
        }
        XCTAssertTrue(statusIsDefined, "undefined status for \(service)", file: file, line: line)
    }

    // MARK: - Populated fixtures render for every family × provider

    func testAllFamiliesRenderNonEmptyForEveryProvider() {
        let metrics = MetricsFixtures.allProviders()

        for family in WidgetFamily.allCases {
            let services = renderedServices(metrics, family: family)
            XCTAssertEqual(
                Set(services),
                Set(metrics.keys),
                "family \(family) dropped a provider (cap too low for the fixture set)"
            )
            for service in services {
                guard let providerMetrics = metrics[service] else {
                    XCTFail("no fixture metrics for rendered service \(service)")
                    continue
                }
                assertRowRendersNonEmpty(service, metrics: providerMetrics)
            }
        }
    }

    func testEachProviderRendersIndividually() {
        // Every CLI-backed provider renders a populated row on its own.
        let cases: [(ServiceType, UsageMetrics)] = [
            (.claudeCode, MetricsFixtures.claudeCode()),
            (.codexCli, MetricsFixtures.codexCli()),
            (.cursor, MetricsFixtures.cursor()),
            (.grok, MetricsFixtures.grok())
        ]
        for (service, metrics) in cases {
            for family in WidgetFamily.allCases {
                let rendered = renderedServices([service: metrics], family: family)
                XCTAssertEqual(rendered, [service], "family \(family) failed to render \(service)")
            }
            assertRowRendersNonEmpty(service, metrics: metrics)
        }
    }

    // MARK: - Sort + cap behavior

    func testProvidersRenderInStableSortOrder() {
        // Regardless of insertion order, rows render Claude → Codex → Cursor.
        let metrics = MetricsFixtures.allProviders()
        XCTAssertEqual(
            renderedServices(metrics, family: .medium),
            [.claudeCode, .codexCli, .cursor]
        )
    }

    func testMediumWidgetReservesAThirdSlotForOverflowSummary() {
        let totalRowCount = 6
        let visibleRowCount = WidgetFamily.medium.visibleRowCount(totalRowCount: totalRowCount)

        XCTAssertEqual(visibleRowCount, 2)
        XCTAssertEqual(
            WidgetFamilyRowBudget.plan(totalRowCount: totalRowCount, family: .medium).hiddenRowCount,
            4
        )
    }

    // MARK: - Empty state

    func testEmptyMetricsProduceEmptyWidgetState() {
        // With no metrics the widget shows its "No data" / "No services connected"
        // empty branch — i.e. there are zero rows to render for any family.
        for family in WidgetFamily.allCases {
            XCTAssertTrue(renderedServices([:], family: family).isEmpty)
        }
    }
}
