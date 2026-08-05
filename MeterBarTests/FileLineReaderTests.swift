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
        var collected: [String] = []
        FileLineReader.forEachLine(in: url, chunkSize: chunkSize) { line in
            collected.append(String(decoding: line, as: UTF8.self))
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
        FileLineReader.forEachLine(in: url, chunkSize: chunkSize) { collected.append($0) }

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
            lineLength = line.count
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
        FileLineReader.forEachLine(in: url, chunkSize: chunkSize) { collected.append($0) }
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

    func testMissingFileReturnsFalseAndYieldsNothing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLineReaderTests-missing-\(UUID().uuidString).jsonl")
        var count = 0

        let opened = FileLineReader.forEachLine(in: url) { _ in count += 1 }

        XCTAssertFalse(opened)
        XCTAssertEqual(count, 0)
    }
}
