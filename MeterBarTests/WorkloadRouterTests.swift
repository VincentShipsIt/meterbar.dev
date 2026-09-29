import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Behaviour of the pure router: hard filters, scoring, ordering, fallbacks,
/// and the outcomes a caller can branch on. Every case is a credential-free
/// fixture at a fixed instant.
final class WorkloadRouterTests: XCTestCase {
    private typealias Fixtures = RoutingFixtures

    // MARK: - Ranking

    func testHighestHeadroomIsRecommendedAndTheRestFollowAsFallbacks() {
        let decision = Fixtures.route([
            Fixtures.candidate(.codexCli, used: 80),
            Fixtures.candidate(.claudeCode, used: 30),
        ])

        XCTAssertEqual(decision.outcome, .recommended)
        XCTAssertEqual(decision.recommendation?.provider, "claude")
        XCTAssertEqual(decision.recommendation?.score, 70)
        XCTAssertEqual(decision.recommendation?.rank, 1)
        XCTAssertEqual(decision.fallbacks.map(\.provider), ["codex"])
        XCTAssertEqual(decision.fallbacks.first?.rank, 2)
        XCTAssertEqual(decision.exitCode, 0)
    }

    func testTheHeadlineReasonStatesTheQuotaThatDecidedIt() {
        let decision = Fixtures.route([Fixtures.candidate(.claudeCode, used: 26)])

        let first = decision.recommendation?.reasons.first
        XCTAssertEqual(first?.code, .quotaHeadroom)
        XCTAssertEqual(first?.message, "74% session quota remains")
    }

    func testIdenticalInputsProduceIdenticalDecisionsInEveryInputOrder() {
        let candidates = [
            Fixtures.candidate(.claudeCode, used: 40),
            Fixtures.candidate(.codexCli, used: 40),
            Fixtures.candidate(.grok, used: 10),
            Fixtures.candidate(.cursor, used: 100),
            Fixtures.candidate(.openRouter, used: 10, age: 9 * 3_600),
            Fixtures.account(.claudeCode, id: Fixtures.uuid(9), name: "Personal", used: 40, order: 1),
        ]
        let reference = Fixtures.route(candidates)
        XCTAssertEqual(reference.rejected.count, 2, "the rejection list must be order-independent too")

        for permutation in permutations(of: candidates) {
            XCTAssertEqual(Fixtures.route(permutation), reference)
        }
    }

    func testEncodingTheSameDecisionTwiceIsByteIdentical() throws {
        let candidates = [Fixtures.candidate(.claudeCode, used: 40), Fixtures.candidate(.codexCli, used: 40)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertEqual(
            try encoder.encode(Fixtures.route(candidates)),
            try encoder.encode(Fixtures.route(candidates.reversed()))
        )
    }

    // MARK: - Tie-breaker

    func testEqualScoresFallBackToProviderOrder() {
        let decision = Fixtures.route([
            Fixtures.candidate(.codexCli, used: 40),
            Fixtures.candidate(.claudeCode, used: 40),
        ])

        XCTAssertEqual(decision.chain, ["claude", "codex"])
        let note = decision.reasons.first { $0.code == .tieBreakApplied }
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.message.contains("provider order") == true, note?.message ?? "")
    }

