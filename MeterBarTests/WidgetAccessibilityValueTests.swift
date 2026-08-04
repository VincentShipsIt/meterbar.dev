import MeterBarShared
import XCTest

/// `WidgetGlanceRow`, `WidgetGlanceHero`, and `WidgetGlanceRail` each combine
/// their children into one accessibility element and then set an explicit
/// value. That explicit value *replaces* whatever `.combine` gathered, so
/// `WidgetHealthIndicator`'s "Stale usage data" and "Usage unavailable" glyph
/// labels never reached VoiceOver: a widget showing the stale clock badge read
/// aloud as a perfectly healthy row. The rail is worse — it drops the glyph
/// entirely for width, so its spoken value is the *only* place that signal can
/// live.
///
/// Composing the value on the row keeps all three call sites saying the same
/// sentence, and keeps the phrasing assertable without hosting a widget view
/// (the extension's views cannot be hosted in this target — see the note in
/// `WidgetRenderingTests`).
final class WidgetAccessibilityValueTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - Health phrase

    /// A healthy row's status is already carried by the bar's tint, so it adds
    /// nothing to speak — the value must not gain a trailing comma for it.
    func testHealthyStateContributesNoSpokenPhrase() {
        XCTAssertNil(WidgetDataHealth.healthy.accessibilityDescription)
    }

    /// These strings are what `WidgetHealthIndicator` labels its glyphs with.
    /// If the two ever disagree, sighted and VoiceOver users are told different
    /// things about the same row.
    func testFlaggedStatesMatchTheIndicatorGlyphLabels() {
        XCTAssertEqual(WidgetDataHealth.stale.accessibilityDescription, "Stale usage data")
        XCTAssertEqual(WidgetDataHealth.unavailable.accessibilityDescription, "Usage unavailable")
    }

    // MARK: - Glance row and hero value

    func testHealthyRowSpeaksQuotaAndSummaryOnly() {
        let row = plannedRow(lastUpdated: now)

        XCTAssertEqual(row.health, .healthy)
        XCTAssertEqual(row.accessibilityValueText, "\(row.quotaTitle), \(row.summaryText)")
    }

    func testStaleRowAppendsTheHealthPhrase() {
        let row = plannedRow(lastUpdated: now.addingTimeInterval(-24 * 60 * 60))

        XCTAssertEqual(row.health, .stale)
        XCTAssertEqual(
            row.accessibilityValueText,
            "\(row.quotaTitle), \(row.summaryText), Stale usage data"
        )
    }

    func testUnavailableRowAppendsTheHealthPhrase() {
        let row = unavailableRow()

        XCTAssertEqual(row.health, .unavailable)
        XCTAssertEqual(
            row.accessibilityValueText,
            "\(row.quotaTitle), \(row.summaryText), Usage unavailable"
        )
    }

    // MARK: - Rail value

    /// The rail trades the health glyph away for width, so a stale entry there
    /// has no visual signal either — the spoken value has to carry it alone.
    func testRailValueCarriesTheHealthPhrase() {
        let row = plannedRow(lastUpdated: now.addingTimeInterval(-24 * 60 * 60))

        XCTAssertEqual(
            row.compactAccessibilityValueText,
            "\(row.compactSummaryText), Stale usage data"
        )
    }

    /// The rail omits the quota title to stay on one line, so its value must
    /// stay the bare summary when there is nothing to flag.
    func testHealthyRailValueStaysTheBareSummary() {
        let row = plannedRow(lastUpdated: now)

        XCTAssertEqual(row.compactAccessibilityValueText, row.compactSummaryText)
    }

    // MARK: - Fixtures

    private func plannedRow(
        lastUpdated: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WidgetPresentationRow {
        let presentation = WidgetPresentationPlanner.makePresentation(
            metrics: [
                .claudeCode: UsageMetrics(
                    service: .claudeCode,
                    weeklyLimit: UsageLimit(used: 72, total: 100, resetTime: nil),
                    lastUpdated: lastUpdated
                )
            ],
            accountMetrics: [],
            preferences: .defaults,
            family: .medium,
            now: now
        )

        guard let row = presentation.rows.first else {
            XCTFail("fixture must plan at least one row", file: file, line: line)
            preconditionFailure("fixture must plan at least one row")
        }
        return row
    }

    /// An explicit selection can outlive its metrics snapshot; the planner keeps
    /// the row and marks it unavailable rather than dropping the selection.
    private func unavailableRow(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WidgetPresentationRow {
        var preferences = WidgetPreferences.defaults
        preferences.accountSelection = .explicit([.provider(.claudeCode)])

        let presentation = WidgetPresentationPlanner.makePresentation(
            metrics: [:],
            accountMetrics: [],
            preferences: preferences,
            family: .medium,
            now: now
        )

        guard let row = presentation.rows.first else {
            XCTFail("fixture must plan an unavailable row", file: file, line: line)
            preconditionFailure("fixture must plan an unavailable row")
        }
        return row
    }
}
