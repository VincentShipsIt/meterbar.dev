import MeterBarShared
import XCTest

/// The widget was drawn as a shrunken popover card: the account name as the
/// headline, the quota window stacked underneath it, a hairline progress bar and
/// a footer of chips — all at ad-hoc 7–9pt sizes. A popover card is read at
/// 30cm with the pointer already on it; a widget is read at arm's length in
/// under a second. `WidgetGlance` is the widget's own vocabulary, and these
/// tests pin the properties that make it *not* a card.
final class WidgetGlanceMetricsTests: XCTestCase {
    /// The card leads with the account name and treats the percentage as a
    /// trailing caption. The widget inverts that: the number is the headline and
    /// everything else supports it.
    func testTheNumberIsTheLargestTypeInEveryFamily() {
        for family in WidgetPresentationFamily.allCases {
            let metrics = WidgetGlance.metrics(for: family)
            XCTAssertGreaterThan(
                metrics.headlineSize,
                metrics.titleSize,
                "\(family): the usage number must outrank the account name"
            )
            XCTAssertGreaterThan(
                metrics.titleSize,
                metrics.captionSize,
                "\(family): the account name must outrank the supporting caption"
            )
        }
    }

    /// The headline has to win by enough to be read at a glance, not by a point.
    func testTheNumberOutweighsItsSupportingText() {
        for family in WidgetPresentationFamily.allCases {
            let metrics = WidgetGlance.metrics(for: family)
            XCTAssertGreaterThanOrEqual(
                metrics.headlineSize,
                metrics.captionSize * 1.5,
                "\(family): the headline must be at least half again its caption"
            )
        }
    }

    /// The 7pt and 8pt labels the widget shipped with are below the size anything
    /// on a home screen can be read at. Nothing in the widget goes under 10pt.
    func testEveryLabelClearsTheLegibilityFloor() {
        for family in WidgetPresentationFamily.allCases {
            let metrics = WidgetGlance.metrics(for: family)
            for (name, size) in [
                ("headline", metrics.headlineSize),
                ("title", metrics.titleSize),
                ("caption", metrics.captionSize),
            ] {
                XCTAssertGreaterThanOrEqual(
                    size,
                    WidgetGlance.legibilityFloor,
                    "\(family) \(name) is below the widget legibility floor"
                )
            }
        }
    }

    /// A default `ProgressView` draws a ~4pt hairline — fine inside a card the
    /// pointer is resting on, invisible on a home screen. The widget bar is a
    /// capsule with real weight, and its tint is what carries status, so the card's
    /// separate status dot is not needed.
    func testTheBarIsACapsuleWithWeightNotAHairline() {
        for family in WidgetPresentationFamily.allCases {
            let metrics = WidgetGlance.metrics(for: family)
            XCTAssertGreaterThanOrEqual(
                metrics.barHeight,
                WidgetGlance.minimumBarHeight,
                "\(family): the usage bar must be thicker than a default hairline"
            )
        }
    }

    /// The small family is one number, so it gets the biggest one.
    func testTheSmallFamilyCarriesTheBiggestNumber() {
        let small = WidgetGlance.metrics(for: .small)
        XCTAssertGreaterThan(small.headlineSize, WidgetGlance.metrics(for: .medium).headlineSize)
        XCTAssertGreaterThan(small.headlineSize, WidgetGlance.metrics(for: .large).headlineSize)
        XCTAssertGreaterThan(small.barHeight, WidgetGlance.metrics(for: .medium).barHeight)
    }

    /// Spacing and padding come off the same 2pt grid the rest of the widget uses
    /// so rows in different families still stack to the same rhythm.
    func testSpacingStepsSitOnTheGrid() {
        for family in WidgetPresentationFamily.allCases {
            let metrics = WidgetGlance.metrics(for: family)
            for (name, step) in [
                ("rowSpacing", metrics.rowSpacing),
                ("stackSpacing", metrics.stackSpacing),
                ("contentPadding", metrics.contentPadding),
            ] {
                XCTAssertEqual(
                    step.truncatingRemainder(dividingBy: 2),
                    0,
                    "\(family) \(name) = \(step) is off the 2pt grid"
                )
            }
            XCTAssertGreaterThan(
                metrics.stackSpacing,
                metrics.rowSpacing,
                "\(family): rows must sit further apart than the lines inside one row"
            )
        }
    }
}

