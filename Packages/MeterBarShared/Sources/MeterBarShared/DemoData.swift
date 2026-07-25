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
///    names ("Claude Code", "OpenAI Codex", "Cursor") are product names, never
///    the owner's custom account/profile names. The app's demo wiring pairs this
///    with default-only account stores so provider cards title as "Claude" /
///    "Codex" / "Cursor" regardless of the real accounts on the machine.
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
    /// Covers three providers — Claude Code, Codex CLI, Cursor — which is enough
    /// to populate the Overview window, the menu-bar panel, and the medium
    /// widget while staying visually uncluttered.
    public static func metrics(now: Date = Date()) -> [ServiceType: UsageMetrics] {
        [
            .claudeCode: claudeCode(now: now),
            .codexCli: codexCli(now: now),
            .cursor: cursor(now: now)
        ]
    }

    // MARK: - Providers

    /// Claude Code: all three windows comfortably green.
    private static func claudeCode(now: Date) -> UsageMetrics {
        UsageMetrics(
            service: .claudeCode,
            sessionLimit: sessionLimit(usedPercent: 42, now: now),
            weeklyLimit: weeklyLimit(usedPercent: 58, now: now),
            codeReviewLimit: modelLimit(usedPercent: 34, now: now),
            modelLimitLabel: "Fable",
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

    /// Cursor: dollar-denominated plan + on-demand balances, both green. No
    /// window seconds (matching the real Cursor mapping), so no pace label.
    private static func cursor(now: Date) -> UsageMetrics {
        UsageMetrics(
            service: .cursor,
            sessionLimit: UsageLimit(used: 2, total: 20, resetTime: nil),
            weeklyLimit: UsageLimit(used: 205, total: 500, resetTime: nil),
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
