import XCTest
@testable import MeterBar

/// Coverage for #549 (3): `append` must be atomic across every writer to the
/// same day's log file — same-process (`WakeProcessRunner.record` and
/// `WakeEventHookRunner.record` both fire from the same state transition) and
/// cross-process alike. It is the app's only forensic trail with no crash
/// reporter behind it, so a torn line is a real loss, not cosmetic.
final class WakeRunLoggerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WakeRunLoggerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempDir = tempDir.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// `WakeRunLogger` is a `struct`: every caller — including two producers
    /// firing from the same state transition — holds an independent value
    /// with no shared in-process state, so the only thing that can serialize
    /// their writes is the file itself. `DispatchQueue.concurrentPerform`
    /// drives many independent `WakeRunLogger` instances at the same file on
    /// real OS threads in parallel — the same shape of contention as two
    /// processes racing — and every resulting line must still be a single,
    /// independently-decodable JSON record with no bytes borrowed from a
    /// neighbor.
    func testConcurrentAppendsProduceWellFormedLines() throws {
        let logDirectory = tempDir.appendingPathComponent("logs")
        let now = Date()
        let writerCount = 40

        DispatchQueue.concurrentPerform(iterations: writerCount) { index in
            let logger = WakeRunLogger(directory: logDirectory, now: { now })
            logger.append(WakeRunLogger.Record(
                timestamp: now,
                event: "resume",
                sessionID: "session-\(index)",
                reason: "quotaAvailable",
                outcome: "succeeded",
                exitCode: 0,
                durationMilliseconds: index,
                stdoutBytes: 0,
                stderrBytes: 0
            ))
        }

        let logFile = logDirectory.appendingPathComponent("session-wake-\(dayStamp(now)).log")
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)

        XCTAssertEqual(lines.count, writerCount, "every concurrent append must land as its own, whole line")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var seenSessionIDs = Set<String>()
        for line in lines {
            guard let data = line.data(using: .utf8) else {
                return XCTFail("line is not valid UTF-8: \(line)")
            }
            let record = try decoder.decode(WakeRunLogger.Record.self, from: data)
            seenSessionIDs.insert(record.sessionID)
        }
        XCTAssertEqual(seenSessionIDs.count, writerCount, "no line was corrupted into another writer's line")
    }

    /// A same-process regression guard for the plain, uncontended path: a
    /// single logger instance appending several records in sequence must
    /// still produce exactly that many well-formed lines.
    func testSequentialAppendsProduceOneLinePerRecord() throws {
        let logDirectory = tempDir.appendingPathComponent("logs")
        let now = Date()
        let logger = WakeRunLogger(directory: logDirectory, now: { now })

        for index in 0..<5 {
            logger.append(WakeRunLogger.Record(
                timestamp: now,
                event: "resume",
                sessionID: "session-\(index)",
                reason: "quotaAvailable",
                outcome: "succeeded",
                exitCode: 0,
                durationMilliseconds: index,
                stdoutBytes: 0,
                stderrBytes: 0
            ))
        }

        let logFile = logDirectory.appendingPathComponent("session-wake-\(dayStamp(now)).log")
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 5)
    }

    private func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}
