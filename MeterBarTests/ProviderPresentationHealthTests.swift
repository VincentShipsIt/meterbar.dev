import XCTest
@testable import MeterBar
import MeterBarShared

/// Issue #457: every usage card must show connection health separately from
/// quota severity. A stale or failed refresh with a 70%-left cache stays
/// numerically 70% left and must not be labelled Healthy.
final class ProviderPresentationHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let freshAt = Date(timeIntervalSince1970: 1_750_000_000)
    private lazy var staleAt = now.addingTimeInterval(-(ProviderParseHealthRecord.staleAfter + 60))

    private enum FixtureKind: String, CaseIterable {
        case claude
        case codex
        case grok
        case cursor
        case openRouter

        var service: ServiceType {
            switch self {
            case .claude: return .claudeCode
            case .codex: return .codexCli
            case .grok: return .grok
            case .cursor: return .cursor
            case .openRouter: return .openRouter
            }
        }

        var isFlat: Bool {
            self == .cursor || self == .openRouter
        }
    }

    // MARK: - Projection

    func testFreshSuccessCarriesNoNotice() {
        XCTAssertNil(
            ProviderPresentationHealth.notice(
                access: .signedIn,
                refresh: .success,
                lastUpdated: freshAt,
                parseHealth: .success(provider: .cursor, at: freshAt),
                now: now
            )
        )
    }

    func testUnprobedStateIsNotAFailure() {
        XCTAssertNil(
            ProviderPresentationHealth.notice(
                access: .unprobed,
                refresh: .unprobed,
                lastUpdated: nil,
                parseHealth: nil,
                now: now
            )
        )
    }

    func testTransientFailureWithCacheIsStaleAndKeepsTheTimestamp() {
        XCTAssertEqual(
            ProviderPresentationHealth.notice(
                access: .signedIn,
                refresh: .transientFailure,
                lastUpdated: freshAt,
                parseHealth: transientFailureRecord(provider: .codexCli, at: freshAt),
                now: now
            ),
            .stale(since: freshAt)
        )
    }

    func testSustainedFailureWithCacheIsAttention() {
        XCTAssertEqual(
            ProviderPresentationHealth.notice(
                access: .signedIn,
                refresh: .sustainedOrParseFailure,
                lastUpdated: freshAt,
                parseHealth: sustainedFailureRecord(provider: .openRouter, at: freshAt),
                now: now
            ),
            .attention("Refresh failed")
        )
    }

    func testParseFailureWithCacheIsAttention() {
        XCTAssertEqual(
            ProviderPresentationHealth.notice(
                access: .signedIn,
                refresh: .sustainedOrParseFailure,
                lastUpdated: freshAt,
                parseHealth: parseFailureRecord(provider: .grok, at: freshAt),
                now: now
            ),
            .attention("Refresh failed")
        )
    }

    func testStaleCacheAfterSuccessIsStaleNotHealthy() {
        XCTAssertEqual(
            ProviderPresentationHealth.notice(
                access: .signedIn,
                refresh: .success,
                lastUpdated: staleAt,
                parseHealth: .success(provider: .claudeCode, at: staleAt),
                now: now
            ),
            .stale(since: staleAt)
        )
    }

    func testNoDataIsNotAFabricatedFailure() {
        XCTAssertNil(
            ProviderPresentationHealth.notice(
                access: .unprobed,
                refresh: .unprobed,
                lastUpdated: nil,
                parseHealth: nil,
                now: now
            )
        )
        XCTAssertNil(
            ProviderPresentationHealth.notice(
                access: .signedIn,
                refresh: .unprobed,
                lastUpdated: nil,
                parseHealth: nil,
                now: now
            )
        )
    }

    func testLoginRequiredBeatsAHealthyCache() {
        XCTAssertEqual(
            ProviderPresentationHealth.notice(
                access: .loginRequired,
                refresh: .success,
                lastUpdated: freshAt,
                parseHealth: .success(provider: .claudeCode, at: freshAt),
                now: now
            ),
            .loginRequired
        )
    }

    func testNotConnectedBeatsAHealthyCache() {
        XCTAssertEqual(
            ProviderPresentationHealth.notice(
                access: .notConnected,
                refresh: .transientFailure,
                lastUpdated: freshAt,
                parseHealth: nil,
                now: now
            ),
            .notConnected
        )
    }

    func testTransientFailureWithoutCacheIsNotAFabricatedStaleNotice() {
        XCTAssertNil(
            ProviderPresentationHealth.notice(
                access: .signedIn,
                refresh: .transientFailure,
                lastUpdated: nil,
                parseHealth: transientFailureRecord(provider: .cursor, at: freshAt),
                now: now
            )
        )
    }

    func testSustainedFailureWithoutCacheIsNotAFabricatedAttentionNotice() {
        XCTAssertNil(
            ProviderPresentationHealth.notice(
                access: .unprobed,
                refresh: .sustainedOrParseFailure,
                lastUpdated: nil,
                parseHealth: sustainedFailureRecord(provider: .cursor, at: freshAt),
                now: now
            )
        )
    }

    func testPersistedParseFailureWithEmptyLastErrorIsNotSuccess() {
        let lastSuccess = now.addingTimeInterval(-30)
        let lastAttempt = now
        let health = relaunchParseFailureRecord(
            provider: .cursor,
            lastSuccess: lastSuccess,
            lastAttempt: lastAttempt
        )

        XCTAssertEqual(
            ProviderPresentationHealth.refreshOutcome(
                lastError: nil,
                parseHealth: health,
                lastUpdated: lastSuccess
            ),
            .sustainedOrParseFailure
        )
        XCTAssertEqual(
            ProviderPresentationHealth.notice(
                access: .signedIn,
                refresh: .sustainedOrParseFailure,
                lastUpdated: lastSuccess,
                parseHealth: health,
                now: now
            ),
            .attention("Refresh failed")
        )
    }

    func testCardCacheAsNewAsTheFailedAttemptIsStillSuccess() {
        let lastSuccess = now.addingTimeInterval(-30)
        let lastAttempt = now
        XCTAssertEqual(
            ProviderPresentationHealth.refreshOutcome(
                lastError: nil,
                parseHealth: relaunchParseFailureRecord(
                    provider: .codexCli,
                    lastSuccess: lastSuccess,
                    lastAttempt: lastAttempt
                ),
                lastUpdated: lastAttempt
            ),
            .success
        )
    }

    // MARK: - Builder fixtures: all five providers

    func testFreshSuccessHasNoOverlayAndKeepsTheBand() throws {
        for kind in FixtureKind.allCases {
            let card = try card(
                kind,
                lastUpdated: freshAt,
                refresh: .success,
                parseHealth: .success(provider: kind.service, at: freshAt)
            )

            XCTAssertNil(card.authNotice, "\(kind.rawValue) fresh success must not overlay the band")
            XCTAssertEqual(card.band, .healthy, "\(kind.rawValue) must keep the cached 30%-used band")
            XCTAssertEqual(ProviderCardPresentation.statusText(for: card), QuotaBand.healthy.shortLabel)
            XCTAssertEqual(ProviderCardPresentation.statusColor(for: card), QuotaBand.healthy.color)
            XCTAssertTrue(card.accessibilityLabel.contains(QuotaBand.healthy.shortLabel))
            XCTAssertFalse(recommendationUnavailable(card))
        }
    }

    func testTransientFailureWithCacheShowsStaleKeepsNumbers() throws {
        for kind in FixtureKind.allCases {
            let card = try card(
                kind,
                lastUpdated: freshAt,
                refresh: .transientFailure,
                parseHealth: transientFailureRecord(provider: kind.service, at: freshAt)
            )

            XCTAssertEqual(card.authNotice, .stale(since: freshAt), kind.rawValue)
            XCTAssertEqual(card.band, .healthy, "\(kind.rawValue) numbers stay 70% left")
            XCTAssertEqual(card.primaryLimit?.percentLeft, 70)
            XCTAssertEqual(ProviderCardPresentation.statusText(for: card), "Stale")
            XCTAssertEqual(ProviderCardPresentation.statusColor(for: card), .secondary)
            XCTAssertTrue(card.accessibilityLabel.contains("Stale"), card.accessibilityLabel)
            XCTAssertFalse(
                card.accessibilityLabel.contains(QuotaBand.healthy.shortLabel),
                "VoiceOver must not read a stale \(kind.rawValue) cache as Healthy"
            )
            XCTAssertTrue(recommendationUnavailable(card), "\(kind.rawValue) stale cache is not live")
        }
    }

    func testSustainedOrParseFailureWithCacheShowsAttentionNotHealthy() throws {
        for kind in FixtureKind.allCases {
            let card = try card(
                kind,
                lastUpdated: freshAt,
                refresh: .sustainedOrParseFailure,
                parseHealth: parseFailureRecord(provider: kind.service, at: freshAt)
            )

            XCTAssertEqual(card.authNotice, .attention("Refresh failed"), kind.rawValue)
            XCTAssertEqual(card.band, .healthy, "\(kind.rawValue) band stays a function of the cached percentages")
            XCTAssertEqual(ProviderCardPresentation.statusText(for: card), "Needs attention")
            XCTAssertEqual(ProviderCardPresentation.statusColor(for: card), MeterBarTheme.warning)
            XCTAssertTrue(card.accessibilityLabel.contains("Needs attention"), card.accessibilityLabel)
            XCTAssertFalse(card.accessibilityLabel.contains(QuotaBand.healthy.shortLabel))
            XCTAssertTrue(recommendationUnavailable(card))
        }
    }

    func testStaleCacheAfterLastSuccessShowsStaleNotHealthy() throws {
        for kind in FixtureKind.allCases {
            let card = try card(
                kind,
                lastUpdated: staleAt,
                refresh: .success,
                parseHealth: .success(provider: kind.service, at: staleAt)
            )

            XCTAssertEqual(card.authNotice, .stale(since: staleAt), kind.rawValue)
            XCTAssertEqual(card.band, .healthy)
            XCTAssertEqual(ProviderCardPresentation.statusText(for: card), "Stale")
            XCTAssertNotEqual(ProviderCardPresentation.statusText(for: card), QuotaBand.healthy.shortLabel)
            XCTAssertTrue(recommendationUnavailable(card))
        }
    }

    func testNoDataStaysEmptyOfflineNotAFabricatedFailure() throws {
        for kind in FixtureKind.allCases {
            let card = try emptyCard(kind)

            XCTAssertNil(card.authNotice, "\(kind.rawValue) unprobed empty must not invent a failure")
            XCTAssertFalse(card.hasMetrics)
            XCTAssertNil(card.band)
            XCTAssertEqual(ProviderCardPresentation.statusText(for: card), "Offline")
            XCTAssertTrue(card.accessibilityLabel.contains("No data"), card.accessibilityLabel)
            XCTAssertFalse(card.accessibilityLabel.contains("Needs attention"))
            XCTAssertFalse(card.accessibilityLabel.contains("Stale"))
        }
    }

    // MARK: - Mixed profiles

    func testOneFailedCustomProfileDoesNotMarkHealthySiblings() throws {
        let claudeWork = ClaudeCodeAccount(id: UUID(), name: "Claude Work", configDirectory: "/tmp/claude-work")
        let codexWork = CodexAccount(id: UUID(), name: "Codex Work", homeDirectory: "/tmp/codex-work")
        let grokWork = GrokAccount(id: UUID(), name: "Grok Work", homeDirectory: "/tmp/grok-work")

        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: [:],
                now: now,
                parseHealth: [
                    .claudeCode: .success(provider: .claudeCode, at: freshAt),
                    .codexCli: .success(provider: .codexCli, at: freshAt),
                    .grok: .success(provider: .grok, at: freshAt)
                ],
                codexAccounts: [.defaultAccount, codexWork],
                codexAccountMetrics: [
                    CodexAccount.defaultID: healthyMetrics(.codexCli, lastUpdated: freshAt),
                    codexWork.id: healthyMetrics(.codexCli, lastUpdated: freshAt)
                ],
                codexAccountAccess: [CodexAccount.defaultID: true, codexWork.id: true],
                grokAccounts: [.defaultAccount, grokWork],
                grokAccountMetrics: [
                    GrokAccount.defaultID: healthyMetrics(.grok, lastUpdated: freshAt),
                    grokWork.id: healthyMetrics(.grok, lastUpdated: freshAt)
                ],
                grokAccountAccess: [GrokAccount.defaultID: true, grokWork.id: true],
                claudeAccounts: [.defaultAccount, claudeWork],
                claudeAccountMetrics: [
                    ClaudeCodeAccount.defaultID: healthyMetrics(.claudeCode, lastUpdated: freshAt),
                    claudeWork.id: healthyMetrics(.claudeCode, lastUpdated: freshAt)
                ],
                enabledServices: [.claudeCode, .codexCli, .grok],
                claudeAccountStates: [
                    ClaudeCodeAccount.defaultID: .connected(.oauth),
                    claudeWork.id: .error("Work refresh failed")
                ],
                claudeCodeHasAccess: true,
                codexCliHasAccess: true,
                grokHasAccess: true,
                lastErrors: ProviderPresentationHealth.LastErrors(
                    codexAccounts: [codexWork.id: .apiError("Codex work failed")],
                    grokAccounts: [grokWork.id: .parsingError("Grok work failed")]
                )
            )
        )

        let claudeDefault = try XCTUnwrap(snapshots.first { $0.accountID == ClaudeCodeAccount.defaultID })
        let claudeFailed = try XCTUnwrap(snapshots.first { $0.accountID == claudeWork.id })
        let codexDefault = try XCTUnwrap(snapshots.first { $0.accountID == CodexAccount.defaultID })
        let codexFailed = try XCTUnwrap(snapshots.first { $0.accountID == codexWork.id })
        let grokDefault = try XCTUnwrap(snapshots.first { $0.accountID == GrokAccount.defaultID })
        let grokFailed = try XCTUnwrap(snapshots.first { $0.accountID == grokWork.id })

        XCTAssertNil(claudeDefault.authNotice)
        XCTAssertEqual(ProviderCardPresentation.statusText(for: claudeDefault), QuotaBand.healthy.shortLabel)
        XCTAssertEqual(claudeFailed.authNotice, .attention("Work refresh failed"))
        XCTAssertEqual(claudeFailed.band, .healthy)

        XCTAssertNil(codexDefault.authNotice)
        XCTAssertEqual(ProviderCardPresentation.statusText(for: codexDefault), QuotaBand.healthy.shortLabel)
        XCTAssertEqual(codexFailed.authNotice, .stale(since: freshAt))
        XCTAssertEqual(codexFailed.band, .healthy)

        XCTAssertNil(grokDefault.authNotice)
        XCTAssertEqual(ProviderCardPresentation.statusText(for: grokDefault), QuotaBand.healthy.shortLabel)
        XCTAssertEqual(grokFailed.authNotice, .stale(since: freshAt))
        XCTAssertEqual(grokFailed.band, .healthy)

        let recommendation = snapshots.headroomRecommendation(now: now)
        let unavailableIDs = Set(recommendation.unavailable.map(\.id))
        XCTAssertFalse(unavailableIDs.contains(claudeDefault.id))
        XCTAssertFalse(unavailableIDs.contains(codexDefault.id))
        XCTAssertFalse(unavailableIDs.contains(grokDefault.id))
        XCTAssertTrue(unavailableIDs.contains(claudeFailed.id))
        XCTAssertTrue(unavailableIDs.contains(codexFailed.id))
        XCTAssertTrue(unavailableIDs.contains(grokFailed.id))
    }

    func testClaudeConnectedButAgedCacheIsStaleNotHealthy() throws {
        let card = try card(
            .claude,
            lastUpdated: staleAt,
            refresh: .success,
            parseHealth: .success(provider: .claudeCode, at: staleAt),
            claudeState: .connected(.oauth)
        )

        XCTAssertEqual(card.authNotice, .stale(since: staleAt))
        XCTAssertEqual(card.band, .healthy)
        XCTAssertEqual(ProviderCardPresentation.statusText(for: card), "Stale")
    }

    func testRelaunchWithPersistedParseFailureAndFreshCacheIsNotHealthy() throws {
        let lastSuccess = now.addingTimeInterval(-30)
        for kind in FixtureKind.allCases {
            let health = relaunchParseFailureRecord(
                provider: kind.service,
                lastSuccess: lastSuccess,
                lastAttempt: now
            )
            let card = try relaunchCard(kind, lastUpdated: lastSuccess, parseHealth: health)

            XCTAssertEqual(card.authNotice, .attention("Refresh failed"), kind.rawValue)
            XCTAssertEqual(card.band, .healthy, "\(kind.rawValue) keeps the cached percentages")
            XCTAssertNotEqual(
                ProviderCardPresentation.statusText(for: card),
                QuotaBand.healthy.shortLabel,
                "\(kind.rawValue) must not look live after a persisted parse failure"
            )
            XCTAssertTrue(card.accessibilityLabel.contains("Needs attention"), card.accessibilityLabel)
            XCTAssertTrue(recommendationUnavailable(card))
        }
    }

    func testPersistedProviderFailureDoesNotMarkSiblingWithNewerCache() throws {
        let lastSuccess = now.addingTimeInterval(-30)
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: [:],
                now: now,
                parseHealth: [
                    .codexCli: relaunchParseFailureRecord(
                        provider: .codexCli,
                        lastSuccess: lastSuccess,
                        lastAttempt: now
                    )
                ],
                codexAccounts: [.defaultAccount, work],
                codexAccountMetrics: [
                    CodexAccount.defaultID: healthyMetrics(.codexCli, lastUpdated: lastSuccess),
                    work.id: healthyMetrics(.codexCli, lastUpdated: now)
                ],
                codexAccountAccess: [CodexAccount.defaultID: true, work.id: true],
                claudeAccounts: [],
                claudeAccountMetrics: [:],
                enabledServices: [.codexCli]
            )
        )

        let failed = try XCTUnwrap(snapshots.first { $0.accountID == CodexAccount.defaultID })
        let newer = try XCTUnwrap(snapshots.first { $0.accountID == work.id })
        XCTAssertEqual(failed.authNotice, .attention("Refresh failed"))
        XCTAssertNil(newer.authNotice, "A sibling whose cache is as new as the attempt is not failed")
        XCTAssertEqual(ProviderCardPresentation.statusText(for: newer), QuotaBand.healthy.shortLabel)
    }

    func testSignedOutCursorWithFreshCacheIsNotHealthy() throws {
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: [.cursor: healthyMetrics(.cursor, lastUpdated: freshAt)],
                now: now,
                claudeAccounts: [],
                claudeAccountMetrics: [:],
                enabledServices: [.cursor],
                cursorHasAccess: false
            )
        )

        let card = try XCTUnwrap(snapshots.first { $0.service == .cursor })
        XCTAssertEqual(card.authNotice, .loginRequired)
        XCTAssertEqual(card.band, .healthy, "The cached percentages stay healthy")
        XCTAssertEqual(ProviderCardPresentation.statusText(for: card), "Login required")
        XCTAssertNotEqual(ProviderCardPresentation.statusText(for: card), QuotaBand.healthy.shortLabel)
    }

    func testSignedOutOpenRouterWithFreshCacheIsNotHealthy() throws {
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: [.openRouter: healthyMetrics(.openRouter, lastUpdated: freshAt)],
                now: now,
                claudeAccounts: [],
                claudeAccountMetrics: [:],
                enabledServices: [.openRouter],
                openRouterAccounts: [.defaultAccount],
                openRouterAccountAccess: [OpenRouterAccount.defaultID: false]
            )
        )

        let card = try XCTUnwrap(snapshots.first { $0.service == .openRouter })
        XCTAssertEqual(card.authNotice, .notConnected)
        XCTAssertEqual(card.band, .healthy)
        XCTAssertEqual(ProviderCardPresentation.statusText(for: card), "Not connected")
        XCTAssertNotEqual(ProviderCardPresentation.statusText(for: card), QuotaBand.healthy.shortLabel)
    }

    func testUnprobedCursorWithFreshCacheIsNotTreatedAsSignedOut() throws {
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: [.cursor: healthyMetrics(.cursor, lastUpdated: freshAt)],
                now: now,
                claudeAccounts: [],
                claudeAccountMetrics: [:],
                enabledServices: [.cursor]
            )
        )

        let card = try XCTUnwrap(snapshots.first { $0.service == .cursor })
        XCTAssertNil(card.authNotice, "Unknown/unprobed is not a fabricated login failure")
        XCTAssertEqual(ProviderCardPresentation.statusText(for: card), QuotaBand.healthy.shortLabel)
    }

    func testCursorClaudeLoginStateDoesNotLeakOntoAFreshCursorCard() throws {
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: [.cursor: healthyMetrics(.cursor, lastUpdated: freshAt)],
                now: now,
                parseHealth: [.cursor: .success(provider: .cursor, at: freshAt)],
                claudeAccounts: [.defaultAccount],
                claudeAccountMetrics: [:],
                enabledServices: [.cursor],
                claudeAccountStates: [ClaudeCodeAccount.defaultID: .needsLogin],
                cursorHasAccess: true
            )
        )

        let cursor = try XCTUnwrap(snapshots.first { $0.service == .cursor })
        XCTAssertNil(cursor.authNotice)
        XCTAssertEqual(ProviderCardPresentation.statusText(for: cursor), QuotaBand.healthy.shortLabel)
    }

    // MARK: - Helpers

    private func card(
        _ kind: FixtureKind,
        lastUpdated: Date,
        refresh: ProviderPresentationHealth.RefreshOutcome,
        parseHealth: ProviderParseHealthRecord,
        claudeState: ClaudeCodeAuthState? = nil
    ) throws -> ProviderSnapshot {
        let metrics = healthyMetrics(kind.service, lastUpdated: lastUpdated)
        let snapshots = ProviderSnapshotBuilder.snapshots(input(
            kind,
            metrics: metrics,
            refresh: refresh,
            parseHealth: parseHealth,
            claudeState: claudeState
        ))
        return try XCTUnwrap(snapshots.first { $0.service == kind.service }, kind.rawValue)
    }

    private func relaunchCard(
        _ kind: FixtureKind,
        lastUpdated: Date,
        parseHealth: ProviderParseHealthRecord
    ) throws -> ProviderSnapshot {
        let metrics = healthyMetrics(kind.service, lastUpdated: lastUpdated)
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: kind.isFlat ? [kind.service: metrics] : [:],
                now: now,
                parseHealth: [kind.service: parseHealth],
                codexAccounts: kind == .codex ? [.defaultAccount] : [],
                codexAccountMetrics: kind == .codex ? [CodexAccount.defaultID: metrics] : [:],
                grokAccounts: kind == .grok ? [.defaultAccount] : [],
                grokAccountMetrics: kind == .grok ? [GrokAccount.defaultID: metrics] : [:],
                claudeAccounts: kind == .claude ? [.defaultAccount] : [],
                claudeAccountMetrics: kind == .claude ? [ClaudeCodeAccount.defaultID: metrics] : [:],
                enabledServices: [kind.service],
                cursorHasAccess: kind == .cursor ? true : nil,
                openRouterAccounts: kind == .openRouter ? [.defaultAccount] : [],
                openRouterAccountMetrics: kind == .openRouter
                    ? [OpenRouterAccount.defaultID: metrics]
                    : [:],
                openRouterAccountAccess: kind == .openRouter
                    ? [OpenRouterAccount.defaultID: true]
                    : [:]
            )
        )
        return try XCTUnwrap(snapshots.first { $0.service == kind.service }, kind.rawValue)
    }

    private func emptyCard(_ kind: FixtureKind) throws -> ProviderSnapshot {
        let snapshots = ProviderSnapshotBuilder.snapshots(input(
            kind,
            metrics: nil,
            refresh: .unprobed,
            parseHealth: nil,
            claudeState: nil
        ))
        return try XCTUnwrap(snapshots.first { $0.service == kind.service }, kind.rawValue)
    }

    private func input(
        _ kind: FixtureKind,
        metrics: UsageMetrics?,
        refresh: ProviderPresentationHealth.RefreshOutcome,
        parseHealth: ProviderParseHealthRecord?,
        claudeState: ClaudeCodeAuthState?
    ) -> ProviderSnapshotBuilder.Input {
        var lastErrors = ProviderPresentationHealth.LastErrors()
        switch (kind, refresh) {
        case (.cursor, .transientFailure), (.cursor, .sustainedOrParseFailure):
            lastErrors.cursor = .apiError("Cursor refresh failed")
        case (.openRouter, .transientFailure), (.openRouter, .sustainedOrParseFailure):
            // Key-scoped cards read only their own key's error.
            lastErrors.openRouterAccounts = [
                OpenRouterAccount.defaultID: .apiError("OpenRouter refresh failed")
            ]
        case (.codex, .transientFailure), (.codex, .sustainedOrParseFailure):
            lastErrors.codexAccounts = [CodexAccount.defaultID: .apiError("Codex refresh failed")]
        case (.grok, .transientFailure), (.grok, .sustainedOrParseFailure):
            lastErrors.grokAccounts = [GrokAccount.defaultID: .apiError("Grok refresh failed")]
        default:
            break
        }

        var claudeStates: [UUID: ClaudeCodeAuthState] = [:]
        if kind == .claude {
            switch refresh {
            case .unprobed:
                break
            case .success:
                claudeStates[ClaudeCodeAccount.defaultID] = claudeState ?? .connected(.oauth)
            case .transientFailure:
                claudeStates[ClaudeCodeAccount.defaultID] = .stale(since: metrics?.lastUpdated ?? freshAt)
            case .sustainedOrParseFailure:
                claudeStates[ClaudeCodeAccount.defaultID] = .error("Refresh failed")
            }
        }

        return ProviderSnapshotBuilder.Input(
            metrics: kind.isFlat ? metrics.map { [kind.service: $0] } ?? [:] : [:],
            now: now,
            parseHealth: parseHealth.map { [kind.service: $0] } ?? [:],
            codexAccounts: kind == .codex ? [.defaultAccount] : [],
            codexAccountMetrics: kind == .codex ? metrics.map { [CodexAccount.defaultID: $0] } ?? [:] : [:],
            codexAccountAccess: kind == .codex && refresh != .unprobed ? [CodexAccount.defaultID: true] : [:],
            grokAccounts: kind == .grok ? [.defaultAccount] : [],
            grokAccountMetrics: kind == .grok ? metrics.map { [GrokAccount.defaultID: $0] } ?? [:] : [:],
            grokAccountAccess: kind == .grok && refresh != .unprobed ? [GrokAccount.defaultID: true] : [:],
            claudeAccounts: kind == .claude ? [.defaultAccount] : [],
            claudeAccountMetrics: kind == .claude ? metrics.map { [ClaudeCodeAccount.defaultID: $0] } ?? [:] : [:],
            enabledServices: [kind.service],
            claudeAccountStates: claudeStates,
            claudeCodeHasAccess: kind == .claude && refresh != .unprobed,
            codexCliHasAccess: kind == .codex && refresh != .unprobed,
            cursorHasAccess: kind == .cursor && refresh != .unprobed ? true : nil,
            openRouterAccounts: kind == .openRouter ? [.defaultAccount] : [],
            openRouterAccountMetrics: kind == .openRouter
                ? metrics.map { [OpenRouterAccount.defaultID: $0] } ?? [:]
                : [:],
            openRouterAccountAccess: kind == .openRouter && refresh != .unprobed
                ? [OpenRouterAccount.defaultID: true]
                : [:],
            grokHasAccess: kind == .grok && refresh != .unprobed,
            lastErrors: lastErrors
        )
    }

    private func healthyMetrics(_ service: ServiceType, lastUpdated: Date) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: UsageLimit(used: 30, total: 100, resetTime: nil),
            lastUpdated: lastUpdated
        )
    }

    private func recommendationUnavailable(_ snapshot: ProviderSnapshot) -> Bool {
        [snapshot].headroomRecommendation(now: now).unavailable.contains { $0.id == snapshot.id }
    }

    private func transientFailureRecord(provider: ServiceType, at date: Date) -> ProviderParseHealthRecord {
        ProviderParseHealthRecord(
            provider: provider,
            lastSuccess: date,
            lastAttempt: date,
            consecutiveFailures: 1,
            lastFailureWasShapeMismatch: false
        )
    }

    private func sustainedFailureRecord(provider: ServiceType, at date: Date) -> ProviderParseHealthRecord {
        ProviderParseHealthRecord(
            provider: provider,
            lastSuccess: date,
            lastAttempt: date,
            consecutiveFailures: ProviderParseHealthRecord.sustainedFailureCount,
            lastFailureWasShapeMismatch: false
        )
    }

    /// After relaunch, parse health still has the failed attempt and
    /// `lastError` is empty. `lastSuccess` is older than `lastAttempt`.
    private func relaunchParseFailureRecord(
        provider: ServiceType,
        lastSuccess: Date,
        lastAttempt: Date
    ) -> ProviderParseHealthRecord {
        ProviderParseHealthRecord(
            provider: provider,
            lastSuccess: lastSuccess,
            lastAttempt: lastAttempt,
            consecutiveFailures: ProviderParseHealthRecord.sustainedShapeMismatchCount,
            lastFailureWasShapeMismatch: true,
            consecutiveShapeMismatches: ProviderParseHealthRecord.sustainedShapeMismatchCount
        )
    }

    private func parseFailureRecord(provider: ServiceType, at date: Date) -> ProviderParseHealthRecord {
        ProviderParseHealthRecord(
            provider: provider,
            lastSuccess: date,
            lastAttempt: date,
            consecutiveFailures: ProviderParseHealthRecord.sustainedShapeMismatchCount,
            lastFailureWasShapeMismatch: true,
            consecutiveShapeMismatches: ProviderParseHealthRecord.sustainedShapeMismatchCount
        )
    }
}
