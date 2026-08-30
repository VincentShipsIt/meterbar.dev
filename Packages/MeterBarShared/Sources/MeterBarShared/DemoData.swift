import Foundation

/// Deterministic, synthetic usage fixture for demo / sample-data mode.
///
/// Demo mode (`METERBAR_DEMO=1` or the hidden prefs toggle — see the app's
/// `DemoMode`) publishes this fixture instead of the signed-in owner's real
/// account data, so the landing-page screenshots and the first-run onboarding
/// preview both render a populated, on-message MeterBar without exposing real
/// costs, private project names, or an all-red "everything is on fire" state.
///
/// Design rules the fixture upholds (each is asserted by `DemoDataTests`):
///  - **Generic labels only.** The map is keyed by `ServiceType`, whose display
///    names ("Claude Code", "OpenAI Codex", "Cursor", "OpenRouter", "Grok")
///    are product names, never the owner's custom account/profile names. The
///    app's demo wiring pairs this with default-only account stores so
///    provider cards title as "Claude" / "Codex" / "Cursor" / "OpenRouter" /
///    "Grok" regardless of the real accounts on the machine.
///  - **Mostly comfortable green.** Every quota window sits at ≤75% used
///    (`QuotaBand.healthy`) except exactly one.
///  - **Exactly one "tight" amber band.** Codex's weekly window sits at 82%
///    used (`QuotaBand.tight`, the 76–90% band) so screenshots show the amber
///    state without any `.critical`/`.exhausted` red.
///  - **Healthy trajectory.** Reset timers are chosen so every window's pace
///    reads "reserve" or "on pace", never "deficit"/"Out" — including the tight
///    Codex weekly window (tight by level, comfortably on track by trajectory).
///  - **Fresh.** `lastUpdated == now`, so all surfaces treat the data as
///    healthy (inside the widget planner's 2h staleness threshold).
///
/// The fixture is a pure function of `now`: the same clock always yields the
/// same numbers, which keeps snapshot tests and rendered screenshots stable.
public enum DemoData {
    /// Session (5h) and weekly (7d) windows mirror the real provider windows so
    /// the pace math and reset copy read the same as production.
    private static let sessionWindowSeconds: TimeInterval = 5 * 3_600
    private static let weeklyWindowSeconds: TimeInterval = 7 * 24 * 3_600
    private static let modelWindowSeconds: TimeInterval = 5 * 3_600

    /// Synthetic provider metrics for demo mode, keyed by service.
    ///
    /// Covers every `ServiceType` so demo / regression surfaces can exercise
    /// Grok and OpenRouter without credentials. Adding a provider is a fixture
    /// gap the capability parity tests fail on.
    public static func metrics(now: Date = Date()) -> [ServiceType: UsageMetrics] {
        [
            .claudeCode: claudeCode(now: now),
            .codexCli: codexCli(now: now),
            .cursor: cursor(now: now),
            .openRouter: openRouter(now: now),
            .grok: grok(now: now)
        ]
    }

    // MARK: - Providers

    /// Claude Code: all three windows comfortably green. Extra usage is on
    /// with nothing spent, matching the production extra-usage surface.
    private static func claudeCode(now: Date) -> UsageMetrics {
        UsageMetrics(
            service: .claudeCode,
            sessionLimit: sessionLimit(usedPercent: 42, now: now),
            weeklyLimit: weeklyLimit(usedPercent: 58, now: now),
            codeReviewLimit: modelLimit(usedPercent: 34, now: now),
            modelLimitLabel: "Fable",
            extraUsage: ExtraUsageStatus(state: .on, detail: "$0.00 used"),
            lastUpdated: now
        )
    }

