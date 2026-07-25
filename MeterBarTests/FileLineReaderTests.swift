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
