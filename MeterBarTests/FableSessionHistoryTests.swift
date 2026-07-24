import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

@MainActor
final class FableSessionHistoryTests: XCTestCase {
    private let accountA = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let accountB = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testModelGroupsLifecycleStatesAcrossProfilesAndSummarizesDiagnostics() {
        let diagnostics = [
            accountA: ClaudeFableProfileDiagnostic(
                accountID: accountA,
                status: .scanned,
                scannedTranscriptCount: 2,
                malformedLineCount: 3
            ),
            accountB: ClaudeFableProfileDiagnostic(
                accountID: accountB,
                status: .unavailable,
                scannedTranscriptCount: 0,
                malformedLineCount: 0
            ),
        ]

        let model = FableSessionHistoryModel(
            sessions: [
                session("active", accountID: accountA, accountName: "Ship", state: .active, offset: 0),
                session("complete", accountID: accountB, accountName: "Gen", state: .completed, offset: -60),
                session("unknown", accountID: accountA, accountName: "Ship", state: .unknown, offset: -120),
            ],
            diagnostics: diagnostics
        )

        XCTAssertEqual(model.active.map(\.sourceSessionID), ["active"])
        XCTAssertEqual(model.recent.map(\.sourceSessionID), ["complete", "unknown"])
        XCTAssertEqual(Set((model.active + model.recent).map(\.accountName)), ["Ship", "Gen"])
        XCTAssertEqual(model.unavailableProfileCount, 1)
        XCTAssertEqual(model.malformedLineCount, 3)
    }

    func testModelDeduplicatesRepeatedObservationUsingLatestLifecycle() {
        let first = session("same", accountID: accountA, accountName: "Ship", state: .active, offset: -60)
        let latest = session("same", accountID: accountA, accountName: "Ship", state: .completed, offset: 0)

        let model = FableSessionHistoryModel(sessions: [first, latest], diagnostics: [:])

        XCTAssertTrue(model.active.isEmpty)
        XCTAssertEqual(model.recent.count, 1)
        XCTAssertEqual(model.recent.first?.state, .completed)
    }

    func testModelDemotesStaleActiveSessionWithoutWaitingForAnotherScan() {
        let stale = session(
            "stale",
            accountID: accountA,
            accountName: "Ship",
            state: .active,
            offset: -ClaudeFableSessionPolicy.activeWindow - 1
        )

        let model = FableSessionHistoryModel(
            sessions: [stale],
            diagnostics: [:],
            now: now
        )

        XCTAssertTrue(model.active.isEmpty)
        XCTAssertEqual(model.recent.first?.state, .unknown)
    }

    func testCardActivityIsAccountAttributedAndPrefersFreshActiveSession() {
        let activity = FableSessionCardActivity.make(
            accountID: accountA,
            sessions: [
                session("other-account", accountID: accountB, accountName: "Gen", state: .active, offset: 0),
                session("recent", accountID: accountA, accountName: "Ship", state: .completed, offset: -30),
                session("active", accountID: accountA, accountName: "Ship", state: .active, offset: -60),
            ],
            now: now
        )

        XCTAssertEqual(activity.session?.sourceSessionID, "active")
        XCTAssertEqual(activity.status(now: now), .active)
    }

    func testCardActivityReportsRecentAndNoActivityHonestly() {
        let recent = FableSessionCardActivity.make(
            accountID: accountA,
            sessions: [
                session("completed", accountID: accountA, accountName: "Ship", state: .completed, offset: -60)
            ],
            now: now
        )
        let none = FableSessionCardActivity.make(accountID: accountB, sessions: [], now: now)

        XCTAssertEqual(recent.status(now: now), .recent)
        XCTAssertEqual(none.status(now: now), .noActivity)
    }

    func testCardActivityDemotesStaleActiveSessionOnTimelineTick() {
        let activity = FableSessionCardActivity.make(
            accountID: accountA,
            sessions: [
                session("active", accountID: accountA, accountName: "Ship", state: .active, offset: 0)
            ],
            now: now
        )

        XCTAssertEqual(
            activity.status(now: now.addingTimeInterval(ClaudeFableSessionPolicy.activeWindow + 1)),
            .recent
        )
    }

    func testHumanOutputCoversEmptyAndPopulatedSnapshots() {
        XCTAssertEqual(
            FableSessionsTextFormatter.format([]),
            """
            No Fable 5 sessions found.
            Open MeterBar and refresh Claude Code after running a Fable 5 session.
            """
        )

        let active = session("active", accountID: accountA, accountName: "Ship", state: .active, offset: 0)
        let completed = session(
            "completed",
            accountID: accountB,
            accountName: "Gen",
            state: .completed,
            offset: -60
        )
        let output = FableSessionsTextFormatter.format([completed, active, active])

        XCTAssertTrue(output.contains("1 active · 1 recent"))
        XCTAssertTrue(output.contains("Ship · claude-fable-5 · active"))
        XCTAssertTrue(output.contains("Gen · claude-fable-5 · completed"))
    }

    func testPopulatedAndEmptyHistoryRender() {
        let populated = FableSessionHistoryView(
            sessions: [
                session("active", accountID: accountA, accountName: "Ship", state: .active, offset: 0),
                session("unknown", accountID: accountB, accountName: "Gen", state: .unknown, offset: -60),
            ],
            diagnostics: [
                accountB: ClaudeFableProfileDiagnostic(
                    accountID: accountB,
                    status: .unavailable,
                    scannedTranscriptCount: 0,
                    malformedLineCount: 1
                ),
            ]
        )
        assertRenders(populated)
        assertRenders(FableSessionHistoryView(sessions: []))
    }

    func testSharedProviderCardRendersFableActivitySummary() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 16, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 71, total: 100, resetTime: nil)
        )
        let activity = FableSessionCardActivity.make(
            accountID: accountA,
            sessions: [
                session("active", accountID: accountA, accountName: "Ship", state: .active, offset: 0)
            ],
            now: now
        )
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Ship",
            service: .claudeCode,
            metrics: metrics,
            emptyDetail: "",
            accountID: accountA,
            fableActivity: activity
        )
        let host = NSHostingView(rootView: ProviderStatusCard(snapshot: snapshot).frame(width: 360))

        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    private func session(
        _ sourceSessionID: String,
        accountID: UUID,
        accountName: String,
        state: ClaudeFableSession.State,
        offset: TimeInterval
    ) -> ClaudeFableSession {
        ClaudeFableSession(
            sourceSessionID: sourceSessionID,
            accountID: accountID,
            accountName: accountName,
            model: "claude-fable-5",
            firstObservedAt: now.addingTimeInterval(offset - 120),
            lastObservedAt: now.addingTimeInterval(offset),
            state: state
        )
    }

    private func assertRenders(_ view: FableSessionHistoryView) {
        let host = NSHostingView(rootView: view.frame(width: 720))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
