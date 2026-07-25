@testable import MeterBar
import XCTest

final class SessionWakeAgentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "SessionWakeAgentTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testConfigurationRoundTripsAndClampsBounds() throws {
        let store = SessionWakeAgentStateStore(userDefaults: defaults)
        let configuration = SessionWakeAgentConfiguration(
            featureEnabled: true,
            isArmed: true,
            provider: .claude,
            accountDirectory: "/tmp/claude-profile",
            permissionMode: .safe,
            bypassAcknowledged: false,
            prompt: "continue",
            notifyOnCompletion: true,
            maxSessionsPerRun: 9_999,
            maxTurns: 0,
            eventHooks: WakeEventHookConfiguration(
                executablePath: "/usr/bin/true",
                arguments: ["literal value"],
                enabledEvents: [.wakeComplete]
            )
        )

        store.saveConfiguration(configuration)

        let restored = try XCTUnwrap(store.loadConfiguration())
        XCTAssertEqual(restored, configuration)
        XCTAssertTrue(restored.canRun)
        XCTAssertEqual(restored.bounds.maxSessionsPerRun, WakeBounds.sessionsRange.upperBound)
        XCTAssertEqual(restored.bounds.maxTurns, WakeBounds.maxTurnsRange.lowerBound)
        XCTAssertTrue(restored.eventHooks.isEnabled(for: .wakeComplete))
    }

    func testBypassWithoutAcknowledgementFailsClosed() {
        let configuration = SessionWakeAgentConfiguration(
            featureEnabled: true,
            isArmed: true,
            provider: .claude,
            accountDirectory: nil,
            permissionMode: .bypass,
            bypassAcknowledged: false,
            prompt: "continue",
            notifyOnCompletion: true,
            maxSessionsPerRun: 5,
            maxTurns: 40
        )

        XCTAssertFalse(configuration.canRun)
    }

    func testLegacyConfigurationDecodesWithHooksDisabled() throws {
        let legacy: [String: Any] = [
            "featureEnabled": true,
            "isArmed": true,
            "provider": WakeProvider.claude.rawValue,
            "permissionMode": WakePermissionMode.safe.rawValue,
            "bypassAcknowledged": false,
            "prompt": "continue",
            "notifyOnCompletion": true,
            "maxSessionsPerRun": 5,
            "maxTurns": 40
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: SessionWakeAgentStateStore.configurationKey
        )

        let restored = try XCTUnwrap(SessionWakeAgentStateStore(userDefaults: defaults).loadConfiguration())

        XCTAssertEqual(restored.eventHooks, .disabled)
        XCTAssertTrue(restored.canRun)
    }

    func testDisarmSynchronouslyUpdatesRunningAgentConfiguration() throws {
        let agentState = SessionWakeAgentStateStore(userDefaults: defaults)
        agentState.saveConfiguration(
            SessionWakeAgentConfiguration(
                featureEnabled: true,
                isArmed: true,
                provider: .claude,
                accountDirectory: nil,
                permissionMode: .safe,
                bypassAcknowledged: false,
                prompt: "continue",
                notifyOnCompletion: true,
                maxSessionsPerRun: 5,
                maxTurns: 40
            )
        )
        let settings = SessionWakeSettingsStore(userDefaults: defaults, agentStateStore: agentState)
        settings.setWakeAccountID(UUID())
        settings.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(settings.isOn)

        settings.setOn(false)

        XCTAssertFalse(try XCTUnwrap(agentState.loadConfiguration()).isArmed)
    }

    func testExecutionChangesRestartButNotificationAndHookChangesDoNot() {
        let baseline = SessionWakeAgentConfiguration(
            featureEnabled: true,
            isArmed: true,
            provider: .claude,
            accountDirectory: nil,
            permissionMode: .safe,
            bypassAcknowledged: false,
            prompt: "continue",
            notifyOnCompletion: true,
            maxSessionsPerRun: 5,
            maxTurns: 40
        )
        let notificationOnly = SessionWakeAgentConfiguration(
            featureEnabled: true,
            isArmed: true,
            provider: .claude,
            accountDirectory: nil,
            permissionMode: .safe,
            bypassAcknowledged: false,
            prompt: "continue",
            notifyOnCompletion: false,
            maxSessionsPerRun: 5,
            maxTurns: 40
        )
        let saferPermission = SessionWakeAgentConfiguration(
            featureEnabled: true,
            isArmed: true,
            provider: .claude,
            accountDirectory: nil,
            permissionMode: .safe,
            bypassAcknowledged: false,
            prompt: "continue safely",
            notifyOnCompletion: true,
            maxSessionsPerRun: 5,
            maxTurns: 40
        )
        let hookChange = SessionWakeAgentConfiguration(
            featureEnabled: true,
            isArmed: true,
            provider: .claude,
            accountDirectory: nil,
            permissionMode: .safe,
            bypassAcknowledged: false,
            prompt: "continue",
            notifyOnCompletion: true,
            maxSessionsPerRun: 5,
            maxTurns: 40,
            eventHooks: .init(
                executablePath: "/usr/bin/true",
                arguments: [],
                enabledEvents: [.quotaReset]
            )
        )

        XCTAssertFalse(notificationOnly.requiresRuntimeRestart(comparedTo: baseline))
        XCTAssertTrue(saferPermission.requiresRuntimeRestart(comparedTo: baseline))
        XCTAssertFalse(hookChange.requiresRuntimeRestart(comparedTo: baseline))
    }

    func testStatusRoundTripsEveryAssociatedValue() throws {
        let store = SessionWakeAgentStateStore(userDefaults: defaults)
        let summary = WakeRunSummary(resumed: 2, failed: 1, skipped: 3, remaining: 4)
        let states: [WakeWatcherState] = [
            .off,
            .idle,
            .scanning,
            .waiting(until: Date(timeIntervalSince1970: 123)),
            .quotaUnknown(reason: "missing token"),
            .running(sessionID: "session-1"),
            .stopping,
            .completed(summary: summary),
            .failed(reason: "boom")
        ]

        for state in states {
            store.saveStatus(.init(state: state, processID: 42, heartbeat: Date(timeIntervalSince1970: 456)))
            let restored = try XCTUnwrap(store.loadStatus())
            XCTAssertEqual(restored.watcherState, state)
            XCTAssertEqual(restored.processID, 42)
        }
    }

    func testAgentLifetimeLockExcludesAppAndCLIHolders() {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionWakeAgentLock-\(UUID().uuidString)")
        let agent = WakeLock(lockURL: lockURL, legacyLockURLs: [], holderKind: .agent)
        let cli = WakeLock(lockURL: lockURL, legacyLockURLs: [], holderKind: .cli)

        XCTAssertEqual(agent.acquire(), .acquired)
        guard case let .contended(holder) = cli.acquire() else {
            agent.release()
            return XCTFail("CLI must contend while the managed watcher owns the lifetime lock")
        }
        XCTAssertEqual(holder?.kind, .agent)

        agent.release()
        XCTAssertEqual(cli.acquire(), .acquired)
        cli.release()
    }

    // MARK: - Completion notification

    func testCompletionNotificationBodyReportsEveryNonZeroBucket() {
        let summary = WakeRunSummary(resumed: 2, failed: 1, skipped: 0, remaining: 3)
        let body = SessionWakeAgent.completionNotificationBody(summary: summary, provider: .claude)

        XCTAssertTrue(body.hasPrefix("Resumed 2 of 3 "))
        XCTAssertTrue(body.contains("1 failed."))
        XCTAssertTrue(body.contains("3 still queued."))
    }

    func testCompletionNotificationBodyOmitsEmptyBuckets() {
        let summary = WakeRunSummary(resumed: 1, failed: 0, skipped: 0, remaining: 0)
        let body = SessionWakeAgent.completionNotificationBody(summary: summary, provider: .claude)

        XCTAssertFalse(body.contains("failed."))
        XCTAssertFalse(body.contains("still queued."))
    }

    func testNotificationArgumentsPassTextAsArgvNotScriptSource() {
        let arguments = SessionWakeAgent.notificationArguments(body: "plain body", title: "plain title")

        // `-e <script> <arg1> <arg2>`: the two runtime values are trailing argv,
        // read by the handler via `item n of argv`.
        XCTAssertEqual(arguments.first, "-e")
        XCTAssertEqual(arguments.count, 4)
        XCTAssertEqual(arguments[2], "plain body")
        XCTAssertEqual(arguments[3], "plain title")
    }

    func testNotificationScriptSourceIsConstantAcrossInputs() {
        let benign = SessionWakeAgent.notificationArguments(body: "ok", title: "title")
        let hostile = SessionWakeAgent.notificationArguments(
            body: #"" & (do shell script "touch /tmp/pwned") & ""#,
            title: #"back\slash and "quotes""#
        )

        // The whole point of the argv form: nothing a caller supplies can reach
        // the compiled script text, so there is no escaping to get wrong.
        XCTAssertEqual(benign[1], hostile[1])
    }

    func testNotificationArgumentsDoNotEscapeTheirInputs() {
        let hostileBody = #"" & (do shell script "touch /tmp/pwned") & ""#
        let arguments = SessionWakeAgent.notificationArguments(body: hostileBody, title: "t")

        // Passed through verbatim — osascript hands argv to the handler as data,
        // so escaping would corrupt the displayed text rather than protect it.
        XCTAssertEqual(arguments[2], hostileBody)
    }
}