    func testEqualScoresPreferTheProviderWithMoreQuotaLeftBeforeProviderOrder() {
        // Codex: 60 left. Claude: 56 left + the 4-point imminent-reset bonus.
        // Both score 60, so provider order (Claude first) would pick Claude;
        // the documented tie-breaker looks at quota remaining first.
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, session: Fixtures.limit(used: 44, resetIn: 10 * 60)),
            Fixtures.candidate(.codexCli, used: 40),
        ])

        XCTAssertEqual(decision.recommendation?.score, 60)
        XCTAssertEqual(decision.fallbacks.first?.score, 60)
        XCTAssertEqual(decision.chain, ["codex", "claude"])
        XCTAssertTrue(
            decision.reasons.first { $0.code == .tieBreakApplied }?.message.contains("more quota remaining") == true
        )
    }

    func testEqualScoresAcrossOneProvidersAccountsFollowAccountOrderThenIdentifier() {
        let byOrder = Fixtures.route([
            Fixtures.account(.claudeCode, id: Fixtures.uuid(1), name: "B", used: 40, order: 1),
            Fixtures.account(.claudeCode, id: Fixtures.uuid(2), name: "A", used: 40, order: 0),
        ])
        XCTAssertEqual(byOrder.recommendation?.account?.label, "A")

        let byIdentifier = Fixtures.route([
            Fixtures.account(.claudeCode, id: Fixtures.uuid(2), name: "Second", used: 40, order: 0),
            Fixtures.account(.claudeCode, id: Fixtures.uuid(1), name: "First", used: 40, order: 0),
        ])
        XCTAssertEqual(byIdentifier.recommendation?.account?.label, "First")
    }

    func testClearWinnerCarriesNoTieBreakNote() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, used: 10),
            Fixtures.candidate(.codexCli, used: 60),
        ])
        XCTAssertFalse(decision.reasons.contains { $0.code == .tieBreakApplied })
    }

    // MARK: - Freshness and missing data

    func testStaleSnapshotIsRejectedNotRanked() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, used: 5, age: 3 * 3_600),
            Fixtures.candidate(.codexCli, used: 70),
        ])

        XCTAssertEqual(decision.chain, ["codex"])
        let rejection = decision.rejected.first
        XCTAssertEqual(rejection?.code, .snapshotStale)
        XCTAssertEqual(rejection?.provider, "claude")
        XCTAssertEqual(rejection?.freshness?.isStale, true)
        XCTAssertEqual(rejection?.freshness?.ageSeconds, 3 * 3_600)
    }

    func testASnapshotExactlyAtTheStalenessBoundIsStillFresh() {
        let decision = Fixtures.route([Fixtures.candidate(.claudeCode, used: 20, age: 2 * 3_600)])
        XCTAssertEqual(decision.outcome, .recommended)
        XCTAssertEqual(decision.recommendation?.freshness.isStale, false)

        let older = Fixtures.route([Fixtures.candidate(.claudeCode, used: 20, age: 2 * 3_600 + 1)])
        XCTAssertEqual(older.rejectionCodes, [.snapshotStale])
    }

    func testTheStalenessBoundIsInjectable() {
        let decision = Fixtures.route(
            [Fixtures.candidate(.claudeCode, used: 20, age: 600)],
            stalenessThreshold: 300
        )
        XCTAssertEqual(decision.rejectionCodes, [.snapshotStale])
    }

    func testCandidateWithNoSnapshotIsRejected() {
        let missing = RoutingCandidate(service: .cursor, metrics: nil)
        let decision = Fixtures.route([missing, Fixtures.candidate(.claudeCode)])

        XCTAssertEqual(decision.rejected.first?.code, .snapshotMissing)
        XCTAssertNil(decision.rejected.first?.freshness)
        XCTAssertEqual(decision.chain, ["claude"])
    }

    func testAWindowWithNoUsableTotalIsNotReadAsFullyAvailable() {
        for bad in [
            Fixtures.limit(used: 0, total: 0),
            Fixtures.limit(used: .nan),
            Fixtures.limit(used: -5),
            Fixtures.limit(used: 5, total: .infinity),
        ] {
            let decision = Fixtures.route([Fixtures.candidate(.codexCli, session: bad)])
            XCTAssertEqual(decision.rejectionCodes, [.noQuotaWindow])
            XCTAssertEqual(decision.outcome, .dataUnavailable)
        }
    }

    func testAMetricsSnapshotWithNoSessionOrWeeklyWindowIsRejected() {
        let candidate = RoutingCandidate(
            service: .claudeCode,
            metrics: Fixtures.metrics(.claudeCode, session: nil, weekly: nil, codeReview: Fixtures.limit(used: 10))
        )
        XCTAssertEqual(Fixtures.route([candidate]).rejectionCodes, [.noQuotaWindow])
    }

    // MARK: - Exhaustion and headroom

    func testExhaustedQuotaIsRejectedWithItsResetTime() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, used: 100),
            Fixtures.candidate(.codexCli, used: 50),
        ])

        XCTAssertEqual(decision.chain, ["codex"])
        XCTAssertEqual(decision.rejected.first?.code, .quotaExhausted)
        XCTAssertTrue(decision.rejected.first?.message.contains("resets in 3h") == true)
    }

    func testAnExhaustedWeeklyWindowBlocksAProviderWhoseSessionHasRoom() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, session: Fixtures.limit(used: 10), weekly: Fixtures.limit(used: 100)),
        ])
        XCTAssertEqual(decision.rejectionCodes, [.quotaExhausted])
        XCTAssertTrue(decision.rejected.first?.message.contains("weekly") == true)
    }

    func testTheTighterWindowDecidesTheHeadroom() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, session: Fixtures.limit(used: 10), weekly: Fixtures.limit(used: 70)),
        ])
        XCTAssertEqual(decision.recommendation?.quota.percentLeft, 30)
        XCTAssertEqual(decision.recommendation?.quota.window, "weekly")
    }

    func testAnExhaustedModelScopedOrCodeReviewWindowDoesNotBlockTheProvider() {
        let candidate = RoutingCandidate(
            service: .claudeCode,
            metrics: Fixtures.metrics(
                .claudeCode,
                session: Fixtures.limit(used: 30),
                codeReview: Fixtures.limit(used: 100)
            )
        )
        XCTAssertEqual(Fixtures.route([candidate]).outcome, .recommended)
    }

    func testEstimatedQuotaAtItsLimitIsStillExhaustedWhenEstimatesAreAllowed() {
        let policy = Fixtures.policy(.research) { $0.allowsEstimatedQuota = true }
        let decision = Fixtures.route(policy, [
            Fixtures.candidate(.cursor, session: Fixtures.limit(used: 500, total: 500, estimated: true)),
        ])
        XCTAssertEqual(decision.rejectionCodes, [.quotaExhausted])
    }

    func testProviderSpecificPoolNamesKeepTheirCapitalsInMessages() {
        let spent = Fixtures.route([Fixtures.candidate(.cursor, session: Fixtures.limit(used: 100), weekly: Fixtures.limit(used: 100))])
        XCTAssertTrue(spent.rejected.first?.message.contains("Cursor Models quota is spent") == true, spent.rejected.first?.message ?? "")

        let open = Fixtures.route([Fixtures.candidate(.cursor, session: Fixtures.limit(used: 40), weekly: Fixtures.limit(used: 40))])
        XCTAssertEqual(open.recommendation?.reasons.first?.message, "60% Cursor Models quota remains")
    }

    func testMinimumHeadroomIsInclusiveAtTheBoundary() {
        let policy = Fixtures.policy { $0.minimumRemainingPercent = 30 }

        XCTAssertEqual(Fixtures.route(policy, [Fixtures.candidate(.claudeCode, used: 70)]).outcome, .recommended)

        let below = Fixtures.route(policy, [Fixtures.candidate(.claudeCode, used: 71)])
        XCTAssertEqual(below.rejectionCodes, [.belowMinimumHeadroom])
        XCTAssertTrue(below.rejected.first?.message.contains("29%") == true)
        XCTAssertTrue(below.rejected.first?.message.contains("30%") == true)
    }

    func testCursorIncludedPoolsSpillOverSoOneSpentPoolDoesNotBlockTheProvider() {
        let auto = Fixtures.limit(used: 100)
        let api = Fixtures.limit(used: 40)
        let decision = Fixtures.route([Fixtures.candidate(.cursor, session: auto, weekly: api)])

        XCTAssertEqual(decision.outcome, .recommended)
        XCTAssertEqual(decision.recommendation?.quota.percentLeft, 60)

        let bothSpent = Fixtures.route([Fixtures.candidate(.cursor, session: auto, weekly: Fixtures.limit(used: 100))])
        XCTAssertEqual(bothSpent.rejectionCodes, [.quotaExhausted])
    }

    // MARK: - Estimates, pace, health

    func testEstimatedQuotaIsRejectedUnlessThePolicyAllowsIt() {
        let estimated = Fixtures.candidate(
            .cursor,
            session: Fixtures.limit(used: 100, total: 500, estimated: true)
        )

        let strict = Fixtures.route(Fixtures.policy(.implementation), [estimated])
        XCTAssertEqual(strict.rejectionCodes, [.estimateNotAllowed])

        let lenient = Fixtures.route(Fixtures.policy(.research) { $0.allowsEstimatedQuota = true }, [estimated])
        XCTAssertEqual(lenient.outcome, .recommended)
        XCTAssertTrue(lenient.recommendation?.reasons.contains { $0.code == .estimatedQuota } == true)
        XCTAssertEqual(lenient.recommendation?.reasons.first?.message, "~80% session quota remains")
        XCTAssertEqual(lenient.recommendation?.quota.estimated, true)
    }

    func testDeficitBeyondThePolicyLimitRejectsTheCandidate() {
        let policy = Fixtures.policy { $0.maximumDeficitPercent = 25 }

        // Session is 40% elapsed: 70% used is 30 points ahead of pace.
        let over = Fixtures.route(policy, [Fixtures.candidate(.claudeCode, session: Fixtures.pacedLimit(used: 70))])
        XCTAssertEqual(over.rejectionCodes, [.deficitExceedsLimit])

        let within = Fixtures.route(policy, [Fixtures.candidate(.claudeCode, session: Fixtures.pacedLimit(used: 65))])
        XCTAssertEqual(within.outcome, .recommended)
        XCTAssertTrue(within.recommendation?.reasons.contains { $0.code == .behindPace } == true)
    }

    func testUnknownPaceIsNotTreatedAsADeficit() {
        let policy = Fixtures.policy { $0.maximumDeficitPercent = 0 }
        let decision = Fixtures.route(policy, [Fixtures.candidate(.claudeCode, used: 80)])
        XCTAssertEqual(decision.outcome, .recommended)
        XCTAssertNil(decision.recommendation?.quota.pace)
    }

    func testReserveRaisesTheScoreAndDeficitLowersIt() {
        // Session is 40% elapsed. 40% used is exactly on pace: no adjustment.
        let onPace = Fixtures.route([Fixtures.candidate(.claudeCode, session: Fixtures.pacedLimit(used: 40))])
        XCTAssertEqual(onPace.recommendation?.score, 60)

        let ahead = Fixtures.route([Fixtures.candidate(.claudeCode, session: Fixtures.pacedLimit(used: 20))])
        XCTAssertEqual(ahead.recommendation?.score, 88)
        XCTAssertEqual(ahead.recommendation?.reasons.map(\.code), [.quotaHeadroom, .aheadOfPace, .includedQuota])
        XCTAssertEqual(ahead.recommendation?.quota.pace?.stage, "reserve")
        XCTAssertEqual(ahead.recommendation?.quota.pace?.deltaPercent, -20)

        // 60% used is 20 points in deficit: 40 left - 0.4 * 20.
        let behind = Fixtures.route([Fixtures.candidate(.claudeCode, session: Fixtures.pacedLimit(used: 60))])
        XCTAssertEqual(behind.recommendation?.score, 32)
    }

    func testFailingProviderHealthRejectsAndDegradedHealthScoresDown() {
        let failing = Fixtures.route([Fixtures.candidate(.claudeCode, used: 10, health: .failing)])
        XCTAssertEqual(failing.rejectionCodes, [.providerUnhealthy])
        XCTAssertEqual(failing.outcome, .dataUnavailable)

        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, used: 40, health: .degraded),
            Fixtures.candidate(.codexCli, used: 45),
        ])
        XCTAssertEqual(decision.chain, ["codex", "claude"])
        XCTAssertEqual(decision.fallbacks.first?.score, 52)
        XCTAssertTrue(decision.fallbacks.first?.reasons.contains { $0.code == .healthDegraded } == true)
    }

    // MARK: - Cost against headroom

    func testCostPreferenceTradesMeteredHeadroomForIncludedQuota() {
        let candidates = [
            Fixtures.candidate(.openRouter, used: 10), // 90 left, metered
            Fixtures.candidate(.claudeCode, used: 50), // 50 left, included
        ]
        func leader(_ cost: RoutingCostPreference, _ tier: RoutingModelTier) -> String? {
            let policy = Fixtures.policy { $0.costPreference = cost; $0.modelTier = tier }
            return Fixtures.route(policy, candidates).recommendation?.provider
        }

        XCTAssertEqual(leader(.headroom, .standard), "openrouter")
        XCTAssertEqual(leader(.balanced, .standard), "openrouter") // 90 - 15 = 75 > 50
        XCTAssertEqual(leader(.cost, .economy), "openrouter") // 90 - 20 = 70 > 50
        XCTAssertEqual(leader(.cost, .premium), "claude") // 90 - 60 = 30 < 50
    }

    func testCostAndHeadroomCanTieAndTheTieBreakerSaysWhy() {
        let policy = Fixtures.policy { $0.costPreference = .cost; $0.modelTier = .standard }
        let decision = Fixtures.route(policy, [
            Fixtures.candidate(.openRouter, used: 10), // 90 - 40 = 50
            Fixtures.candidate(.claudeCode, used: 50), // 50
        ])

        XCTAssertEqual(decision.recommendation?.score, 50)
        XCTAssertEqual(decision.fallbacks.first?.score, 50)
        XCTAssertEqual(decision.recommendation?.provider, "openrouter")
        XCTAssertTrue(
            decision.reasons.first { $0.code == .tieBreakApplied }?.message.contains("more quota remaining") == true
        )
    }

    func testMeteredAndIncludedRoutesSayWhichTheyAre() {
        let decision = Fixtures.route([
            Fixtures.candidate(.openRouter, used: 10),
            Fixtures.candidate(.claudeCode, used: 20),
        ])
        XCTAssertTrue(decision.chain.contains("openrouter"))
        let included = decision.recommendation?.reasons.map(\.code)
        XCTAssertTrue(included?.contains(.includedQuota) == true)
        XCTAssertTrue(decision.fallbacks.first?.reasons.contains { $0.code == .meteredUsage } == true)
    }

    func testHeadroomOnlyPolicySaysNothingAboutCost() {
        let policy = Fixtures.policy { $0.costPreference = .headroom }
        let decision = Fixtures.route(policy, [Fixtures.candidate(.claudeCode), Fixtures.candidate(.openRouter)])
        for route in [decision.recommendation].compactMap({ $0 }) + decision.fallbacks {
            XCTAssertFalse(route.reasons.contains { $0.code == .includedQuota || $0.code == .meteredUsage })
        }
    }

    // MARK: - Preference, scope, accounts

    func testPreferredProviderDecidesBetweenCloseCandidatesButNotAgainstMuchEmptierOnes() {
        let policy = Fixtures.policy { $0.providerPreference = [.codexCli, .claudeCode] }

        let close = Fixtures.route(policy, [
            Fixtures.candidate(.claudeCode, used: 30), // 70 + 15
            Fixtures.candidate(.codexCli, used: 35), // 65 + 25
        ])
        XCTAssertEqual(close.recommendation?.provider, "codex")
        XCTAssertEqual(close.recommendation?.score, 90)
        XCTAssertTrue(close.recommendation?.reasons.contains { $0.code == .preferredProvider } == true)

        let farApart = Fixtures.route(policy, [
            Fixtures.candidate(.claudeCode, used: 30),
            Fixtures.candidate(.codexCli, used: 80), // 20 + 25 = 45
        ])
        XCTAssertEqual(farApart.recommendation?.provider, "claude")
    }

    func testPreferredOnlyScopeRejectsProvidersOutsideTheList() {
        let policy = Fixtures.policy { $0.providerPreference = [.codexCli]; $0.providerScope = .preferredOnly }
        let decision = Fixtures.route(policy, [Fixtures.candidate(.claudeCode, used: 0), Fixtures.candidate(.codexCli, used: 50)])

        XCTAssertEqual(decision.chain, ["codex"])
        XCTAssertEqual(decision.rejectionCodes, [.providerNotPermitted])
    }

    func testRestrictedAccountsLimitOnlyTheProvidersTheyName() {
        let pinned = Fixtures.uuid(1)
        let policy = Fixtures.policy {
            $0.accountSelection = .restricted
            $0.accounts = [RoutingAccountRef(provider: .claudeCode, accountID: pinned)]
        }
        let decision = Fixtures.route(policy, [
            Fixtures.account(.claudeCode, id: pinned, name: "Work", used: 20),
            Fixtures.account(.claudeCode, id: Fixtures.uuid(2), name: "Personal", used: 0),
            Fixtures.candidate(.claudeCode, used: 0), // provider-wide: cannot prove it is the pinned account
            Fixtures.candidate(.codexCli, used: 50), // no pin for Codex: unaffected
        ])

        XCTAssertEqual(decision.chain, ["claude", "codex"])
        XCTAssertEqual(decision.recommendation?.account?.label, "Work")
        XCTAssertEqual(decision.rejectionCodes, [.accountNotPermitted, .accountNotPermitted])
    }

    func testPreferredAccountsScoreHigherWithoutExcludingTheOthers() {
        let preferred = Fixtures.uuid(1)
        let policy = Fixtures.policy {
            $0.accountSelection = .preferred
            $0.accounts = [RoutingAccountRef(provider: .claudeCode, accountID: preferred)]
        }
        let decision = Fixtures.route(policy, [
            Fixtures.account(.claudeCode, id: preferred, name: "Work", used: 55), // 45 + 10
            Fixtures.account(.claudeCode, id: Fixtures.uuid(2), name: "Personal", used: 50), // 50
        ])

        XCTAssertEqual(decision.chain.count, 2)
        XCTAssertEqual(decision.recommendation?.account?.label, "Work")
        XCTAssertTrue(decision.recommendation?.reasons.contains { $0.code == .preferredAccount } == true)
    }

    func testPinnedAccountsMatchOnlyUnderTheirOwnProvider() {
        let shared = Fixtures.uuid(1)
        let policy = Fixtures.policy {
            $0.accountSelection = .restricted
            $0.accounts = [
                RoutingAccountRef(provider: .claudeCode, accountID: shared),
                RoutingAccountRef(provider: .codexCli, accountID: Fixtures.uuid(2)),
            ]
        }
        let decision = Fixtures.route(policy, [
            Fixtures.account(.claudeCode, id: shared, used: 50),
            // Same id as the pinned Claude account, but pinned Codex accounts
            // are a different list.
            Fixtures.account(.codexCli, id: shared, used: 50),
        ])

        XCTAssertEqual(decision.chain, ["claude"])
        XCTAssertEqual(decision.rejected.map(\.provider), ["codex"])
        XCTAssertEqual(decision.rejectionCodes, [.accountNotPermitted])
    }

    func testDisabledCandidateIsRejected() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, used: 0, enabled: false),
            Fixtures.candidate(.codexCli, used: 50),
        ])
        XCTAssertEqual(decision.rejectionCodes, [.providerDisabled])
        XCTAssertEqual(decision.chain, ["codex"])
    }

    // MARK: - Fallbacks

    func testFallbacksFollowScoreOrderAndAreCappedByThePolicy() {
        let candidates = [
            Fixtures.candidate(.claudeCode, used: 10),
            Fixtures.candidate(.codexCli, used: 30),
            Fixtures.candidate(.cursor, used: 50),
            Fixtures.candidate(.grok, used: 70),
        ]
        let all = Fixtures.route(candidates)
        XCTAssertEqual(all.chain, ["claude", "codex", "cursor", "grok"])
        XCTAssertEqual(all.fallbacks.map(\.rank), [2, 3, 4])

        let capped = Fixtures.route(Fixtures.policy { $0.maximumFallbacks = 1 }, candidates)
        XCTAssertEqual(capped.chain, ["claude", "codex"])

        let none = Fixtures.route(Fixtures.policy { $0.maximumFallbacks = 0 }, candidates)
        XCTAssertEqual(none.chain, ["claude"])
        XCTAssertTrue(none.fallbacks.isEmpty)
    }

    func testPolicyPreferenceOrderingRanksFallbacksByPreferenceBeforeScore() {
        let candidates = [
            Fixtures.candidate(.claudeCode, used: 10), // 90, unlisted
            Fixtures.candidate(.codexCli, used: 30), // 70, unlisted
            Fixtures.candidate(.cursor, used: 50), // 50 + 15
            Fixtures.candidate(.grok, used: 70), // 30 + 25
        ]
        let byScore = Fixtures.route(Fixtures.policy {
            $0.providerPreference = [.grok, .cursor]
        }, candidates)
        XCTAssertEqual(byScore.chain, ["claude", "codex", "cursor", "grok"])

        let byPreference = Fixtures.route(Fixtures.policy {
            $0.providerPreference = [.grok, .cursor]
            $0.fallbackOrder = .policyPreference
        }, candidates)
        XCTAssertEqual(byPreference.recommendation?.provider, "claude")
        XCTAssertEqual(byPreference.chain, ["claude", "grok", "cursor", "codex"])

        let capped = Fixtures.route(Fixtures.policy {
            $0.providerPreference = [.grok, .cursor]
            $0.fallbackOrder = .policyPreference
            $0.maximumFallbacks = 2
        }, candidates)
        XCTAssertEqual(capped.chain, ["claude", "grok", "cursor"])
        XCTAssertEqual(capped.fallbacks.map(\.rank), [2, 3])
    }

    func testFallbacksNeverIncludeRejectedCandidates() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, used: 10),
            Fixtures.candidate(.codexCli, used: 100),
            Fixtures.candidate(.cursor, used: 20, age: 5 * 3_600),
        ])
        XCTAssertEqual(decision.chain, ["claude"])
        XCTAssertEqual(Set(decision.rejectionCodes), [.quotaExhausted, .snapshotStale])
    }

    // MARK: - Outcomes

    func testASingleEligibleProviderIsRecommendedWithoutAnyMultiProviderSetup() {
        let decision = Fixtures.route([Fixtures.candidate(.claudeCode, used: 25)])

        XCTAssertEqual(decision.outcome, .recommended)
        XCTAssertEqual(decision.recommendation?.provider, "claude")
        XCTAssertTrue(decision.fallbacks.isEmpty)
        XCTAssertEqual(decision.reasons.map(\.code), [.onlyEligibleCandidate])
        XCTAssertNil(decision.recommendation?.account)
    }

    func testNoCandidatesIsDataUnavailableAndSaysSo() {
        let decision = Fixtures.route([])

        XCTAssertEqual(decision.outcome, .dataUnavailable)
        XCTAssertEqual(decision.exitCode, 12)
        XCTAssertNil(decision.recommendation)
        XCTAssertEqual(decision.reasons.map(\.code), [.noCandidates])
    }

    func testEveryCandidateRejectedByQuotaIsNoEligibleCandidateWithEveryReason() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, used: 100),
            Fixtures.candidate(.codexCli, used: 95),
            Fixtures.candidate(.cursor, used: 100, enabled: false),
        ])

        XCTAssertEqual(decision.outcome, .noEligibleCandidate)
        XCTAssertEqual(decision.exitCode, 11)
        XCTAssertNil(decision.recommendation)
        XCTAssertEqual(decision.rejectionCodes, [.quotaExhausted, .belowMinimumHeadroom, .providerDisabled])
        XCTAssertEqual(decision.rejected.count, 3)
        XCTAssertTrue(decision.summary.contains("Implementation"))
    }

    func testTrustworthyQuotaRefusalOutranksSomeOtherCandidatesHavingNoData() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, used: 100),
            Fixtures.candidate(.codexCli, used: 5, age: 9 * 3_600),
        ])
        XCTAssertEqual(decision.outcome, .noEligibleCandidate)
    }

    func testEveryCandidateStaleOrMissingIsDataUnavailable() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, used: 5, age: 9 * 3_600),
            RoutingCandidate(service: .cursor, metrics: nil),
        ])
        XCTAssertEqual(decision.outcome, .dataUnavailable)
        XCTAssertEqual(decision.exitCode, 12)
    }

    func testOutcomeExitCodesAreStableAndDistinctFromUsageError() {
        XCTAssertEqual(RoutingOutcome.recommended.exitCode, 0)
        XCTAssertEqual(RoutingOutcome.noEligibleCandidate.exitCode, 11)
        XCTAssertEqual(RoutingOutcome.dataUnavailable.exitCode, 12)
        XCTAssertEqual(RoutingOutcome.usageErrorExitCode, 13)
        XCTAssertEqual(Set(RoutingOutcome.allCases.map(\.exitCode)).count, RoutingOutcome.allCases.count)
    }

    // MARK: - Model selection and labels

    func testTheRouteCarriesTheTierAndOnlyThatProvidersAlias() {
        let policy = Fixtures.policy {
            $0.modelTier = .premium
            $0.modelAliases = [.codexCli: "gpt-test-1"]
        }
        let decision = Fixtures.route(policy, [
            Fixtures.candidate(.codexCli, used: 10),
            Fixtures.candidate(.claudeCode, used: 30),
        ])

        XCTAssertEqual(decision.recommendation?.model, RoutingModelSelection(tier: .premium, alias: "gpt-test-1"))
        XCTAssertEqual(decision.fallbacks.first?.model, RoutingModelSelection(tier: .premium, alias: nil))
        XCTAssertEqual(decision.summary, "Use Codex · gpt-test-1")
    }

    func testTheSummaryNamesProviderAccountAndTierLikeTheEpicExample() {
        let decision = Fixtures.route([Fixtures.account(.codexCli, id: Fixtures.uuid(1), name: "Work", used: 26)])
        XCTAssertEqual(decision.summary, "Use Codex · Work · standard model")
    }

    func testAccountLabelsThatLookLikeEmailsOrPathsAreNeverShown() {
        let decision = Fixtures.route([
            Fixtures.account(.claudeCode, id: Fixtures.uuid(1), name: "vincent@example.com", used: 10, order: 0),
            Fixtures.account(.codexCli, id: Fixtures.uuid(2), name: "/Users/vincent/.codex", used: 20, order: 0),
            Fixtures.account(.grok, id: Fixtures.uuid(3), name: "  Team   Grok ", used: 30, order: 0),
        ])

        XCTAssertEqual(decision.recommendation?.account?.label, "Account 01000000")
        let labels = decision.fallbacks.compactMap(\.account?.label)
        XCTAssertEqual(labels, ["Account 02000000", "Team Grok"])
        let encoded = String(decoding: (try? JSONEncoder().encode(decision)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(encoded.contains("@"))
        XCTAssertFalse(encoded.contains("/Users"))
    }

    func testResetSoonEarnsTheDocumentedBonusAndIsExplained() {
        let decision = Fixtures.route([
            Fixtures.candidate(.claudeCode, session: Fixtures.limit(used: 50, resetIn: 20 * 60)),
        ])
        XCTAssertEqual(decision.recommendation?.score, 54)
        XCTAssertTrue(
            decision.recommendation?.reasons.contains { $0.code == .resetSoon && $0.message == "Quota resets in 20m" } == true
        )
    }

    // MARK: - Helpers

    private func permutations<T>(of items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(of: rest).map { [head] + $0 }
        }
    }
}
