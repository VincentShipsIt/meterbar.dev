import AppKit
import MeterBarShared
@testable import MeterBar
import SwiftUI
import XCTest

/// The widget row existed in three hand-rolled copies: `ServiceMiniView` and
/// `ServiceCompactView` in the extension, and `WidgetSettingsPreviewRow` here in
/// the app. They disagreed on icon source (asset logo vs SF Symbol), font sizes
/// (8pt vs 7/9pt), whether a health glyph appeared at all, and how a status
/// became a color. A settings preview that does not match the widget is worse
/// than no preview.
///
/// The extension's views cannot be hosted in this test target — see the note in
/// `WidgetRenderingTests` — but the preview's *are* in the app target, so this
/// pins the preview to the one shared vocabulary both now read from. If the
/// preview drifts, these fail; if the extension drifts, it stops compiling
/// against `WidgetGlance`.
@MainActor
final class WidgetSettingsPreviewParityTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - One vocabulary

    func testPreviewRowDrawsAtTheWidgetSizes() {
        for family in WidgetPresentationFamily.allCases {
            let row = WidgetSettingsPreviewRow(row: firstRow(family: family), family: family)
            XCTAssertEqual(
                row.metrics,
                WidgetGlance.metrics(for: family),
                "\(family): the preview must draw at the sizes the widget draws at"
            )
        }
    }

    func testPreviewSurfaceUsesTheGlanceContentPadding() {
        for family in WidgetPresentationFamily.allCases {
            let surface = WidgetSettingsPreviewSurface(
                family: family,
                presentation: presentation(family: family),
                appearance: .light
            )
            XCTAssertEqual(
                surface.metrics.contentPadding,
                WidgetGlance.metrics(for: family).contentPadding,
                "\(family): the preview inset must match the widget's"
            )
        }
    }

    /// The small preview has to show the hero, not three stacked mini rows —
    /// otherwise it advertises a layout the widget no longer draws.
    func testSmallPreviewShowsTheHeroLayout() {
        let surface = WidgetSettingsPreviewSurface(
            family: .small,
            presentation: presentation(family: .small),
            appearance: .light
        )
        guard case .hero = surface.layout else {
            return XCTFail("the small preview must render the widget's hero layout")
        }
    }

    func testWiderPreviewsStackRows() {
        for family in [WidgetPresentationFamily.medium, .large] {
            let surface = WidgetSettingsPreviewSurface(
                family: family,
                presentation: presentation(family: family),
                appearance: .light
            )
            guard case .rows = surface.layout else {
                return XCTFail("\(family) has room for stacked rows")
            }
        }
    }

    // MARK: - One severity → color map

    /// The preview used to carry a private `UsageStatus` → `Color` switch of its
    /// own, so a theme change moved every other surface and left the widget
    /// preview behind. It now reads the same map as `QuotaBand.color`.
    func testStatusColorComesFromTheSameMapAsEverySurface() {
        let pairs: [(QuotaBand, UsageStatus)] = [
            (.healthy, .good),
            (.tight, .warning),
            (.critical, .critical),
            (.exhausted, .critical)
        ]
        for (band, status) in pairs {
            XCTAssertEqual(
                status.color,
                band.color,
                "\(band) must tint the widget preview the same as it tints a card"
            )
        }
    }

    // MARK: - It still draws

    func testEveryPreviewFamilyRenders() {
        for family in WidgetPresentationFamily.allCases {
            let host = NSHostingView(
                rootView: WidgetSettingsPreviewSurface(
                    family: family,
                    presentation: presentation(family: family),
                    appearance: .light
                )
            )
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0, "\(family) preview rendered empty")
        }
    }

    func testBurnDownPreviewRendersSupportedFamiliesInLightAndDark() {
        for family in [WidgetPresentationFamily.small, .medium] {
            let burnDown = WidgetBurnDownPlanner.makePresentation(
                metrics: [
                    .claudeCode: UsageMetrics(
                        service: .claudeCode,
                        weeklyLimit: UsageLimit(
                            used: 72,
                            total: 100,
                            resetTime: now.addingTimeInterval(2.5 * 24 * 60 * 60),
                            windowSeconds: 7 * 24 * 60 * 60
                        ),
                        lastUpdated: now
                    )
                ],
                accountMetrics: [],
                preferences: .defaults,
                family: family,
                now: now
            )
            for appearance in [WidgetSettingsPreviewAppearance.light, .dark] {
                let host = NSHostingView(
                    rootView: WidgetSettingsBurnDownPreviewSurface(
                        family: family,
                        presentation: burnDown,
                        appearance: appearance
                    )
                )
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(host.fittingSize.height, 0, "\(family) \(appearance)")
            }
        }
    }

    // MARK: - Fixtures

    private func presentation(family: WidgetPresentationFamily) -> WidgetPresentation {
        WidgetPresentationPlanner.makePresentation(
            metrics: [
                .claudeCode: makeMetrics(.claudeCode, weeklyUsed: 72),
                .codexCli: makeMetrics(.codexCli, weeklyUsed: 18)
            ],
            accountMetrics: [],
            preferences: .defaults,
            family: family,
            now: now
        )
    }

    private func firstRow(family: WidgetPresentationFamily) -> WidgetPresentationRow {
        guard let row = presentation(family: family).rows.first else {
            preconditionFailure("fixture must plan at least one row")
        }
        return row
    }

    private func makeMetrics(_ service: ServiceType, weeklyUsed: Double) -> UsageMetrics {
        UsageMetrics(
            service: service,
            weeklyLimit: UsageLimit(used: weeklyUsed, total: 100, resetTime: nil),
            lastUpdated: now
        )
    }
}
