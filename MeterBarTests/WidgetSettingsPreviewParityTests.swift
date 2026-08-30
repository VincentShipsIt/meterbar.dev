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

    func testSmallBlockedIndependentPoolNamesThePoolInTheSupportRail() throws {
        var preferences = WidgetPreferences.defaults
        preferences.visibleQuotaWindows = [.weekly]
        let presentation = WidgetPresentationPlanner.makePresentation(
            metrics: [
                .claudeCode: UsageMetrics(
                    service: .claudeCode,
                    weeklyLimit: UsageLimit(used: 10, total: 100, resetTime: nil),
                    lastUpdated: now
                ),
                .cursor: UsageMetrics(
                    service: .cursor,
                    sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil),
                    weeklyLimit: UsageLimit(used: 20, total: 100, resetTime: nil),
                    additionalLimits: [
                        UsageLimit(used: 100, total: 100, resetTime: nil, periodKind: .weekly)
                    ],
                    lastUpdated: now
                ),
            ],
            accountMetrics: [],
            preferences: preferences,
            family: .small,
            now: now
        )

        guard case let .hero(headline, supporting) = WidgetGlance.layout(
            for: presentation,
            family: .small
        ) else {
            return XCTFail("small must use the hero and support-rail layout")
        }
        XCTAssertEqual(headline.service, .claudeCode)
        XCTAssertFalse(headline.isBlocked)

        let cursorPrimary = try XCTUnwrap(supporting.first { !$0.isAdditionalLimit })
        XCTAssertEqual(cursorPrimary.accountName, "Cursor")
        XCTAssertFalse(cursorPrimary.isBlocked)
        XCTAssertNil(cursorPrimary.compactIdentityQuotaTitleKey)

        let grokBot = try XCTUnwrap(supporting.first { $0.quotaTitleKey == .grokBot })
        XCTAssertEqual(grokBot.accountName, "Cursor", "the source account remains Cursor")
        XCTAssertTrue(grokBot.isBlocked)
        XCTAssertEqual(grokBot.compactIdentityQuotaTitleKey, .grokBot)

        let expectedIdentity = LocalizedUsageFormat.quotaTitle(for: .grokBot)
        let rail = WidgetSettingsPreviewRailRow(
            row: grokBot,
            metrics: WidgetGlance.metrics(for: .small)
        )
        XCTAssertEqual(rail.compactIdentityText, expectedIdentity)
        XCTAssertEqual(
            LocalizedUsageFormat.widgetCompactIdentity(for: grokBot),
            expectedIdentity,
            "visual text and VoiceOver label must identify the exhausted sub-pool"
        )
        XCTAssertNotEqual(expectedIdentity, grokBot.accountName)
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

    // MARK: - One language

    /// The preview used to print the shared model's hardcoded English `title`
    /// and `detail` while the widget beside it drew localized copy — so on a
    /// non-English Mac, Settings advertised a widget in the wrong language.
    /// Both preview surfaces now read the same keys the extension does.
    func testPreviewEmptyStatesUseTheLocalizedWidgetCopy() {
        for state in [WidgetPresentationEmptyState.noSelection, .unavailable] {
            let expected = WidgetSettingsPreviewEmptyStateText(state)
            XCTAssertEqual(expected.title, LocalizedUsageFormat.widgetEmptyTitle(state))
            XCTAssertEqual(expected.detail, LocalizedUsageFormat.widgetEmptyDetail(state))

            let glance = WidgetSettingsPreviewSurface(
                family: .medium,
                presentation: emptyPresentation(state),
                appearance: .light
            )
            XCTAssertEqual(glance.presentation.emptyState, state, "\(state) glance fixture")
            XCTAssertEqual(glance.emptyStateText, expected, "\(state) glance preview")

            let burnDown = WidgetSettingsBurnDownPreviewSurface(
                family: .medium,
                presentation: emptyBurnDownPresentation(state),
                appearance: .light
            )
            XCTAssertEqual(burnDown.presentation.emptyState, state, "\(state) burn-down fixture")
            XCTAssertEqual(burnDown.emptyStateText, expected, "\(state) burn-down preview")
        }
    }

    /// The preview used to print the shared model's English `quotaTitle` while
    /// the widget localized `quotaTitleKey`. Both preview surfaces now ask
    /// the same formatter the widget uses, including verbatim model labels.
    func testPreviewQuotaTitlesUseTheSharedRoutingKey() {
        let cases: [(ServiceType, WidgetQuotaWindow, Double, String?)] = [
            (.claudeCode, .weekly, 100, nil),
            (.claudeCode, .codeReview, 100, "Fable"),
            (.claudeCode, .codeReview, 100, nil),
            (.cursor, .session, ServiceType.cursorIncludedPoolTotal, nil),
            (.cursor, .weekly, ServiceType.cursorIncludedPoolTotal, nil),
            (.cursor, .codeReview, 40, nil),
            (.openRouter, .session, 10, nil),
            (.openRouter, .weekly, 10, nil),
            (.codexCli, .session, 100, nil),
            (.grok, .weekly, 100, nil),
        ]
        for (service, window, total, modelLabel) in cases {
            let row = plannedQuotaRow(
                service: service,
                window: window,
                total: total,
                modelLabel: modelLabel
            )
            let expected = LocalizedUsageFormat.quotaTitle(for: row.quotaTitleKey)
            let preview = WidgetSettingsPreviewRow(row: row, family: .medium)
            XCTAssertEqual(preview.quotaTitleText, expected, "\(service) \(window)")

            let burnDown = WidgetSettingsBurnDownPreviewRow(
                row: WidgetBurnDownRow(
                    row: row,
                    stage: .onPace,
                    stageText: "On pace",
                    countdownKind: .reset,
                    countdownTitle: LocalizedUsageFormat.burnDownCountdownTitle(.reset),
                    countdownTarget: nil,
                    countdownText: "2h 5m"
                ),
                family: .medium
            )
            XCTAssertEqual(burnDown.quotaTitleText, expected, "burn-down \(service) \(window)")
            XCTAssertEqual(expected, row.quotaTitleKey.englishTitle, "\(service) \(window) English")
        }
    }

    /// The preview inlined the widget's `"Unavailable"` sentinel check instead
    /// of asking the shared formatter, which is two copies of one rule.
    func testBurnDownPreviewCountdownMatchesTheSharedFallback() {
        let cases: [(WidgetBurnDownCountdownKind, String)] = [
            (.unavailable, "2h 5m"),
            (.reset, "Unavailable"),
            (.reset, "2h 5m"),
            (.projectedExhaustion, "45m")
        ]
        for (kind, countdownText) in cases {
            let preview = WidgetSettingsBurnDownPreviewRow(
                row: burnDownRow(kind: kind, countdownText: countdownText),
                family: .medium
            )
            XCTAssertEqual(
                preview.countdownText,
                LocalizedUsageFormat.burnDownCountdownText(kind: kind, fallback: countdownText),
                "\(kind) / \(countdownText)"
            )
        }
    }

    // MARK: - Fixtures

    /// `.noSelection` comes from an empty quota-window selection, `.unavailable`
    /// from a selection nothing can fill — the two ways the planner gives up.
    private func emptyPreferences(_ state: WidgetPresentationEmptyState) -> WidgetPreferences {
        var preferences = WidgetPreferences.defaults
        if state == .noSelection {
            preferences.visibleQuotaWindows = []
        }
        return preferences
    }

    private func emptyPresentation(_ state: WidgetPresentationEmptyState) -> WidgetPresentation {
        WidgetPresentationPlanner.makePresentation(
            metrics: [:],
            accountMetrics: [],
            preferences: emptyPreferences(state),
            family: .medium,
            now: now
        )
    }

    private func emptyBurnDownPresentation(
        _ state: WidgetPresentationEmptyState
    ) -> WidgetBurnDownPresentation {
        WidgetBurnDownPlanner.makePresentation(
            metrics: [:],
            accountMetrics: [],
            preferences: emptyPreferences(state),
            family: .medium,
            now: now
        )
    }

    private func burnDownRow(
        kind: WidgetBurnDownCountdownKind,
        countdownText: String
    ) -> WidgetBurnDownRow {
        WidgetBurnDownRow(
            row: firstRow(family: .medium),
            stage: .onPace,
            stageText: "On pace",
            countdownKind: kind,
            countdownTitle: LocalizedUsageFormat.burnDownCountdownTitle(kind),
            countdownTarget: nil,
            countdownText: countdownText
        )
    }

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

    private func plannedQuotaRow(
        service: ServiceType,
        window: WidgetQuotaWindow,
        total: Double,
        modelLabel: String?
    ) -> WidgetPresentationRow {
        var preferences = WidgetPreferences.defaults
        preferences.visibleQuotaWindows = [window]
        let limit = UsageLimit(used: 40, total: total, resetTime: nil)
        let metrics = UsageMetrics(
            service: service,
            sessionLimit: window == .session ? limit : nil,
            weeklyLimit: window == .weekly ? limit : nil,
            codeReviewLimit: window == .codeReview ? limit : nil,
            modelLimitLabel: modelLabel,
            lastUpdated: now
        )
        let presentation = WidgetPresentationPlanner.makePresentation(
            metrics: [service: metrics],
            accountMetrics: [],
            preferences: preferences,
            family: .medium,
            now: now
        )
        guard let row = presentation.rows.first else {
            preconditionFailure("fixture must plan a \(service) \(window) row")
        }
        return row
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
