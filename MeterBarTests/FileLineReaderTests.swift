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
