import AppKit
@testable import MeterBar
import SwiftUI
import XCTest

/// Coverage for #98: state→label mapping, read-only preview while disabled, and
/// SwiftUI hosting for both the Settings pane and the menu-bar control.
@MainActor
final class SessionWakeStatusTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionWakeStatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLabelIsOffWhenToggleOff() {
        XCTAssertEqual(SessionWakeStatusLabel.from(state: .running(sessionID: "s"), isOn: false), .off)
    }

    func testRealStatesAreNotCollapsed() {
        XCTAssertEqual(SessionWakeStatusLabel.from(state: .running(sessionID: "s"), isOn: true), .running)
        XCTAssertEqual(SessionWakeStatusLabel.from(state: .stopping, isOn: true), .stopping)
        XCTAssertEqual(SessionWakeStatusLabel.from(state: .quotaUnknown(reason: "x"), isOn: true), .quotaUnknown)
        XCTAssertEqual(SessionWakeStatusLabel.from(state: .failed(reason: "x"), isOn: true), .needsAttention)
        XCTAssertTrue(SessionWakeStatusLabel.needsAttention.isAttention)
    }

    func testCompletionSummaryMatchesRunnerOutcome() {
        let status = SessionWakeStatus()
        status.update(state: .completed(summary: WakeRunSummary(resumed: 3, failed: 1, skipped: 2, remaining: 0)))
        XCTAssertEqual(status.lastSummary?.resumed, 3)
        XCTAssertEqual(status.lastSummary?.failed, 1)
    }

    func testPreviewWorksWhileFeatureDisabled() async throws {
        // Write a blocked transcript with an existing cwd ⇒ one eligible session.
        let projects = tempDir.appendingPathComponent("projects").appendingPathComponent("-proj")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-07-10T02:00:00.000Z",
            "isApiErrorMessage": true,
            "apiErrorStatus": 429,
            "cwd": tempDir.path,
            "sessionId": "s0",
            "message": ["role": "assistant", "content": [["type": "text", "text": "session limit resets 3:00am (UTC)"]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try String(decoding: data, as: UTF8.self)
            .write(to: projects.appendingPathComponent("s0.jsonl"), atomically: true, encoding: .utf8)

        let ledgerURL = tempDir.appendingPathComponent("l.json")
        let status = SessionWakeStatus(ledgerFactory: { ReplayLedger(fileURL: ledgerURL) })
        await status.preview(configDirectory: tempDir.path)
        XCTAssertEqual(status.eligibleCount, 1)
        XCTAssertFalse(status.isPreviewing)
    }

    // MARK: - SwiftUI hosting

    func testSettingsPaneHosts() {
        let defaults = UserDefaults(suiteName: "hosting-\(UUID().uuidString)")!
        let store = SessionWakeSettingsStore(userDefaults: defaults)
        store.setWakeAccountID(UUID())
        store.acknowledgeFirstRunAndTurnOn()
        let view = SessionWakeSettingsView(store: store, status: SessionWakeStatus(), accounts: ClaudeCodeAccountStore(userDefaults: defaults))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 100)
    }

    func testSettingsPaneHostsEmbeddedInDashboard() {
        // The dashboard embeds the settings inside its own ScrollView, so the
        // embedded variant must render without the grouped Form's nested scroll.
        let defaults = UserDefaults(suiteName: "hosting-\(UUID().uuidString)")!
        let store = SessionWakeSettingsStore(userDefaults: defaults)
        store.setWakeAccountID(UUID())
        store.acknowledgeFirstRunAndTurnOn()
        let view = SessionWakeSettingsView(
            embeddedInDashboard: true,
            store: store,
            status: SessionWakeStatus(),
            accounts: ClaudeCodeAccountStore(userDefaults: defaults)
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 100)
    }

    func testMenuControlVisibility() {
        // On ⇒ shown (kill switch must stay reachable), even mid-run.
        XCTAssertTrue(SessionWakeMenuControl.shouldShow(isOn: true, canTurnOn: false))
        // Off but armable (account configured) ⇒ shown for quick access.
        XCTAssertTrue(SessionWakeMenuControl.shouldShow(isOn: false, canTurnOn: true))
        // Off and unconfigured ⇒ hidden, no inert row.
        XCTAssertFalse(SessionWakeMenuControl.shouldShow(isOn: false, canTurnOn: false))
    }

    func testMenuControlHosts() {
        let defaults = UserDefaults(suiteName: "hosting-\(UUID().uuidString)")!
        let view = SessionWakeMenuControl(
            store: SessionWakeSettingsStore(userDefaults: defaults),
            status: SessionWakeStatus()
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}