/// The small widget shipped three stacked mini-cards inside 150×150. That is the
/// popover's list shrunk past the point of being readable — the widget's answer
/// is one hero number with the rest reduced to a rail.
final class WidgetGlanceLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testSmallLeadsWithOneHeroAndDemotesTheRest() {
        let plan = presentation(
            metrics: [
                .claudeCode: makeMetrics(.claudeCode, weeklyUsed: 10),
                .codexCli: makeMetrics(.codexCli, weeklyUsed: 20)
            ],
            family: .small
        )
        XCTAssertEqual(plan.rows.count, 2, "fixture should plan two rows for the small family")

        guard case let .hero(headline, supporting) = WidgetGlance.layout(for: plan, family: .small) else {
            return XCTFail("small must lead with a hero, not a stack of cards")
        }

        XCTAssertEqual(headline.id, plan.rows[0].id, "the hero is the row the planner ranked first")
        XCTAssertEqual(supporting.map(\.id), Array(plan.rows.dropFirst().map(\.id)))
    }

    func testMediumAndLargeStackRows() {
        for family in [WidgetPresentationFamily.medium, .large] {
            let plan = presentation(
                metrics: [
                    .claudeCode: makeMetrics(.claudeCode, weeklyUsed: 10),
                    .codexCli: makeMetrics(.codexCli, weeklyUsed: 20)
                ],
                family: family
            )

            guard case let .rows(stacked) = WidgetGlance.layout(for: plan, family: family) else {
                return XCTFail("\(family) has the room for a stack of rows")
            }
            XCTAssertEqual(stacked.map(\.id), plan.rows.map(\.id))
        }
    }

    /// One selected account is the common case: a hero with nothing under it, not
    /// a hero plus an empty rail.
    func testASingleRowIsAHeroWithNoRail() {
        let plan = presentation(
            metrics: [.claudeCode: makeMetrics(.claudeCode, weeklyUsed: 10)],
            family: .small
        )
        XCTAssertEqual(plan.rows.count, 1)

        guard case let .hero(headline, supporting) = WidgetGlance.layout(for: plan, family: .small) else {
            return XCTFail("a single row is still a hero")
        }

        XCTAssertEqual(headline.id, plan.rows[0].id)
        XCTAssertTrue(supporting.isEmpty)
    }

    /// Nothing to show falls back to the row stack so the empty state renders
    /// through one path in every family.
    func testNoRowsFallsBackToAnEmptyStack() {
        for family in WidgetPresentationFamily.allCases {
            let plan = presentation(metrics: [:], family: family)
            XCTAssertTrue(plan.rows.isEmpty)

            guard case let .rows(stacked) = WidgetGlance.layout(for: plan, family: family) else {
                return XCTFail("\(family) with no rows must not claim a hero")
            }
            XCTAssertTrue(stacked.isEmpty)
        }
    }

    // MARK: - Fixtures

    private func presentation(
        metrics: [ServiceType: UsageMetrics],
        family: WidgetPresentationFamily
    ) -> WidgetPresentation {
        WidgetPresentationPlanner.makePresentation(
            metrics: metrics,
            accountMetrics: [],
            preferences: .defaults,
            family: family,
            now: now
        )
    }

    private func makeMetrics(_ service: ServiceType, weeklyUsed: Double) -> UsageMetrics {
        UsageMetrics(
            service: service,
            weeklyLimit: UsageLimit(used: weeklyUsed, total: 100, resetTime: nil),
            lastUpdated: now
        )
    }
}
