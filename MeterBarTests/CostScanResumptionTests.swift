import Foundation
import XCTest
@testable import MeterBar

final class CostScanResumptionTests: XCTestCase {
    private let originalCutoff = Date(timeIntervalSince1970: 1_780_000_000)
    private let currentCutoff = Date(timeIntervalSince1970: 1_781_000_000)

    func testRejectsOffsetBeyondCurrentFileSize() {
        let file = makeFile(size: 100)
        let record = makeRecord(offset: 101, stamp: file.stamp)

        XCTAssertNil(resumableRecord(record, for: file))
    }

    func testRejectsCompleteRecordWhenFullStampDoesNotMatch() {
        let file = makeFile(size: 100, modified: 2_000, fileID: 42)
        let record = makeRecord(
            stamp: CostScanFileStamp(size: 100, modified: 1_000, fileID: 42),
            isComplete: true
        )

        XCTAssertNil(resumableRecord(record, for: file))
    }

    func testIncompleteRecordRequiresSameFileAndNondecreasingSize() {
        let stamp = CostScanFileStamp(size: 80, modified: 1_000, fileID: 42)
        let record = makeRecord(offset: 70, stamp: stamp, isComplete: false)

        XCTAssertNotNil(resumableRecord(record, for: makeFile(size: 100, modified: 2_000, fileID: 42)))
        XCTAssertNil(resumableRecord(record, for: makeFile(size: 100, modified: 2_000, fileID: 99)))
        XCTAssertNil(resumableRecord(record, for: makeFile(size: 70, modified: 2_000, fileID: 42)))
    }

    func testEqualCutoffReturnsRecordWithoutRebasing() throws {
        let file = makeFile(size: 100)
        var record = makeRecord(stamp: file.stamp)
        record.cutoff = currentCutoff
        record.payload.periodKeys = ["unchanged"]
        var didRebase = false

        let result = CostScanResumption.resumableRecord(
            existing: record,
            file: file,
            cutoff: currentCutoff
        ) { payload, cutoff in
            didRebase = true
            return payload.rebasePeriod(to: cutoff)
        }

        XCTAssertFalse(didRebase)
        XCTAssertEqual(try XCTUnwrap(result).payload.periodKeys, ["unchanged"])
    }

    func testWindowPayloadRebaseClearsPeriodWhenEveryEventPredatesCutoff() throws {
        let oldEvent = currentCutoff.addingTimeInterval(-100)
        var payload = CodexFileTotals(cutoff: originalCutoff)
        payload.period.eventKeys = ["stale-period"]
        payload.lifetime.eventKeys = ["old"]
        payload.lifetime.earliestDate = oldEvent
        payload.lifetime.latestDate = oldEvent

        let result = try XCTUnwrap(resumableRecord(makeRecord(payload: payload)))

        XCTAssertTrue(result.payload.period.eventKeys.isEmpty)
        XCTAssertEqual(result.payload.period.latestDate, currentCutoff)
        XCTAssertEqual(result.cutoff, currentCutoff)
    }

    func testWindowPayloadRebaseCopiesLifetimeWhenEveryEventFallsInsideCutoff() throws {
        let currentEvent = currentCutoff.addingTimeInterval(100)
        var payload = CodexFileTotals(cutoff: originalCutoff)
        payload.period.eventKeys = ["stale-period"]
        payload.lifetime.eventKeys = ["current"]
        payload.lifetime.earliestDate = currentEvent
        payload.lifetime.latestDate = currentEvent

        let result = try XCTUnwrap(resumableRecord(makeRecord(payload: payload)))

        XCTAssertEqual(result.payload.period.eventKeys, ["current"])
        XCTAssertEqual(result.payload.period.earliestDate, currentEvent)
        XCTAssertEqual(result.payload.period.latestDate, currentEvent)
        XCTAssertEqual(result.cutoff, currentCutoff)
    }

    func testWindowPayloadRebaseRejectsRecordWhenEventsStraddleCutoff() {
        var payload = CodexFileTotals(cutoff: originalCutoff)
        payload.lifetime.eventKeys = ["old", "current"]
        payload.lifetime.earliestDate = currentCutoff.addingTimeInterval(-100)
        payload.lifetime.latestDate = currentCutoff.addingTimeInterval(100)

        XCTAssertNil(resumableRecord(makeRecord(payload: payload)))
    }

