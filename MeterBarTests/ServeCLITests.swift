import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class ServeCLITests: XCTestCase {
    private func makeDataSource() -> ServeRouter.DataSource {
        ServeRouter.DataSource(loadUsageMetrics: { [:] }, loadCostCache: { nil })
    }

    func testRunNotifiesOnReadyWithTheBoundPortThenStopsWhenCancelled() async {
        final class CancelBox: @unchecked Sendable {
            private let lock = NSLock()
            private var cancelled = false
            var isCancelled: Bool { lock.withLock { cancelled } }
            func cancel() { lock.withLock { cancelled = true } }
        }

        let box = CancelBox()
        final class ReadyBox: @unchecked Sendable {
            private let lock = NSLock()
            private var info: ServeCLI.StartupInfo?
            var value: ServeCLI.StartupInfo? { lock.withLock { info } }
            func set(_ newValue: ServeCLI.StartupInfo) { lock.withLock { info = newValue } }
        }
        let readyBox = ReadyBox()

        let runTask = Task {
            await ServeCLI.run(
                ServeCLI.Request(
                    host: ServeBindConfiguration.loopbackHost,
                    port: 0,
                    token: "t",
                    maxRequestsPerSecond: 10
                ),
                dataSource: makeDataSource(),
                onReady: { readyBox.set($0) },
                shouldCancel: { box.isCancelled }
            )
        }

        // Give the server a moment to bind and invoke onReady, then stop it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        box.cancel()
        let outcome = await runTask.value

        XCTAssertEqual(outcome, .stopped)
        let info = try? XCTUnwrap(readyBox.value)
        XCTAssertEqual(info?.host, ServeBindConfiguration.loopbackHost)
        XCTAssertNotEqual(info?.port, 0, "an ephemeral bind should resolve to a real port")
    }

    func testRunReportsFailureWhenTheHostCannotBeResolved() async {
        let outcome = await ServeCLI.run(
            ServeCLI.Request(host: "not-an-ip-address", port: 0, token: "t", maxRequestsPerSecond: 10),
            dataSource: makeDataSource(),
            shouldCancel: { true }
        )

        guard case .failedToStart = outcome else {
            XCTFail("expected a failedToStart outcome, got \(outcome)")
            return
        }
    }
}
