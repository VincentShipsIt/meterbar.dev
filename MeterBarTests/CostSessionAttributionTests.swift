import XCTest
@testable import MeterBar

final class CostSessionAttributionTests: XCTestCase {
    func testStableIDUsesTheFilenameStem() {
        let url = URL(fileURLWithPath: "/Users/demo/.codex/sessions/rollout-2026-08-01-aabbccdd-1111-2222-3333-444444444444.jsonl")
        XCTAssertEqual(
            CostSessionAttribution.stableID(from: url),
            "rollout-2026-08-01-aabbccdd-1111-2222-3333-444444444444"
        )
    }

    func testSanitizeStripsDirectoriesAndEmptyValues() {
        XCTAssertEqual(
            CostSessionAttribution.sanitize("/Users/demo/.claude/projects/foo/session-1.jsonl"),
            "session-1"
        )
        XCTAssertEqual(CostSessionAttribution.sanitize("  "), CostSessionAttribution.unknownSessionID)
        XCTAssertEqual(CostSessionAttribution.sanitize("conv-1"), "conv-1")
    }

    func testPresentationShortensUUIDStemsWithoutLeakingPaths() {
        let presentation = CostSessionPresentation(
            identifier: "aabbccdd-1111-2222-3333-444444444444",
            projectIdentifier: "www/meterbardev"
        )
        XCTAssertEqual(presentation.title, "Session aabbccdd")
        XCTAssertEqual(presentation.detail, "meterbardev")
        XCTAssertFalse(presentation.title.contains("/"))
    }

    func testPresentationNamesTheUnknownBucket() {
        let presentation = CostSessionPresentation(
            identifier: CostSessionAttribution.unknownSessionID
        )
        XCTAssertEqual(presentation.title, "Unknown session")
        XCTAssertNil(presentation.detail)
    }
}
