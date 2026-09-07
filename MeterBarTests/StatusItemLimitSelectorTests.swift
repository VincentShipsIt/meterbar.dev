import XCTest
@testable import MeterBar
import MeterBarShared

final class StatusItemLimitSelectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func candidate(
        key: String,
        percentUsed: Double,
        activeMinutesAgo: Double? = nil,
        displayName: String? = nil,
        pinKey: String? = nil,
        windowName: String = "Session",
        isAutoSelectable: Bool = true,
        service: ServiceType = .claudeCode
    ) -> StatusLimitCandidate {
        StatusLimitCandidate(
            key: key,
            pinKey: pinKey ?? key,
            service: service,
            displayName: displayName ?? key,
            windowName: windowName,
            limit: UsageLimit(used: percentUsed, total: 100, resetTime: nil),
            lastActivity: activeMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
            isAutoSelectable: isAutoSelectable
        )
    }

    private func select(
        _ candidates: [StatusLimitCandidate],
        previousKey: String? = nil,
        pinnedKey: String? = nil
    ) -> StatusLimitCandidate? {
        StatusItemLimitSelector.select(
            candidates: candidates,
            previousKey: previousKey,
            pinnedKey: pinnedKey,
            now: now
        )
    }

    // MARK: - Basics

    func testEmptyCandidatesReturnsNil() {
        XCTAssertNil(select([]))
    }

    func testSingleCandidateIsSelectedEvenWhenIdle() {
        let only = candidate(key: "codex", percentUsed: 20, activeMinutesAgo: nil)
        XCTAssertEqual(select([only])?.key, "codex")
    }

    func testProviderAutoWindowPolicyPreservesExistingWindowsAndAddsOpenRouterCredits() {
        XCTAssertEqual(StatusItemAutoSelectionPolicy.windowID(for: .claudeCode), "session")
        XCTAssertEqual(StatusItemAutoSelectionPolicy.windowID(for: .codexCli), "session")
        XCTAssertEqual(StatusItemAutoSelectionPolicy.windowID(for: .cursor), "weekly")
        XCTAssertEqual(StatusItemAutoSelectionPolicy.windowID(for: .openRouter), "weekly")
        XCTAssertEqual(StatusItemAutoSelectionPolicy.windowID(for: .grok), "weekly")
    }

    func testGrokWeeklyQuotaProducesAnAutomaticAccountCandidate() {
        let limits = ProviderSnapshotBuilder.limits(
            for: UsageMetrics(
                service: .grok,
                weeklyLimit: UsageLimit(used: 35, total: 100, resetTime: now.addingTimeInterval(3_600))
            ),
            service: .grok
        )

        let seeds = StatusItemLimitCandidateBuilder.seeds(
            service: .grok,
            accountID: UUID(),
            autoSelectionKey: "grok:profile",
            displayName: "Work (Grok)",
            limits: limits
        )

        XCTAssertEqual(seeds.first(where: \.isAutoSelectable)?.key, "grok:profile")
        XCTAssertEqual(seeds.first(where: \.isAutoSelectable)?.windowName, "Weekly")
    }

    private func cursorMetricsWithGrokBot(weeklyUsed: Double, grokBotUsed: Double) -> UsageMetrics {
        UsageMetrics(
            service: .cursor,
            sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil, periodKind: .monthly),
            weeklyLimit: UsageLimit(used: weeklyUsed, total: 100, resetTime: nil, periodKind: .monthly),
            additionalLimits: [
                UsageLimit(used: grokBotUsed, total: 100, resetTime: now.addingTimeInterval(3_600), periodKind: .weekly)
            ]
        )
    }

    /// Cursor Ultra's Grok Bot pool is its own card in the popover, so it must
    /// also be its own automatic menu-bar candidate instead of hiding as a
    /// never-selectable "additional" limit behind Cursor's weekly pool.
    func testCursorGrokBotPoolProducesItsOwnAutomaticCandidate() {
        let limits = ProviderSnapshotBuilder.limits(
            for: cursorMetricsWithGrokBot(weeklyUsed: 100, grokBotUsed: 17),
            service: .cursor
        )
        let seeds = StatusItemLimitCandidateBuilder.seeds(
            service: .cursor,
            accountID: nil,
            autoSelectionKey: "cursor",
            displayName: "Cursor",
            limits: limits
        )

        let auto = seeds.filter(\.isAutoSelectable)
        XCTAssertEqual(auto.map(\.windowID), ["weekly", "grokBot"])
        XCTAssertEqual(auto.map(\.key), ["cursor", "cursor:grokBot"])
        XCTAssertEqual(
            auto.last?.pinKey,
            StatusItemPinKey.make(service: .cursor, accountID: nil, windowID: "grokBot")
        )
        XCTAssertEqual(auto.last?.windowName, "Grok Bot")
    }

    /// With Claude, Codex and Cursor's weekly pool all spent, the Grok Bot pool
    /// is the only quota left and must win instead of the pool falling back to
    /// a spent Claude window.
    func testGrokBotWinsWhenEveryOtherAutomaticCandidateIsSpent() {
        let claude = candidate(key: "claude:default", percentUsed: 100, activeMinutesAgo: 1)
        let codex = candidate(key: "codex:default", percentUsed: 100, service: .codexCli)
        let cursorWeekly = candidate(key: "cursor", percentUsed: 100, windowName: "Weekly", service: .cursor)
        let grokBot = candidate(
            key: "cursor:grokBot",
            percentUsed: 17,
            displayName: "Cursor",
            pinKey: StatusItemPinKey.make(service: .cursor, accountID: nil, windowID: "grokBot"),
            windowName: "Grok Bot",
            service: .cursor
        )

        XCTAssertEqual(select([claude, codex, cursorWeekly, grokBot])?.key, "cursor:grokBot")
    }

    /// When OpenAI temporarily disables the 5-hour window, Codex still reports a
    /// weekly window. Auto must fall back to weekly so the menu bar is not left
    /// without a Codex candidate.
    func testCodexWeeklyOnlyQuotaFallsBackToWeeklyForAutoSelection() {
        let limits = ProviderSnapshotBuilder.limits(
            for: UsageMetrics(
                service: .codexCli,
                weeklyLimit: UsageLimit(used: 19, total: 100, resetTime: now.addingTimeInterval(3_600))
            ),
            service: .codexCli
        )
        let seeds = StatusItemLimitCandidateBuilder.seeds(
            service: .codexCli,
            accountID: CodexAccount.defaultID,
            autoSelectionKey: "codex:\(CodexAccount.defaultID.uuidString)",
            displayName: "Codex",
            limits: limits
        )

        XCTAssertEqual(seeds.map(\.windowName), ["Weekly"])
        XCTAssertEqual(seeds.filter(\.isAutoSelectable).map(\.windowName), ["Weekly"])
    }

    /// Grok never auto-won while its activity probe was hard-coded to `nil`
    /// and Claude still had recent on-disk activity. Active Grok must win.
    func testActiveGrokBeatsIdleClaudeInAutoSelection() {
        let idleClaude = candidate(
            key: "claude:default",
            percentUsed: 66,
            activeMinutesAgo: nil,
            service: .claudeCode
        )
        let activeGrok = candidate(
            key: "grok:default",
            percentUsed: 19,
            activeMinutesAgo: 1,
            windowName: "Weekly",
            service: .grok
        )
        XCTAssertEqual(select([idleClaude, activeGrok])?.key, "grok:default")
    }

    func testOpenRouterAccountCreditsParticipateInAutoSelection() {
        let metrics = UsageMetrics(
            service: .openRouter,
            sessionLimit: UsageLimit(used: 10, total: 100, resetTime: now.addingTimeInterval(3600)),
            weeklyLimit: UsageLimit(used: 80, total: 100, resetTime: nil)
        )
        let seeds = StatusItemLimitCandidateBuilder.seeds(
            service: .openRouter,
            accountID: nil,
            autoSelectionKey: nil,
            displayName: ServiceType.openRouter.displayName,
            limits: ProviderSnapshotBuilder.limits(for: metrics, service: .openRouter)
        )
        let candidates = seeds.map { seed in
            StatusLimitCandidate(
                key: seed.key,
                pinKey: seed.pinKey,
                service: seed.service,
                displayName: seed.displayName,
                windowName: seed.windowName,
                limit: seed.limit,
                lastActivity: nil,
                isAutoSelectable: seed.isAutoSelectable
            )
        }
        let idleCodex = candidate(key: "codex-idle", percentUsed: 30)
        let activeCodex = candidate(
            key: "codex-active",
            percentUsed: 30,
            activeMinutesAgo: 5
        )

        XCTAssertEqual(seeds.filter(\.isAutoSelectable).map(\.windowName), ["Account credits"])
        XCTAssertEqual(select(candidates + [idleCodex])?.windowName, "Account credits")
        XCTAssertEqual(select(candidates + [activeCodex])?.key, activeCodex.key)
    }

    // MARK: - Active-account filtering

    func testTightestAmongActiveWinsOverTighterIdleAccount() {
        // The idle account is far tighter (10% left) but hasn't been used;
        // the menu bar should follow the accounts actually in use.
        let idleTight = candidate(key: "claude:old", percentUsed: 90, activeMinutesAgo: nil)
        let activeLoose = candidate(key: "claude:ship", percentUsed: 40, activeMinutesAgo: 5)
        XCTAssertEqual(select([idleTight, activeLoose])?.key, "claude:ship")
    }

    func testStaleActivityBeyondWindowCountsAsIdle() {
        let stale = candidate(key: "claude:old", percentUsed: 90, activeMinutesAgo: 31)
        let active = candidate(key: "codex", percentUsed: 40, activeMinutesAgo: 5)
        XCTAssertEqual(select([stale, active])?.key, "codex")
    }

    func testActivityExactlyAtWindowBoundaryCountsAsActive() {
        let boundary = candidate(key: "claude:ship", percentUsed: 90, activeMinutesAgo: 30)
        let active = candidate(key: "codex", percentUsed: 40, activeMinutesAgo: 5)
        XCTAssertEqual(select([boundary, active])?.key, "claude:ship")
    }

    func testFallsBackToTightestOverallWhenNothingIsActive() {
        // Preserves the pre-feature behavior when no account shows recent use.
        let loose = candidate(key: "codex", percentUsed: 20, activeMinutesAgo: nil)
        let tight = candidate(key: "claude:ship", percentUsed: 80, activeMinutesAgo: 120)
        XCTAssertEqual(select([loose, tight])?.key, "claude:ship")
    }

    // MARK: - Exhausted quotas

    func testExhaustedActiveAccountYieldsToAnAccountThatHasQuotaLeft() {
        // The reported bug: Codex sat at 0% for days, and because it is always
        // the tightest candidate it owned the menu bar the whole time.
        let spentCodex = candidate(key: "codex", percentUsed: 100, activeMinutesAgo: 1)
        let liveClaude = candidate(key: "claude:gen", percentUsed: 48)
        XCTAssertEqual(select([spentCodex, liveClaude])?.key, "claude:gen")
    }

    func testExhaustedAccountIsSkippedInTheIdleFallbackPoolToo() {
        let spentCodex = candidate(key: "codex", percentUsed: 100)
        let liveClaude = candidate(key: "claude:gen", percentUsed: 60)
        XCTAssertEqual(select([spentCodex, liveClaude])?.key, "claude:gen")
    }

    func testNearlyExhaustedAccountStillCompetes() {
        // 99.6% used still reads "1% left" — only a truly spent quota is skipped.
        let nearlySpent = candidate(key: "codex", percentUsed: 99.6, activeMinutesAgo: 1)
        let claude = candidate(key: "claude:gen", percentUsed: 48, activeMinutesAgo: 1)
        XCTAssertEqual(select([nearlySpent, claude])?.key, "codex")
    }

    func testEveryCandidateExhaustedStillShowsAQuota() {
        // Skipping them all would blank the label; the pool is restored instead.
        let codex = candidate(key: "codex", percentUsed: 100, activeMinutesAgo: 1)
        let claude = candidate(key: "claude:gen", percentUsed: 100)
        XCTAssertEqual(select([codex, claude])?.key, "codex")
    }

    func testStickySelectionDoesNotKeepAnExhaustedAccount() {
        // Without the exhausted filter, hysteresis re-elects the 0% account.
        let spentCodex = candidate(key: "codex", percentUsed: 100, activeMinutesAgo: 1)
        let claude = candidate(key: "claude:gen", percentUsed: 97, activeMinutesAgo: 1)
        XCTAssertEqual(select([spentCodex, claude], previousKey: "codex")?.key, "claude:gen")
    }

    func testExplicitPinStillShowsAnExhaustedQuota() {
        // Pinning is a deliberate choice: "show me Codex" must keep showing 0%.
        let spentCodex = candidate(key: "codex", percentUsed: 100, activeMinutesAgo: 1)
        let claude = candidate(key: "claude:gen", percentUsed: 48, activeMinutesAgo: 1)
        XCTAssertEqual(select([spentCodex, claude], pinnedKey: "codex")?.key, "codex")
    }

    // MARK: - Sticky selection (hysteresis)

    func testKeepsPreviousActiveAccountWithinHysteresis() {
        // codex is tighter by 4 points — inside the 5-point band, so no flip.
        let claude = candidate(key: "claude:ship", percentUsed: 60, activeMinutesAgo: 2)
        let codex = candidate(key: "codex", percentUsed: 64, activeMinutesAgo: 1)
        XCTAssertEqual(select([claude, codex], previousKey: "claude:ship")?.key, "claude:ship")
    }

    func testKeepsPreviousAtExactHysteresisBoundary() {
        let claude = candidate(key: "claude:ship", percentUsed: 60, activeMinutesAgo: 2)
        let codex = candidate(key: "codex", percentUsed: 65, activeMinutesAgo: 1)
        XCTAssertEqual(select([claude, codex], previousKey: "claude:ship")?.key, "claude:ship")
    }

    func testSwitchesWhenPreviousIsClearlyLooserThanTightestActive() {
        let claude = candidate(key: "claude:ship", percentUsed: 60, activeMinutesAgo: 2)
        let codex = candidate(key: "codex", percentUsed: 70, activeMinutesAgo: 1)
        XCTAssertEqual(select([claude, codex], previousKey: "claude:ship")?.key, "codex")
    }

    func testSwitchesAwayFromPreviousWhenItGoesIdle() {
        let claude = candidate(key: "claude:ship", percentUsed: 90, activeMinutesAgo: nil)
        let codex = candidate(key: "codex", percentUsed: 40, activeMinutesAgo: 1)
        XCTAssertEqual(select([claude, codex], previousKey: "claude:ship")?.key, "codex")
    }

    func testStickyAlsoAppliesToIdleFallbackPool() {
        // Nothing active: pool is "all", and the previously shown account stays
        // put while within the hysteresis band.
        let claude = candidate(key: "claude:ship", percentUsed: 60, activeMinutesAgo: nil)
        let codex = candidate(key: "codex", percentUsed: 63, activeMinutesAgo: nil)
        XCTAssertEqual(select([claude, codex], previousKey: "claude:ship")?.key, "claude:ship")
    }

    func testUnknownPreviousKeyFallsBackToTightest() {
        let claude = candidate(key: "claude:ship", percentUsed: 60, activeMinutesAgo: 2)
        let codex = candidate(key: "codex", percentUsed: 80, activeMinutesAgo: 1)
        XCTAssertEqual(select([claude, codex], previousKey: "cursor")?.key, "codex")
    }

    // MARK: - Determinism

    func testEqualPercentagesTieBreakByKeyForStableOutput() {
        let a = candidate(key: "claude:a", percentUsed: 50, activeMinutesAgo: 1)
        let b = candidate(key: "claude:b", percentUsed: 50, activeMinutesAgo: 1)
        XCTAssertEqual(select([b, a])?.key, "claude:a")
        XCTAssertEqual(select([a, b])?.key, "claude:a")
    }

    func testCodexAccountsCompeteIndependentlyByActivity() {
        let idle = candidate(key: "codex:personal", percentUsed: 95)
        let active = candidate(key: "codex:work", percentUsed: 45, activeMinutesAgo: 2)

        XCTAssertEqual(select([idle, active])?.key, "codex:work")
    }

    // MARK: - Pinned selection

    func testPinnedWindowWinsOverAutoHeuristic() {
        let automatic = candidate(key: "codex:work:session", percentUsed: 90, activeMinutesAgo: 1)
        let pinned = candidate(
            key: "claude:personal:weekly",
            percentUsed: 20,
            windowName: "Weekly",
            isAutoSelectable: false
        )

        XCTAssertEqual(
            select([automatic, pinned], pinnedKey: pinned.key)?.key,
            pinned.key
        )
    }

    func testPinnedAutoWindowMatchesPersistentPinKeyWithoutChangingLegacyAutoKey() {
        let claude = candidate(key: "claude:work", percentUsed: 90, activeMinutesAgo: 1)
        let codex = candidate(
            key: "codex:work",
            percentUsed: 20,
            activeMinutesAgo: 1,
            pinKey: "codexCli:account-id:session"
        )

        let selection = select([claude, codex], pinnedKey: "codexCli:account-id:session")

        XCTAssertEqual(selection?.key, "codex:work")
        XCTAssertEqual(selection?.pinKey, "codexCli:account-id:session")
    }

    func testUnavailablePinFallsBackToByteCompatibleAutoSelection() {
        let claude = candidate(key: "claude:work:session", percentUsed: 40, activeMinutesAgo: 2)
        let codex = candidate(key: "codex:work:session", percentUsed: 70, activeMinutesAgo: 1)

        XCTAssertEqual(
            select([claude, codex], pinnedKey: "cursor:default:weekly")?.key,
            "codex:work:session"
        )
    }

    func testPinOnlyWindowsDoNotChangeAutoSelection() {
        let session = candidate(key: "codex:work:session", percentUsed: 40, activeMinutesAgo: 1)
        let weekly = candidate(
            key: "codex:work:weekly",
            percentUsed: 95,
            activeMinutesAgo: 1,
            windowName: "Weekly",
            isAutoSelectable: false
        )

        XCTAssertEqual(select([session, weekly])?.key, session.key)
    }
}
