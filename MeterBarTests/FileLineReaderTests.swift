import XCTest
@testable import MeterBar

/// Covers the streaming reader that replaced the whole-file
/// `Data(contentsOf:)` + `String(data:encoding:)` loads in the cost scanners.
/// The chunk boundary is the interesting part: a line that straddles two reads
/// must come back intact, and the final line must be yielded even without a
/// trailing newline.
final class FileLineReaderTests: XCTestCase {
    private func writeFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLineReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("lines.jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func writeData(_ contents: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLineReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("lines.jsonl")
        try contents.write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func lines(of url: URL, chunkSize: Int = FileLineReader.defaultChunkSize) -> [String] {
        records(of: url, chunkSize: chunkSize).map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    private func records(
        of url: URL,
        chunkSize: Int = FileLineReader.defaultChunkSize,
        maxLineBytes: Int = FileLineReader.defaultMaxLineBytes,
        prefixBytes: Int = FileLineReader.defaultPrefixBytes
    ) -> [FileLineReader.Line] {
        var collected: [FileLineReader.Line] = []
        FileLineReader.forEachLine(
            in: url,
            chunkSize: chunkSize,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes
        ) { line in
            collected.append(line)
        }
        return collected
    }

    func testYieldsEachNewlineDelimitedLine() throws {
        let url = try writeFile("a\nbb\nccc\n")

        XCTAssertEqual(lines(of: url), ["a", "bb", "ccc"])
    }

    func testYieldsFinalLineWithoutTrailingNewline() throws {
        let url = try writeFile("a\nbb")

        XCTAssertEqual(lines(of: url), ["a", "bb"])
    }

    func testYieldsBlankLinesAsEmptyData() throws {
        let url = try writeFile("a\n\nb\n")

        XCTAssertEqual(lines(of: url), ["a", "", "b"])
    }

    func testStripsTrailingCarriageReturn() throws {
        // CRLF transcripts must not leave a stray \r on the payload handed to
        // JSONSerialization.
        let url = try writeFile("a\r\nbb\r\n")

        XCTAssertEqual(lines(of: url), ["a", "bb"])
    }

    func testSingleByteChunksProduceIdenticalLines() throws {
        let url = try writeFile("first\nsecond\nthird")

        XCTAssertEqual(lines(of: url, chunkSize: 1), ["first", "second", "third"])
    }

    func testLineLongerThanChunkIsReassembled() throws {
        let long = String(repeating: "x", count: 1_000)
        let url = try writeFile("\(long)\ntail")

        XCTAssertEqual(lines(of: url, chunkSize: 16), [long, "tail"])
    }

    func testArbitraryChunkSizesAgreeWithDefault() throws {
        let url = try writeFile("alpha\nbeta\n\ngamma\ndelta")
        let expected = lines(of: url)

        for chunkSize in [1, 2, 3, 5, 7, 11, 64] {
            XCTAssertEqual(lines(of: url, chunkSize: chunkSize), expected, "chunkSize \(chunkSize)")
        }
    }

    func testLineManyChunksLongIsDeliveredByteForByte() throws {
        // The reader must resume the newline search where the previous chunk
        // left off. Restarting at byte 0 each chunk is what made a long line
        // quadratic in its own length.
        let chunkSize = 64
        // 14...253 so the payload carries no \n to split on and no \r for the
        // CRLF trim to eat.
        var payload = Data()
        for index in 0..<(chunkSize * 50) {
            payload.append(UInt8(14 + index % 240))
        }
        var file = payload
        file.append(UInt8(ascii: "\n"))
        file.append(contentsOf: Array("tail".utf8))
        let url = try writeData(file)

        var collected: [Data] = []
        FileLineReader.forEachLine(in: url, chunkSize: chunkSize) { collected.append($0.bytes) }

        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(collected.first, payload)
        XCTAssertEqual(collected.last, Data("tail".utf8))
    }

    func testMultipleOversizedLinesInOneFile() throws {
        let chunkSize = 32
        let expected = [
            String(repeating: "a", count: chunkSize * 9),
            String(repeating: "b", count: chunkSize * 4 + 7),
            "short",
            String(repeating: "c", count: chunkSize * 11 + 1),
        ]
        let url = try writeFile(expected.joined(separator: "\n") + "\n")

        XCTAssertEqual(lines(of: url, chunkSize: chunkSize), expected)
    }

    func testNewlineExactlyOnChunkBoundary() throws {
        let chunkSize = 16

        // Newline is the last byte of a chunk.
        let atEnd = try writeFile(String(repeating: "x", count: chunkSize - 1) + "\n" + "tail")
        XCTAssertEqual(
            lines(of: atEnd, chunkSize: chunkSize),
            [String(repeating: "x", count: chunkSize - 1), "tail"]
        )

        // Newline is the first byte of the next chunk — the case where a naive
        // resume offset would emit an empty line and swallow the real one.
        let atStart = try writeFile(String(repeating: "x", count: chunkSize) + "\n" + "tail")
        XCTAssertEqual(
            lines(of: atStart, chunkSize: chunkSize),
            [String(repeating: "x", count: chunkSize), "tail"]
        )

        // And again after several chunks have accumulated into one long line.
        let deep = try writeFile(String(repeating: "x", count: chunkSize * 5) + "\n" + "tail")
        XCTAssertEqual(
            lines(of: deep, chunkSize: chunkSize),
            [String(repeating: "x", count: chunkSize * 5), "tail"]
        )
    }

    func testLongSingleLineReadsInLinearTime() throws {
        // Regression guard for the quadratic rescan. Real Codex rollout
        // transcripts carry single lines in the tens of megabytes; at 256 KiB
        // chunks the old loop rescanned the whole accumulated buffer per chunk
        // and took tens of seconds for a file this size. Linear scanning does
        // it in well under a second — 5s is a generous ceiling that only the
        // quadratic loop can breach.
        let byteCount = 32 * 1024 * 1024
        var file = Data(repeating: UInt8(ascii: "x"), count: byteCount)
        file.append(UInt8(ascii: "\n"))
        let url = try writeData(file)

        var yielded = 0
        var lineLength = 0
        let start = Date()
        let opened = FileLineReader.forEachLine(in: url) { line in
            yielded += 1
            lineLength = line.byteCount
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(opened)
        XCTAssertEqual(yielded, 1)
        XCTAssertEqual(lineLength, byteCount)
        XCTAssertLessThan(elapsed, 5, "32 MiB single line took \(elapsed)s — the scan is not linear")
    }

    /// Splits the whole file in the most obvious way possible. Deliberately
    /// naive — it is the oracle the chunked reader has to agree with, so it
    /// must be readable at a glance rather than fast.
    private func referenceLines(of data: Data) -> [Data] {
        var out: [Data] = []
        var current = Data()
        for byte in data {
            guard byte == UInt8(ascii: "\n") else {
                current.append(byte)
                continue
            }
            if current.last == UInt8(ascii: "\r") { current.removeLast() }
            out.append(current)
            current = Data()
        }
        if !current.isEmpty {
            if current.last == UInt8(ascii: "\r") { current.removeLast() }
            out.append(current)
        }
        return out
    }

    private func readerLines(of url: URL, chunkSize: Int) -> [Data] {
        var collected: [Data] = []
        FileLineReader.forEachLine(in: url, chunkSize: chunkSize) { collected.append($0.bytes) }
        return collected
    }

    func testMatchesReferenceSplitterOnPseudoRandomFiles() throws {
        // Seeded LCG, not `random()`: a differential failure has to be
        // reproducible from the test name alone.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func nextByte() -> UInt8 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8((seed >> 33) & 0xFF)
        }

        for iteration in 0..<40 {
            var payload = Data()
            for _ in 0..<(200 + iteration * 13) {
                let roll = nextByte()
                // Heavily biased toward \n and \r so boundaries, blank lines and
                // stray carriage returns actually occur instead of being a
                // 1-in-256 accident.
                switch roll % 8 {
                case 0, 1: payload.append(UInt8(ascii: "\n"))
                case 2: payload.append(UInt8(ascii: "\r"))
                default: payload.append(roll)
                }
            }
            let url = try writeData(payload)
            let expected = referenceLines(of: payload)

            for chunkSize in [1, 2, 3, 4, 5, 7, 8, 13, 16, 31, 64, 255, 1_024] {
                XCTAssertEqual(
                    readerLines(of: url, chunkSize: chunkSize),
                    expected,
                    "iteration \(iteration), chunkSize \(chunkSize)"
                )
            }
        }
    }

    func testCarriageReturnSplitAcrossChunkBoundary() throws {
        // The \r ends one chunk and its \n opens the next, so the trim has to
        // happen against the reassembled line rather than the current chunk.
        let chunkSize = 8
        let url = try writeFile(String(repeating: "x", count: chunkSize - 1) + "\r\n" + "tail")

        XCTAssertEqual(
            lines(of: url, chunkSize: chunkSize),
            [String(repeating: "x", count: chunkSize - 1), "tail"]
        )
    }

    func testCarriageReturnEndingAnOversizedLine() throws {
        // Same trim, but the line spans many chunks so it arrives via the
        // accumulation path rather than straight out of one chunk.
        let chunkSize = 16
        let long = String(repeating: "y", count: chunkSize * 6)
        let url = try writeFile(long + "\r\n" + "tail")

        XCTAssertEqual(lines(of: url, chunkSize: chunkSize), [long, "tail"])
    }

    func testTrailingCarriageReturnWithoutNewline() throws {
        let url = try writeFile("a\nbb\r")

        XCTAssertEqual(lines(of: url, chunkSize: 2), ["a", "bb"])
    }

    func testEmptyFileYieldsNothing() throws {
        let url = try writeFile("")
        var count = 0

        let opened = FileLineReader.forEachLine(in: url) { _ in count += 1 }

        XCTAssertTrue(opened)
        XCTAssertEqual(count, 0)
    }

    // MARK: - Oversized lines

    func testOversizedLineIsRetainedAsAPrefixAndFlagged() throws {
        // A Codex rollout can hold a single 56 MB JSONL line. Dropping it would
        // discard a real usage record, so the reader keeps a bounded prefix and
        // reports that the rest was cut.
        let url = try writeFile(String(repeating: "x", count: 10_000))

        let collected = records(of: url, chunkSize: 64, maxLineBytes: 128, prefixBytes: 128)

        XCTAssertEqual(collected.count, 1)
        XCTAssertTrue(collected[0].wasTruncated)
        XCTAssertEqual(collected[0].bytes.count, 128)
        // The line's real length is still reported even though it was not kept.
        XCTAssertEqual(collected[0].byteCount, 10_000)
        XCTAssertEqual(String(decoding: collected[0].bytes, as: UTF8.self), String(repeating: "x", count: 128))
    }

    func testLinesWithinTheCapAreUntouched() throws {
        let url = try writeFile("alpha\nbeta\n")

        let collected = records(of: url, maxLineBytes: 128, prefixBytes: 128)

        XCTAssertEqual(collected.map(\.wasTruncated), [false, false])
        XCTAssertEqual(collected.map(\.byteCount), [5, 4])
        XCTAssertEqual(collected.map { String(decoding: $0.bytes, as: UTF8.self) }, ["alpha", "beta"])
    }

    func testRetainedBytesDoNotGrowWithLineLength() throws {
        // The point of the prefix cap: peak retention is flat no matter how long
        // the line is. Asserted on the emitted byte count rather than on
        // allocations, which XCTest cannot observe.
        for length in [1_000, 10_000, 1_000_000] {
            let url = try writeFile(String(repeating: "y", count: length))

            let collected = records(of: url, chunkSize: 4_096, maxLineBytes: 256, prefixBytes: 256)

            XCTAssertEqual(collected.count, 1, "length \(length)")
            XCTAssertEqual(collected[0].bytes.count, 256, "length \(length)")
            XCTAssertEqual(collected[0].byteCount, length, "length \(length)")
        }
    }

    func testOversizedFinalLineWithoutTrailingNewlineIsStillEmitted() throws {
        // Rollouts are appended to live, so the last line frequently has no
        // terminator. That line must not be swallowed by the cap.
        let url = try writeFile("head\n" + String(repeating: "z", count: 5_000))

        let collected = records(of: url, chunkSize: 64, maxLineBytes: 100, prefixBytes: 100)

        XCTAssertEqual(collected.count, 2)
        XCTAssertFalse(collected[0].wasTruncated)
        XCTAssertEqual(String(decoding: collected[0].bytes, as: UTF8.self), "head")
        XCTAssertTrue(collected[1].wasTruncated)
        XCTAssertEqual(collected[1].bytes.count, 100)
        XCTAssertEqual(collected[1].byteCount, 5_000)
    }

    func testTruncationDoesNotDisturbNeighbouringLines() throws {
        let url = try writeFile("first\n" + String(repeating: "q", count: 2_000) + "\nlast\n")

        let collected = records(of: url, chunkSize: 128, maxLineBytes: 32, prefixBytes: 32)

        XCTAssertEqual(collected.map(\.wasTruncated), [false, true, false])
        XCTAssertEqual(
            collected.map { String(decoding: $0.bytes, as: UTF8.self) },
            ["first", String(repeating: "q", count: 32), "last"]
        )
    }

    func testPrefixSmallerThanTheCapKeepsOnlyThePrefix() throws {
        // `maxLineBytes` bounds what is buffered; `prefixBytes` is the salvage
        // slice handed to the parser. A line under the cap is kept whole.
        let url = try writeFile(String(repeating: "a", count: 200) + "\n" + String(repeating: "b", count: 5_000))

        let collected = records(of: url, chunkSize: 64, maxLineBytes: 512, prefixBytes: 64)

        XCTAssertEqual(collected.count, 2)
        XCTAssertFalse(collected[0].wasTruncated)
        XCTAssertEqual(collected[0].bytes.count, 200)
        XCTAssertTrue(collected[1].wasTruncated)
        XCTAssertEqual(collected[1].bytes.count, 64)
    }

    func testMissingFileReturnsFalseAndYieldsNothing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLineReaderTests-missing-\(UUID().uuidString).jsonl")
        var count = 0

        let opened = FileLineReader.forEachLine(in: url) { _ in count += 1 }

        XCTAssertFalse(opened)
        XCTAssertEqual(count, 0)
    }

    // MARK: - Resumable reads

    private func read(
        _ url: URL,
        startOffset: UInt64 = 0,
        maxBytes: Int = .max,
        chunkSize: Int = FileLineReader.defaultChunkSize
    ) -> (lines: [String], offsets: [UInt64], result: FileLineReadResult?) {
        var collected: [String] = []
        var offsets: [UInt64] = []
        var request = FileLineReadRequest()
        request.startOffset = startOffset
        request.maxBytes = maxBytes
        request.chunkSize = chunkSize
        let result = FileLineReader.readLines(in: url, request: request) { line, offset in
            collected.append(String(decoding: line.bytes, as: UTF8.self))
            offsets.append(offset)
        }
        return (collected, offsets, result)
    }

    func testReadLinesReportsTheByteOffsetOfEachLine() throws {
        let url = try writeFile("a\nbb\nccc\n")

        let read = self.read(url)

        XCTAssertEqual(read.lines, ["a", "bb", "ccc"])
        XCTAssertEqual(read.offsets, [0, 2, 5])
        XCTAssertEqual(read.result?.committedOffset, 9)
        XCTAssertEqual(read.result?.bytesRead, 9)
        XCTAssertEqual(read.result?.reachedEndOfFile, true)
    }

    func testReadLinesResumesFromAPersistedOffset() throws {
        let url = try writeFile("a\nbb\nccc\n")

        let read = self.read(url, startOffset: 2)

        XCTAssertEqual(read.lines, ["bb", "ccc"])
        XCTAssertEqual(read.result?.bytesRead, 7)
        XCTAssertEqual(read.result?.committedOffset, 9)
    }

    func testReadLinesStopsAtTheByteBudgetOnTheLastCompleteLine() throws {
        let url = try writeFile("a\nbb\nccc\n")

        // Four bytes covers "a\n" plus the first half of "bb\n".
        let read = self.read(url, maxBytes: 4, chunkSize: 1)

        XCTAssertEqual(read.lines, ["a"])
        XCTAssertEqual(read.result?.committedOffset, 2)
        XCTAssertEqual(read.result?.bytesRead, 4)
        XCTAssertEqual(read.result?.reachedEndOfFile, false)
    }

    func testReadLinesCommitsAStructurallyCompleteTrailingLineWithoutNewline() throws {
        let url = try writeFile("{\"a\":1}\n{\"b\":2}")

        let read = self.read(url)

        XCTAssertEqual(read.lines, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(read.result?.committedOffset, 15)
    }

    func testReadLinesWithholdsAHalfWrittenTrailingLine() throws {
        // The scanners read files that Claude Code and Codex are still appending
        // to. Committing a half-written record would double-count it once the
        // rest of the line lands.
        let url = try writeFile("{\"a\":1}\n{\"b\":")

        let read = self.read(url)

        XCTAssertEqual(read.lines, ["{\"a\":1}"])
        XCTAssertEqual(read.result?.committedOffset, 8)
        XCTAssertEqual(read.result?.reachedEndOfFile, true)
    }

    func testReadLinesNeverCommitsATrailingLineCutShortByTheBudget() throws {
        // The bytes look like complete JSON only because the budget stopped
        // reading there; the file itself continues.
        let url = try writeFile("{\"a\":1}{\"b\":2}\n")

        let read = self.read(url, maxBytes: 7, chunkSize: 1)

        XCTAssertTrue(read.lines.isEmpty)
        XCTAssertEqual(read.result?.committedOffset, 0)
    }

    func testReadLinesBoundsAnOversizedLineWithoutLosingItsCommittedOffset() throws {
        let oversized = String(repeating: "x", count: 100)
        let url = try writeFile(oversized + "\ntail\n")
        var request = FileLineReadRequest()
        request.chunkSize = 16
        request.maxLineBytes = 10
        request.prefixBytes = 7
        var lines: [FileLineReader.Line] = []
        var offsets: [UInt64] = []

        let result = FileLineReader.readLines(in: url, request: request) { line, offset in
            lines.append(line)
            offsets.append(offset)
        }

        XCTAssertEqual(offsets, [0, 101])
        XCTAssertEqual(lines.map(\.byteCount), [100, 4])
        XCTAssertEqual(lines.map(\.wasTruncated), [true, false])
        XCTAssertEqual(lines[0].bytes, Data(String(repeating: "x", count: 7).utf8))
        XCTAssertEqual(lines[1].bytes, Data("tail".utf8))
        XCTAssertEqual(result?.committedOffset, 106)
        XCTAssertEqual(result?.reachedEndOfFile, true)
    }

    func testReadLinesDoesNotCommitAnOversizedLineCutShortByTheBudget() throws {
        let url = try writeFile(String(repeating: "x", count: 100) + "\n")
        var request = FileLineReadRequest()
        request.maxBytes = 50
        request.chunkSize = 10
        request.maxLineBytes = 8
        request.prefixBytes = 8
        var lines: [FileLineReader.Line] = []

        let result = FileLineReader.readLines(in: url, request: request) { line, _ in
            lines.append(line)
        }

        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(result?.bytesRead, 50)
        XCTAssertEqual(result?.committedOffset, 0)
        XCTAssertEqual(result?.reachedEndOfFile, false)
    }

    func testReadLinesWithholdsATruncatedUnterminatedLineEvenWhenItsPrefixLooksComplete() throws {
        let url = try writeFile(#"{"a":1}"# + String(repeating: " ", count: 100))
        var request = FileLineReadRequest()
        request.maxLineBytes = 8
        request.prefixBytes = 8
        var lines: [FileLineReader.Line] = []

        let result = FileLineReader.readLines(in: url, request: request) { line, _ in
            lines.append(line)
        }

        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(result?.committedOffset, 0)
        XCTAssertEqual(result?.reachedEndOfFile, true)
    }

    func testStructuralCompletenessIgnoresBracesInsideStrings() {
        XCTAssertTrue(FileLineReader.isStructurallyCompleteJSONLine(Data(#"{"a":"}"}"#.utf8)))
        XCTAssertFalse(FileLineReader.isStructurallyCompleteJSONLine(Data(#"{"a":"}"#.utf8)))
        XCTAssertTrue(FileLineReader.isStructurallyCompleteJSONLine(Data(#"{"a":"\""}"#.utf8)))
        XCTAssertFalse(FileLineReader.isStructurallyCompleteJSONLine(Data(#"{"a":[1,2}"#.utf8)))
        XCTAssertFalse(FileLineReader.isStructurallyCompleteJSONLine(Data("".utf8)))
        XCTAssertFalse(FileLineReader.isStructurallyCompleteJSONLine(Data("   ".utf8)))
    }
}