    /// Grok reaches the window rebase through the same shared conformance as
    /// Codex rather than its own copy, so it is covered explicitly: a missing
    /// conformance would still compile against the generic seam and silently
    /// stop rebasing.
    func testGrokPayloadSharesTheWindowRebaseBehavior() throws {
        let oldEvent = currentCutoff.addingTimeInterval(-100)
        var stalePayload = GrokFileTotals(cutoff: originalCutoff)
        stalePayload.period.eventKeys = ["stale-period"]
        stalePayload.lifetime.eventKeys = ["old"]
        stalePayload.lifetime.earliestDate = oldEvent
        stalePayload.lifetime.latestDate = oldEvent

        let staleResult = try XCTUnwrap(resumableRecord(makeRecord(payload: stalePayload)))
        XCTAssertTrue(staleResult.payload.period.eventKeys.isEmpty)
        XCTAssertEqual(staleResult.payload.period.latestDate, currentCutoff)
        XCTAssertEqual(staleResult.cutoff, currentCutoff)

        let currentEvent = currentCutoff.addingTimeInterval(100)
        var insidePayload = GrokFileTotals(cutoff: originalCutoff)
        insidePayload.period.eventKeys = ["stale-period"]
        insidePayload.lifetime.eventKeys = ["current"]
        insidePayload.lifetime.earliestDate = currentEvent
        insidePayload.lifetime.latestDate = currentEvent

        let insideResult = try XCTUnwrap(resumableRecord(makeRecord(payload: insidePayload)))
        XCTAssertEqual(insideResult.payload.period.eventKeys, ["current"])
        XCTAssertEqual(insideResult.payload.period.latestDate, currentEvent)

        var straddlePayload = GrokFileTotals(cutoff: originalCutoff)
        straddlePayload.lifetime.eventKeys = ["old", "current"]
        straddlePayload.lifetime.earliestDate = oldEvent
        straddlePayload.lifetime.latestDate = currentEvent

        XCTAssertNil(resumableRecord(makeRecord(payload: straddlePayload)))
    }

    func testClaudeRebasePreservesItsSeparatePeriodAndLifetimeKeySemantics() throws {
        var beforePayload = ClaudeFileTotals()
        beforePayload.period.input = 10
        beforePayload.periodKeys = ["stale-period"]
        beforePayload.lifetime.latest = currentCutoff.addingTimeInterval(-100)
        beforePayload.lifetimeKeys = ["old"]

        let beforeResult = try XCTUnwrap(resumableRecord(makeRecord(payload: beforePayload)))
        XCTAssertFalse(beforeResult.payload.period.hasUsage)
        XCTAssertTrue(beforeResult.payload.periodKeys.isEmpty)
        XCTAssertEqual(beforeResult.payload.lifetimeKeys, ["old"])

        var insidePayload = ClaudeFileTotals()
        insidePayload.lifetime.input = 25
        insidePayload.lifetime.earliest = currentCutoff.addingTimeInterval(100)
        insidePayload.lifetime.latest = currentCutoff.addingTimeInterval(200)
        insidePayload.lifetimeKeys = ["current"]

        let insideResult = try XCTUnwrap(resumableRecord(makeRecord(payload: insidePayload)))
        XCTAssertEqual(insideResult.payload.period.input, 25)
        XCTAssertEqual(insideResult.payload.periodKeys, ["current"])
    }

    private func resumableRecord<Payload: CostScanPeriodRebasable>(
        _ record: CostScanFileRecord<Payload>,
        for file: CostScanFile? = nil
    ) -> CostScanFileRecord<Payload>? {
        let file = file ?? makeFile(
            size: record.stamp.size,
            modified: record.stamp.modified,
            fileID: record.stamp.fileID
        )
        return CostScanResumption.resumableRecord(
            existing: record,
            file: file,
            cutoff: currentCutoff
        ) { payload, cutoff in
            payload.rebasePeriod(to: cutoff)
        }
    }

    private func makeFile(
        size: Int,
        modified: Double = 1_000,
        fileID: UInt64? = 42
    ) -> CostScanFile {
        CostScanFile(
            url: URL(fileURLWithPath: "/tmp/cost-scan-resumption.jsonl"),
            stamp: CostScanFileStamp(size: size, modified: modified, fileID: fileID)
        )
    }

    private func makeRecord(
        offset: UInt64 = 50,
        stamp: CostScanFileStamp = CostScanFileStamp(size: 100, modified: 1_000, fileID: 42),
        isComplete: Bool = false,
        payload: ClaudeFileTotals = ClaudeFileTotals()
    ) -> CostScanFileRecord<ClaudeFileTotals> {
        CostScanFileRecord(
            offset: offset,
            stamp: stamp,
            cutoff: originalCutoff,
            isComplete: isComplete,
            payload: payload
        )
    }

    private func makeRecord<Payload: Codable & Sendable>(
        offset: UInt64 = 50,
        stamp: CostScanFileStamp = CostScanFileStamp(size: 100, modified: 1_000, fileID: 42),
        isComplete: Bool = false,
        payload: Payload
    ) -> CostScanFileRecord<Payload> {
        CostScanFileRecord(
            offset: offset,
            stamp: stamp,
            cutoff: originalCutoff,
            isComplete: isComplete,
            payload: payload
        )
    }
}
