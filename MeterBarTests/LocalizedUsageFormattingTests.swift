import Foundation
import MeterBarShared
import XCTest

final class LocalizedUsageFormattingTests: XCTestCase {
    private func limit(used: Double, isEstimated: Bool = false) -> UsageLimit {
        UsageLimit(
            used: used,
            total: 100,
            resetTime: nil,
            isEstimated: isEstimated
        )
    }

    func testQuotaPercentFormattingKeepsUsedAndRemainingSemantics() {
        XCTAssertEqual(
            LocalizedUsageFormat.percentLeft(limit(used: 40), locale: Locale(identifier: "en")),
            "60% left"
        )
        XCTAssertEqual(
            LocalizedUsageFormat.percentUsed(limit(used: 40), locale: Locale(identifier: "en")),
            "40% used"
        )
    }

    func testEstimatedPercentFormattingKeepsApproximationMark() {
        XCTAssertEqual(
            LocalizedUsageFormat.percentLeft(
                limit(used: 100, isEstimated: true),
                locale: Locale(identifier: "en")
            ),
            "~0% left"
        )
        XCTAssertEqual(
            LocalizedUsageFormat.percentUsed(
                limit(used: 40, isEstimated: true),
                locale: Locale(identifier: "en")
            ),
            "~40% used"
        )
    }

    func testCountdownUsesLocaleAwareUnitFormatting() {
        let english = LocalizedUsageFormat.countdown(
            seconds: 3_660,
            locale: Locale(identifier: "en")
        )
        let japanese = LocalizedUsageFormat.countdown(
            seconds: 3_660,
            locale: Locale(identifier: "ja")
        )

        XCTAssertEqual(english, "1h 1m")
        XCTAssertNotEqual(japanese, english)
        XCTAssertFalse(japanese.isEmpty)
    }

    func testCountdownKeepsCompactSubMinuteFallback() {
        XCTAssertEqual(
            LocalizedUsageFormat.countdown(seconds: 59, locale: Locale(identifier: "en")),
            "<1m"
        )
    }

    /// English source copy has to stay word-for-word what `QuotaTitleKey`
    /// already says, or the Settings preview would change wording the moment
    /// it started routing through the localized helper. Parsed model labels
    /// stay verbatim.
    func testQuotaTitleMatchesSharedEnglishSourceAndPreservesModelLabels() {
        let english = Locale(identifier: "en")
        let keys: [ServiceType.QuotaTitleKey] = [
            .keyLimit,
            .session,
            .cursorModels,
            .accountCredits,
            .otherModels,
            .monthly,
            .weekly,
            .codeReview,
            .onDemand,
            .model(label: nil),
            .model(label: "Fable"),
        ]
        for key in keys {
            XCTAssertEqual(
                LocalizedUsageFormat.quotaTitle(for: key, locale: english),
                key.englishTitle,
                String(describing: key)
            )
        }
    }

    /// The English source copy has to stay word-for-word what the locale-neutral
    /// shared model says, or the Settings preview would change wording the
    /// moment it started routing through the localized helper.
    func testWidgetEmptyStateCopyMatchesTheSharedEnglishSource() {
        for state in [WidgetPresentationEmptyState.noSelection, .unavailable] {
            XCTAssertEqual(
                LocalizedUsageFormat.widgetEmptyTitle(state, locale: Locale(identifier: "en")),
                state.title,
                "\(state) title"
            )
            XCTAssertEqual(
                LocalizedUsageFormat.widgetEmptyDetail(state, locale: Locale(identifier: "en")),
                state.detail,
                "\(state) detail"
            )
        }
    }

    /// `countdownText` arrives from the locale-neutral planner, so an
    /// unavailable countdown reads as the English sentinel. Recognizing it is
    /// the formatter's job — every renderer that spelled the check out itself is
    /// a place the fallback could go missing.
    func testBurnDownCountdownTextTranslatesTheUnavailableSentinel() {
        let english = Locale(identifier: "en")
        XCTAssertEqual(
            LocalizedUsageFormat.burnDownCountdownText(
                kind: .unavailable,
                fallback: "2h 5m",
                locale: english
            ),
            LocalizedUsageFormat.unavailable(locale: english)
        )
        XCTAssertEqual(
            LocalizedUsageFormat.burnDownCountdownText(
                kind: .reset,
                fallback: "Unavailable",
                locale: english
            ),
            LocalizedUsageFormat.unavailable(locale: english)
        )
        XCTAssertEqual(
            LocalizedUsageFormat.burnDownCountdownText(
                kind: .reset,
                fallback: "2h 5m",
                locale: english
            ),
            "2h 5m"
        )
    }
}