    /// Codex CLI: session + code-review green; weekly is the single amber
    /// "tight" band (82% used). Two banked reset credits available.
    private static func codexCli(now: Date) -> UsageMetrics {
        UsageMetrics(
            service: .codexCli,
            sessionLimit: sessionLimit(usedPercent: 61, now: now),
            weeklyLimit: weeklyLimit(usedPercent: 82, now: now),
            codeReviewLimit: modelLimit(usedPercent: 12, now: now),
            resetCreditsAvailable: 2,
            lastUpdated: now
        )
    }

    /// Cursor: two included percent pools plus the weekly Grok Bot bar,
    /// all green. The included pools have no window seconds (matching the
    /// real usage-summary mapping). Grok Bot carries a ~7-day window.
    private static func cursor(now: Date) -> UsageMetrics {
        let reset = now.addingTimeInterval(28 * 24 * 3_600)
        return UsageMetrics(
            service: .cursor,
            sessionLimit: UsageLimit(
                used: 18,
                total: ServiceType.cursorIncludedPoolTotal,
                resetTime: reset,
                periodKind: .monthly
            ),
            weeklyLimit: UsageLimit(
                used: 42,
                total: ServiceType.cursorIncludedPoolTotal,
                resetTime: reset,
                periodKind: .monthly
            ),
            additionalLimits: [
                UsageLimit(
                    used: 22,
                    total: ServiceType.cursorIncludedPoolTotal,
                    resetTime: now.addingTimeInterval(5 * 24 * 3_600),
                    windowSeconds: weeklyWindowSeconds,
                    periodKind: .weekly
                )
            ],
            lastUpdated: now
        )
    }

    /// OpenRouter: key-limit + account-credits windows matching production
    /// mapping (`sessionLimit` = key spend cap, `weeklyLimit` = credit
    /// balance). Dollar amounts stay comfortably green.
    private static func openRouter(now: Date) -> UsageMetrics {
        UsageMetrics(
            service: .openRouter,
            sessionLimit: UsageLimit(
                used: 12.80,
                total: 40,
                resetTime: now.addingTimeInterval(18 * 24 * 3_600),
                windowSeconds: 30 * 24 * 3_600
            ),
            weeklyLimit: UsageLimit(
                used: 42,
                total: 100,
                resetTime: nil
            ),
            lastUpdated: now
        )
    }

    /// Grok: a weekly-style window plus extra usage and a banked reset.
    /// Production often has no session period — do not invent one.
    private static func grok(now: Date) -> UsageMetrics {
        UsageMetrics(
            service: .grok,
            weeklyLimit: weeklyLimit(usedPercent: 47, now: now),
            extraUsage: ExtraUsageStatus(state: .on, detail: "$10.00 credits"),
            resetCreditsAvailable: 1,
            lastUpdated: now
        )
    }

    // MARK: - Window builders

    /// A 5h session window resetting in 2h (60% elapsed): a used% below ~58
    /// reads "reserve", ~59–61 reads "on pace".
    private static func sessionLimit(usedPercent: Double, now: Date) -> UsageLimit {
        UsageLimit(
            used: usedPercent,
            total: 100,
            resetTime: now.addingTimeInterval(2 * 3_600),
            windowSeconds: sessionWindowSeconds
        )
    }

    /// A 7d weekly window resetting in ~1 day (≈86% elapsed): even the 82%
    /// "tight" band stays in reserve on trajectory, never a deficit.
    private static func weeklyLimit(usedPercent: Double, now: Date) -> UsageLimit {
        UsageLimit(
            used: usedPercent,
            total: 100,
            resetTime: now.addingTimeInterval(24 * 3_600),
            windowSeconds: weeklyWindowSeconds
        )
    }

    /// The model-scoped third window (Claude "Fable", Codex code review),
    /// resetting in 2.5h (50% elapsed).
    private static func modelLimit(usedPercent: Double, now: Date) -> UsageLimit {
        UsageLimit(
            used: usedPercent,
            total: 100,
            resetTime: now.addingTimeInterval(2 * 3_600 + 1_800),
            windowSeconds: modelWindowSeconds
        )
    }
}
