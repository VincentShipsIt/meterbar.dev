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
}
