import Foundation
import MeterBarShared
import XCTest

final class ProviderRecommendationTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - Ordering

    func testRanksCandidatesByBindingWindowHeadroom() {
        let recommendation = rank([
            makeCandidate(id: "tight", service: .grok, session: limit(used: 90)),
            makeCandidate(id: "roomy", service: .cursor, session: limit(used: 20)),
            makeCandidate(id: "middling", service: .codexCli, session: limit(used: 60))
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["roomy", "middling", "tight"])
        XCTAssertEqual(recommendation.rows.map(\.percentLeft), [80, 40, 10])
        XCTAssertEqual(recommendation.top?.id, "roomy")
        XCTAssertTrue(recommendation.unavailable.isEmpty)
    }

    func testBindingWindowIsTheTightestProviderBlockingWindow() {
        let recommendation = rank([
            makeCandidate(
                id: "weekly-bound",
                service: .claudeCode,
                session: limit(used: 10),
                weekly: limit(used: 70)
            ),
            makeCandidate(id: "session-only", service: .codexCli, session: limit(used: 50))
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["session-only", "weekly-bound"])
        XCTAssertEqual(recommendation.rows.map(\.window), [.session, .weekly])
        XCTAssertEqual(recommendation.rows.map(\.percentLeft), [50, 30])
        XCTAssertEqual(recommendation.rows.map(\.windowTitle), ["Session", "Weekly"])
    }

    func testWindowTitleFollowsTheProviderVocabulary() {
        let recommendation = rank([
            makeCandidate(id: "credits", service: .openRouter, weekly: limit(used: 10)),
            makeCandidate(id: "monthly", service: .cursor, weekly: limit(used: 20)),
            makeCandidate(id: "key", service: .openRouter, displayOrder: 1, session: limit(used: 30))
        ])

        XCTAssertEqual(
            recommendation.rows.map(\.windowTitle),
            ["Account credits", "Other Models", "Key limit"]
        )
    }

    func testGrokMonthlyWeeklySlotRecommendationIsTitledMonthly() {
        let recommendation = rank([
            makeCandidate(
                id: "grok-monthly",
                service: .grok,
                weekly: UsageLimit(used: 40, total: 100, resetTime: nil, periodKind: .monthly)
            )
        ])

        XCTAssertEqual(recommendation.rows.map(\.windowTitle), ["Monthly"])
    }

    func testEqualScoresFallBackToStableProviderOrder() {
        let recommendation = rank([
            makeCandidate(id: "grok", service: .grok, session: limit(used: 40)),
            makeCandidate(id: "claude-b", service: .claudeCode, displayOrder: 1, session: limit(used: 40)),
            makeCandidate(id: "claude-a", service: .claudeCode, displayOrder: 0, session: limit(used: 40))
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["claude-a", "claude-b", "grok"])
        XCTAssertEqual(Set(recommendation.rows.map(\.score)), [60])
    }

    // MARK: - Pace weighting

    func testReserveOutranksDeficitAtEqualHeadroom() {
        // Both candidates have half their quota left; only the elapsed share of
        // the window differs, so pace is the sole tiebreaker.
        let recommendation = rank([
            makeCandidate(
                id: "deficit",
                service: .claudeCode,
                session: limit(used: 50, resetIn: 8 * 3_600, windowSeconds: 10 * 3_600)
            ),
            makeCandidate(
                id: "reserve",
                service: .codexCli,
                session: limit(used: 50, resetIn: 2 * 3_600, windowSeconds: 10 * 3_600)
            )
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["reserve", "deficit"])
        XCTAssertEqual(recommendation.rows.map(\.score), [62, 38])
        XCTAssertEqual(recommendation.rows.map(\.paceText), ["30% in reserve", "30% in deficit"])
    }

    func testPaceAdjustmentIsCappedSoHeadroomStaysDominant() {
        // "reserve" runs a 30-point reserve — worth 12 points, not 12 × 0.4 × 30 —
        // so the candidate with genuinely more quota left still wins.
        let recommendation = rank([
            makeCandidate(
                id: "reserve",
                service: .claudeCode,
                session: limit(used: 60, resetIn: 3_600, windowSeconds: 10 * 3_600)
            ),
            makeCandidate(
                id: "roomier",
                service: .codexCli,
                session: limit(used: 45, resetIn: 5_400 + 14_400, windowSeconds: 10 * 3_600)
            )
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["roomier", "reserve"])
        XCTAssertEqual(recommendation.rows.map(\.score), [55, 52])
    }

    func testImminentResetLiftsANearlyRefilledWindow() {
        let recommendation = rank([
            makeCandidate(id: "refills-soon", service: .claudeCode, session: limit(used: 70, resetIn: 600)),
            makeCandidate(id: "no-reset", service: .codexCli, session: limit(used: 68))
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["refills-soon", "no-reset"])
        XCTAssertEqual(recommendation.rows.map(\.score), [34, 32])
        XCTAssertEqual(recommendation.rows.first?.resetText, "Resets in 10m")
    }

    // MARK: - Exhaustion

    func testExhaustedCandidatesRankLastOrderedBySoonestReset() {
        let recommendation = rank([
            makeCandidate(id: "late", service: .claudeCode, session: limit(used: 100, resetIn: 3 * 3_600)),
            makeCandidate(id: "unknown-reset", service: .codexCli, session: limit(used: 120)),
            makeCandidate(id: "healthy", service: .cursor, session: limit(used: 50)),
            makeCandidate(id: "soon", service: .grok, session: limit(used: 100, resetIn: 1_800))
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["healthy", "soon", "late", "unknown-reset"])
        XCTAssertEqual(recommendation.rows.map(\.isExhausted), [false, true, true, true])
        XCTAssertEqual(recommendation.rows.dropFirst().map(\.score), [0, 0, 0])
        XCTAssertEqual(
            recommendation.rows.map(\.availabilityText),
            [nil, "Available in 30m", "Available in 3h", nil]
        )
    }

    func testAnExhaustedWindowNeverBorrowsTheImminentResetBonus() {
        let recommendation = rank([
            makeCandidate(id: "exhausted", service: .claudeCode, session: limit(used: 100, resetIn: 300)),
            makeCandidate(id: "barely-left", service: .codexCli, session: limit(used: 99.5))
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["barely-left", "exhausted"])
        XCTAssertEqual(recommendation.rows.map(\.score), [1, 0])
    }

    func testEveryWindowExhaustedStillNamesTheSoonestReturn() {
        let recommendation = rank([
            makeCandidate(id: "later", service: .claudeCode, session: limit(used: 100, resetIn: 4 * 3_600)),
            makeCandidate(id: "sooner", service: .codexCli, session: limit(used: 100, resetIn: 90 * 60))
        ])

        XCTAssertTrue(recommendation.isFullyExhausted)
        XCTAssertEqual(recommendation.top?.id, "sooner")
        XCTAssertEqual(recommendation.top?.availabilityText, "Available in 1h 30m")
    }

    // MARK: - Staleness and missing data

    func testStaleCandidatesAreExcludedWithTheirAgeInsteadOfRanked() {
        let recommendation = rank([
            makeCandidate(id: "fresh", service: .claudeCode, session: limit(used: 40)),
            makeCandidate(
                id: "stale",
                service: .codexCli,
                session: limit(used: 5),
                updatedSecondsAgo: 3 * 3_600
            )
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["fresh"])
        XCTAssertEqual(recommendation.unavailable.map(\.id), ["stale"])
        XCTAssertEqual(recommendation.unavailable.first?.reason, .stale(age: 3 * 3_600))
        XCTAssertEqual(recommendation.unavailable.first?.detail, "Last updated 3h ago")
    }

    func testStalenessThresholdIsInjectable() {
        let candidates = [
            makeCandidate(id: "fresh", service: .claudeCode, session: limit(used: 40)),
            makeCandidate(
                id: "older",
                service: .codexCli,
                session: limit(used: 5),
                updatedSecondsAgo: 30 * 60
            )
        ]

        XCTAssertEqual(rank(candidates).rows.map(\.id), ["older", "fresh"])
        XCTAssertEqual(
            rank(candidates, stalenessThreshold: 10 * 60).rows.map(\.id),
            ["fresh"]
        )
    }

    func testMissingSnapshotsAndMissingBindingWindowsListAsNoData() {
        let recommendation = rank([
            makeCandidate(id: "ranked", service: .cursor, session: limit(used: 40)),
            makeCandidate(id: "never-fetched", service: .claudeCode, updatedSecondsAgo: nil),
            makeCandidate(id: "no-window", service: .codexCli)
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["ranked"])
        XCTAssertEqual(recommendation.unavailable.map(\.id), ["never-fetched", "no-window"])
        XCTAssertEqual(
            recommendation.unavailable.map(\.reason),
            [.noSnapshot, .noBindingWindow]
        )
        XCTAssertEqual(
            recommendation.unavailable.map(\.detail),
            ["No usage cached yet", "No session or weekly window reported"]
        )
    }

    func testCallerSuppliedBlockersOutrankOtherwiseHealthyNumbers() {
        let signedOut = ProviderRecommendationCandidate(
            id: "signed-out",
            name: "Claude",
            service: .claudeCode,
            displayOrder: 0,
            sessionLimit: limit(used: 5),
            weeklyLimit: nil,
            lastUpdated: now,
            unavailableReason: .blocked("Login required")
        )
        let recommendation = rank([
            signedOut,
            makeCandidate(id: "usable", service: .codexCli, session: limit(used: 80))
        ])

        XCTAssertEqual(recommendation.rows.map(\.id), ["usable"])
        XCTAssertEqual(recommendation.unavailable.map(\.detail), ["Login required"])
    }

    func testHeadroomIsNeverGuessedFromAnEmptyQuotaTotal() {
        let recommendation = rank([
            makeCandidate(
                id: "zero-total",
                service: .claudeCode,
                session: UsageLimit(used: 0, total: 0, resetTime: nil)
            )
        ])

        XCTAssertTrue(recommendation.rows.isEmpty)
        XCTAssertEqual(recommendation.unavailable.map(\.reason), [.noBindingWindow])
    }

    // MARK: - Degenerate inputs

    func testSingleCandidateIsItsOwnTopRecommendation() {
        let recommendation = rank([
            makeCandidate(id: "solo", service: .cursor, weekly: limit(used: 18, resetIn: 3 * 86_400))
        ])

        XCTAssertEqual(recommendation.rows.count, 1)
        XCTAssertEqual(recommendation.top?.id, "solo")
        XCTAssertFalse(recommendation.isEmpty)
        XCTAssertFalse(recommendation.isFullyExhausted)
        XCTAssertEqual(recommendation.top?.summary, "Cursor — 82% left on Other Models, resets in 3d")
    }

    func testHeadlineNamesTheTopPickAndItsNumbers() {
        let recommendation = rank([
            makeCandidate(id: "solo", service: .cursor, weekly: limit(used: 18, resetIn: 3 * 86_400))
        ])

        XCTAssertEqual(recommendation.headline, "Use Cursor next — 82% left on other models, resets in 3d")
    }

    func testHeadlineSaysSoWhenEveryWindowIsSpent() {
        let recommendation = rank([
            makeCandidate(id: "late", service: .codexCli, session: limit(used: 100, resetIn: 3 * 3_600)),
            makeCandidate(id: "soon", service: .claudeCode, session: limit(used: 100, resetIn: 45 * 60))
        ])

        XCTAssertEqual(
            recommendation.headline,
            "Every window is spent — Claude is back first, available in 45m"
        )
    }

    func testHeadlineIsAbsentWithNothingToRank() {
        XCTAssertNil(rank([]).headline)
    }

    func testEmptyCandidateListProducesAnEmptyRecommendation() {
        let recommendation = rank([])

        XCTAssertTrue(recommendation.rows.isEmpty)
        XCTAssertTrue(recommendation.unavailable.isEmpty)
        XCTAssertTrue(recommendation.isEmpty)
        XCTAssertFalse(recommendation.isFullyExhausted)
        XCTAssertNil(recommendation.top)
    }

    func testOnlyUnavailableCandidatesStillCountAsEmptyRanking() {
        let recommendation = rank([
            makeCandidate(id: "never-fetched", service: .claudeCode, updatedSecondsAgo: nil)
        ])

        XCTAssertTrue(recommendation.isEmpty)
        XCTAssertFalse(recommendation.isFullyExhausted)
        XCTAssertEqual(recommendation.unavailable.count, 1)
    }

    // MARK: - Explainability

    func testEstimatedTotalsRankButStayMarkedAsEstimates() {
        let recommendation = rank([
            makeCandidate(
                id: "estimated",
                service: .claudeCode,
                session: limit(used: 60, isEstimated: true)
            )
        ])

        XCTAssertEqual(recommendation.top?.headroomText, "~40% left")
        XCTAssertEqual(recommendation.top?.limit.isEstimated, true)
    }

    func testRowsCarryTheInputsThatProducedTheirScore() {
        let recommendation = rank([
            makeCandidate(
                id: "explained",
                service: .claudeCode,
                session: limit(used: 50, resetIn: 2 * 3_600, windowSeconds: 10 * 3_600)
            )
        ])

        let row = recommendation.rows.first
        XCTAssertEqual(row?.percentLeft, 50)
        XCTAssertEqual(row?.band, .healthy)
        XCTAssertEqual(row?.window, .session)
        XCTAssertEqual(row?.secondsUntilReset, 2 * 3_600)
        XCTAssertEqual(row?.resetText, "Resets in 2h")
        XCTAssertEqual(row?.paceText, "30% in reserve")
        XCTAssertEqual(row?.pace?.stage, .reserve)
    }

    func testCandidateFromMetricsIgnoresTheModelScopedWindow() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: limit(used: 30),
            weeklyLimit: limit(used: 40),
            codeReviewLimit: limit(used: 99),
            lastUpdated: now
        )
        let candidate = ProviderRecommendationCandidate(
            id: "claude",
            name: "Claude Code",
            service: .claudeCode,
            displayOrder: 0,
            metrics: metrics
        )

        XCTAssertEqual(candidate.sessionLimit, metrics.sessionLimit)
        XCTAssertEqual(candidate.weeklyLimit, metrics.weeklyLimit)
        XCTAssertEqual(candidate.lastUpdated, now)
        XCTAssertEqual(rank([candidate]).top?.percentLeft, 60)
    }

    func testCandidateFromAMissingSnapshotHasNoTimestamp() {
        let candidate = ProviderRecommendationCandidate(
            id: "grok",
            name: "Grok",
            service: .grok,
            displayOrder: 0,
            metrics: nil
        )

        XCTAssertNil(candidate.lastUpdated)
        XCTAssertEqual(rank([candidate]).unavailable.map(\.reason), [.noSnapshot])
    }

    // MARK: - Helpers

    private func rank(
        _ candidates: [ProviderRecommendationCandidate],
        stalenessThreshold: TimeInterval = ProviderRecommendationPlanner.defaultStalenessThreshold
    ) -> ProviderRecommendation {
        ProviderRecommendationPlanner.rank(
            candidates: candidates,
            now: now,
            stalenessThreshold: stalenessThreshold
        )
    }

    private func limit(
        used: Double,
        resetIn: TimeInterval? = nil,
        windowSeconds: TimeInterval? = nil,
        isEstimated: Bool = false
    ) -> UsageLimit {
        UsageLimit(
            used: used,
            total: 100,
            resetTime: resetIn.map { now.addingTimeInterval($0) },
            windowSeconds: windowSeconds,
            isEstimated: isEstimated
        )
    }

    private func makeCandidate(
        id: String,
        service: ServiceType,
        displayOrder: Int = 0,
        session: UsageLimit? = nil,
        weekly: UsageLimit? = nil,
        updatedSecondsAgo: TimeInterval? = 0
    ) -> ProviderRecommendationCandidate {
        ProviderRecommendationCandidate(
            id: id,
            name: service.shortName,
            service: service,
            displayOrder: displayOrder,
            sessionLimit: session,
            weeklyLimit: weekly,
            lastUpdated: updatedSecondsAgo.map { now.addingTimeInterval(-$0) }
        )
    }
}
