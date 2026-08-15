import Darwin
import Dispatch
import Foundation
import XCTest
@testable import MeterBar

/// The cancellation flag and signal wiring shared by `serve`, `guard`,
/// `refresh`, `wake`, and `wake-agent`. Each command used to carry its own
/// copy; the copies drifted, and none of them was ever covered by a test.
final class CLICancellationTests: XCTestCase {
    func testTheFlagStartsClear() {
        XCTAssertFalse(CLICancellationFlag().isCancelled)
    }

    func testCancelIsVisibleToASubsequentRead() {
        let flag = CLICancellationFlag()
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
    }

    func testCancelIsIdempotent() {
        let flag = CLICancellationFlag()
        flag.cancel()
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
    }

    /// The real access pattern: a signal handler on a global queue writes while
    /// the command's engine polls from somewhere else. Concurrent readers must
    /// see a consistent value and the writes must not race.
    func testConcurrentCancelsAndReadsAreSafe() {
        let flag = CLICancellationFlag()

        DispatchQueue.concurrentPerform(iterations: 256) { iteration in
            if iteration.isMultiple(of: 4) {
                flag.cancel()
            } else {
                _ = flag.isCancelled
            }
        }

        XCTAssertTrue(flag.isCancelled)
    }

    /// Every reader observes the cancel once it has happened — the point of the
    /// lock, since `shouldCancel` closures are called from threads that never
    /// touched the flag before.
    func testACancelOnOneThreadIsObservedOnAnother() {
        let flag = CLICancellationFlag()
        let observed = expectation(description: "cancel observed off-thread")

        DispatchQueue.global().async {
            flag.cancel()
            DispatchQueue.global().async {
                if flag.isCancelled { observed.fulfill() }
            }
        }

        wait(for: [observed], timeout: 5)
    }

    func testInstallReturnsOneLiveSourcePerSignal() {
        let flag = CLICancellationFlag()
        let sources = CLISignalHandlers.install([SIGUSR1, SIGUSR2], cancelling: flag)
        defer { sources.forEach { $0.cancel() } }

        XCTAssertEqual(sources.count, 2)
        XCTAssertFalse(sources.contains { $0.isCancelled })
        XCTAssertFalse(flag.isCancelled, "Installing a handler must not cancel anything by itself.")
    }

    func testTheDefaultSignalListIsInterruptAndTerminate() {
        XCTAssertEqual(CLISignalHandlers.interruptAndTerminate, [SIGINT, SIGTERM])
    }

    /// The wiring itself: delivering the signal must flip the flag rather than
    /// kill the process, which is what `signal(_:SIG_IGN)` inside `install` buys.
    ///
    /// Sent to SIGUSR2, not SIGINT/SIGTERM — those would change this test
    /// process's own disposition for every later test.
    func testADeliveredSignalCancelsTheFlag() throws {
        let flag = CLICancellationFlag()
        let sources = CLISignalHandlers.install([SIGUSR2], cancelling: flag)
        defer { sources.forEach { $0.cancel() } }

        // Process-directed, not `raise()`: the signal source watches the
        // process, and a thread-directed signal need not wake it.
        XCTAssertEqual(kill(getpid(), SIGUSR2), 0)

        let deadline = Date().addingTimeInterval(5)
        while !flag.isCancelled, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertTrue(flag.isCancelled, "The signal source should have cancelled the flag.")
    }
}
