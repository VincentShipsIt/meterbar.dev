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
        XCTAssertEqual(
            Set(metrics.keys),
            Set(ServiceType.allCases),
            "the canonical fixture must cover every ServiceType"
        )

        for service in ServiceType.allCases {
            guard let providerMetrics = metrics[service] else {
                XCTFail("no fixture metrics for \(service)")
                continue
            }
            for family in WidgetFamily.allCases {
                let rendered = renderedServices([service: providerMetrics], family: family)
                XCTAssertEqual(rendered, [service], "family \(family) failed to render \(service)")
            }
            assertRowRendersNonEmpty(service, metrics: providerMetrics)
        }

        for family in WidgetPresentationFamily.allCases {
            let presentation = WidgetPresentationPlanner.makePresentation(
                metrics: metrics,
                accountMetrics: [],
                preferences: .defaults,
                family: family,
                now: MetricsFixtures.referenceDate
            )
            XCTAssertFalse(presentation.rows.isEmpty, "\(family) planned no rows from the all-provider fixture")
            XCTAssertTrue(
                Set(presentation.rows.map(\.service)).isSubset(of: Set(ServiceType.allCases)),
                "\(family) invented an unknown provider"
            )
        }
    }

    func testEachProviderRendersIndividually() {
        for (service, metrics) in MetricsFixtures.allProviders() {
            for family in WidgetFamily.allCases {
                let rendered = renderedServices([service: metrics], family: family)
                XCTAssertEqual(rendered, [service], "family \(family) failed to render \(service)")
            }
            assertRowRendersNonEmpty(service, metrics: metrics)
        }
    }

    // MARK: - Sort + cap behavior

    func testProvidersRenderInStableSortOrder() {
        let metrics = MetricsFixtures.allProviders()
        let expected = ServiceType.allCases.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(renderedServices(metrics, family: .large), expected)
        XCTAssertEqual(
            renderedServices(metrics, family: .medium),
            Array(expected.prefix(WidgetFamily.medium.visibleRowCount(totalRowCount: expected.count)))
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
