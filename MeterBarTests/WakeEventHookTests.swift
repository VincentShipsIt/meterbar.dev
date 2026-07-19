import Foundation
import XCTest
@testable import MeterBar

final class WakeEventHookTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        suiteName = "WakeEventHookTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WakeEventHookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeRunner(
        timeout: TimeInterval = 10,
        maxCaptureBytes: Int = 16 * 1024
    ) -> WakeEventHookRunner {
        WakeEventHookRunner(
            timeout: timeout,
            maxCaptureBytes: maxCaptureBytes,
            logger: WakeRunLogger(directory: tempDirectory.appendingPathComponent("logs", isDirectory: true))
        )
    }

    func testHooksDefaultOffAndRequireAConfiguredCommand() {
        let store = SessionWakeSettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.eventHookConfiguration, .disabled)
        store.setHookEnabled(true, for: .quotaExhausted)
        XCTAssertFalse(store.eventHookConfiguration.enabledEvents.contains(.quotaExhausted))

        store.setHookExecutablePath("/usr/bin/true")
        store.setHookEnabled(true, for: .quotaExhausted)
        XCTAssertTrue(store.eventHookConfiguration.enabledEvents.contains(.quotaExhausted))

        store.setHookExecutablePath("")
        XCTAssertTrue(store.eventHookConfiguration.enabledEvents.isEmpty)
    }

    func testCommandArgumentsAndEventOptInsPersistExactly() {
        let store = SessionWakeSettingsStore(userDefaults: defaults)
        store.setHookExecutablePath("/usr/bin/printf")
        store.addHookArgument()
        store.setHookArgument("value with spaces", at: 0)
        store.addHookArgument()
        store.setHookArgument("$(not-expanded)", at: 1)
        store.setHookEnabled(true, for: .quotaReset)
        store.setHookEnabled(true, for: .wakeComplete)

        let reloaded = SessionWakeSettingsStore(userDefaults: defaults)

        XCTAssertEqual(reloaded.eventHookConfiguration.executablePath, "/usr/bin/printf")
        XCTAssertEqual(reloaded.eventHookConfiguration.arguments, ["value with spaces", "$(not-expanded)"])
        XCTAssertEqual(reloaded.eventHookConfiguration.enabledEvents, [.quotaReset, .wakeComplete])
    }

    func testTransitionTrackerDeduplicatesRetriesAndDetectsReset() {
        var tracker = WakeEventHookTransitionTracker()

        XCTAssertEqual(tracker.event(for: .waiting(until: nil)), .quotaExhausted)
        XCTAssertNil(tracker.event(for: .waiting(until: nil)))
        XCTAssertNil(tracker.event(for: .off))
        XCTAssertNil(tracker.event(for: .waiting(until: nil)))
        XCTAssertNil(tracker.event(for: .quotaUnknown(reason: "retry")))
        XCTAssertNil(tracker.event(for: .scanning))
        XCTAssertNil(tracker.event(for: .waiting(until: Date())))
        XCTAssertEqual(tracker.event(for: .running(sessionID: "session-1")), .quotaReset)
        XCTAssertNil(tracker.event(for: .running(sessionID: "session-2")))
    }

    func testWakeCompleteRequiresMeaningfulWorkAndFiresOncePerTransition() {
        var tracker = WakeEventHookTransitionTracker()
        let empty = WakeRunSummary()
        let resumed = WakeRunSummary(resumed: 1)

        XCTAssertNil(tracker.event(for: .completed(summary: empty)))
        XCTAssertNil(tracker.event(for: .completed(summary: resumed)))
        XCTAssertNil(tracker.event(for: .scanning))
        XCTAssertEqual(tracker.event(for: .completed(summary: resumed)), .wakeComplete)
        XCTAssertNil(tracker.event(for: .completed(summary: resumed)))
    }

    func testRunnerPreservesLiteralArgvWithoutShellExpansion() async throws {
        let sentinel = tempDirectory.appendingPathComponent("must-not-exist")
        let literal = "$(touch \(sentinel.path))"
        let configuration = WakeEventHookConfiguration(
            executablePath: "/usr/bin/printf",
            arguments: ["<%s>\\n", "value with spaces", literal, "; echo injected"],
            enabledEvents: []
        )

        let result = await makeRunner().run(configuration: configuration, context: .test)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            try XCTUnwrap(String(bytes: result.stdoutCapture, encoding: .utf8)),
            "<value with spaces>\n<\(literal)>\n<; echo injected>\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testRunnerBoundsCapturedOutput() async {
        let configuration = WakeEventHookConfiguration(
            executablePath: "/usr/bin/printf",
            arguments: ["%s", String(repeating: "x", count: 2_048)],
            enabledEvents: []
        )

        let result = await makeRunner(maxCaptureBytes: 32)
            .run(configuration: configuration, context: .test)

        XCTAssertEqual(result.stdoutByteCount, 2_048)
        XCTAssertEqual(result.stdoutCapture.count, 32)
    }

    func testTimeoutNonzeroMissingAndPermissionFailuresReturnWithoutThrowing() async throws {
        let timeout = await makeRunner(timeout: 0.05).run(
            configuration: .init(executablePath: "/bin/sleep", arguments: ["5"], enabledEvents: []),
            context: .test
        )
        XCTAssertEqual(timeout.termination, .timedOut)

        let nonzero = await makeRunner().run(
            configuration: .init(executablePath: "/usr/bin/false", arguments: [], enabledEvents: []),
            context: .test
        )
        XCTAssertEqual(nonzero.termination, .exited(1))

        let missing = await makeRunner().run(
            configuration: .init(
                executablePath: tempDirectory.appendingPathComponent("missing").path,
                arguments: [],
                enabledEvents: []
            ),
            context: .test
        )
        guard case .launchFailed = missing.termination else {
            return XCTFail("Missing executable should be a launch failure")
        }

        let nonExecutable = tempDirectory.appendingPathComponent("not-executable")
        try Data("hook".utf8).write(to: nonExecutable)
        let denied = await makeRunner().run(
            configuration: .init(executablePath: nonExecutable.path, arguments: [], enabledEvents: []),
            context: .test
        )
        guard case .launchFailed = denied.termination else {
            return XCTFail("Non-executable file should be a launch failure")
        }
    }
}
