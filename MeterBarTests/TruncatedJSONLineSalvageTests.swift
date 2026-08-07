import XCTest
@testable import MeterBar

/// Covers the key-scoped extractor the scanners fall back to when a transcript
/// line was too long to retain whole. Its input is a window cut at an arbitrary
/// byte, so every case here starts or ends mid-record on purpose.
final class TruncatedJSONLineSalvageTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testExtractsAnObjectValue() throws {
        let window = data(#"tail","usage":{"input_tokens":5,"output_tokens":7}},"requestId":"req_1"}"#)

        let usage = try XCTUnwrap(TruncatedJSONLineSalvage.lastValue(forKey: "usage", in: window) as? [String: Any])

        XCTAssertEqual(usage["input_tokens"] as? Int, 5)
        XCTAssertEqual(usage["output_tokens"] as? Int, 7)
    }

    func testExtractsAStringValue() throws {
        let window = data(#""stop_reason":null,"timestamp":"2026-07-01T10:00:00.000Z","type":"assistant"}"#)

        XCTAssertEqual(
            TruncatedJSONLineSalvage.lastValue(forKey: "timestamp", in: window) as? String,
            "2026-07-01T10:00:00.000Z"
        )
    }

    func testExtractsBooleanAndNumericLiterals() {
        let window = data(#"{"isSidechain":true,"cost":1.5,"depth":3}"#)

        XCTAssertEqual(TruncatedJSONLineSalvage.firstValue(forKey: "isSidechain", in: window) as? Bool, true)
        XCTAssertEqual(TruncatedJSONLineSalvage.firstValue(forKey: "cost", in: window) as? Double, 1.5)
        XCTAssertEqual(TruncatedJSONLineSalvage.firstValue(forKey: "depth", in: window) as? Int, 3)
    }

    func testIgnoresAValueTheWindowCutsShort() {
        let window = data(#""model":"claude-sonnet-4-5","usage":{"input_tokens":5,"outp"#)

        XCTAssertNil(TruncatedJSONLineSalvage.lastValue(forKey: "usage", in: window))
        XCTAssertEqual(
            TruncatedJSONLineSalvage.lastValue(forKey: "model", in: window) as? String, "claude-sonnet-4-5"
        )
    }

    func testIgnoresAKeyWithNoColonAfterIt() {
        let window = data(#"{"content":"the word \"usage\" appears here","other":1}"#)

        XCTAssertNil(TruncatedJSONLineSalvage.firstValue(forKey: "usage", in: window))
    }

    func testReturnsEveryOccurrenceInDocumentOrder() throws {
        let window = data(#"{"usage":{"input_tokens":1},"b":{"usage":{"input_tokens":2}}}"#)

        let usages = TruncatedJSONLineSalvage.values(forKey: "usage", in: window)

        XCTAssertEqual(usages.count, 2)
        XCTAssertEqual((usages.first as? [String: Any])?["input_tokens"] as? Int, 1)
        XCTAssertEqual((usages.last as? [String: Any])?["input_tokens"] as? Int, 2)
    }

    func testStopsExtractingBeyondTheValueCeiling() {
        let blob = String(repeating: "a", count: TruncatedJSONLineSalvage.maximumValueBytes + 64)
        let window = data(#"{"content":"\#(blob)","input_tokens":9}"#)

        XCTAssertNil(TruncatedJSONLineSalvage.firstValue(forKey: "content", in: window))
        XCTAssertEqual(TruncatedJSONLineSalvage.firstValue(forKey: "input_tokens", in: window) as? Int, 9)
    }

    func testHandlesNestedBracketsAndEscapedQuotesInsideTheValue() throws {
        let window = data(#"x,"usage":{"detail":"a \"quoted\" }brace{","input_tokens":4}}"#)

        let usage = try XCTUnwrap(TruncatedJSONLineSalvage.lastValue(forKey: "usage", in: window) as? [String: Any])

        XCTAssertEqual(usage["input_tokens"] as? Int, 4)
    }

    func testEmptyWindowYieldsNothing() {
        XCTAssertNil(TruncatedJSONLineSalvage.firstValue(forKey: "usage", in: Data()))
        XCTAssertTrue(TruncatedJSONLineSalvage.values(forKey: "usage", in: Data()).isEmpty)
    }
}
