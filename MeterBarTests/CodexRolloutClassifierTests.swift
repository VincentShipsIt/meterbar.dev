import XCTest
@testable import MeterBar

/// Coverage for the Codex rollout classifier: the block signal is the
/// structured `rate_limit_reached_type`, never prose; a later `task_complete`
/// clears it; the reached window selects the reason and reset instant.
final class CodexRolloutClassifierTests: XCTestCase {
    // MARK: - Fixtures

    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func meta(id: String = "sess-1", cwd: String? = "/tmp/work", source: String = "exec") -> String {
        var payload: [String: Any] = ["id": id, "source": source]
        if let cwd { payload["cwd"] = cwd }
        return line(["type": "session_meta", "timestamp": "2026-07-13T09:00:00.000Z", "payload": payload])
    }

    private func tokenCount(
        timestamp: String = "2026-07-13T09:05:00.000Z",
        reached: Any = NSNull(),
        primaryResetsAt: Int? = 1_900_000_000,
        secondaryResetsAt: Int? = 1_900_500_000
    ) -> String {
        var rateLimits: [String: Any] = ["rate_limit_reached_type": reached]
        if let primaryResetsAt {
            rateLimits["primary"] = ["used_percent": 100.0, "window_minutes": 300, "resets_at": primaryResetsAt]
        }
        if let secondaryResetsAt {
            rateLimits["secondary"] = ["used_percent": 100.0, "window_minutes": 10080, "resets_at": secondaryResetsAt]
        }
        return line([
            "type": "event_msg", "timestamp": timestamp,
            "payload": ["type": "token_count", "rate_limits": rateLimits]
        ])
    }

    private func taskComplete(timestamp: String = "2026-07-13T09:10:00.000Z") -> String {
        line(["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_complete"]])
    }

    // MARK: - Blocked signal

    func testPrimaryHitIsSessionLimitBlockedWithResetInstant() {
        let lines = [meta(), tokenCount(reached: "primary")]
        let summary = CodexRolloutClassifier.classify(fallbackID: "fallback", lines: lines)

        XCTAssertEqual(summary.sessionID, "sess-1")
        XCTAssertEqual(summary.cwd, "/tmp/work")
        guard case let .blocked(reason, blockedAt, resetHint) = summary.state else {
            return XCTFail("expected blocked, got \(summary.state)")
        }
        XCTAssertEqual(reason, .sessionLimit)
        XCTAssertEqual(blockedAt, CodexRolloutClassifier.parseTimestamp("2026-07-13T09:05:00.000Z"))
        XCTAssertEqual(resetHint?.resetAt, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testSecondaryHitIsWeeklyLimitWithSecondaryReset() {
        let lines = [meta(), tokenCount(reached: "secondary")]
        let summary = CodexRolloutClassifier.classify(fallbackID: "f", lines: lines)
        guard case let .blocked(reason, _, resetHint) = summary.state else {
            return XCTFail("expected blocked, got \(summary.state)")
        }
        XCTAssertEqual(reason, .weeklyLimit)
        XCTAssertEqual(resetHint?.resetAt, Date(timeIntervalSince1970: 1_900_500_000))
    }

    // MARK: - Recovery clears the block

    func testCompletionAfterHitClearsBlocked() {
        let lines = [meta(), tokenCount(reached: "primary"), taskComplete()]
        let summary = CodexRolloutClassifier.classify(fallbackID: "f", lines: lines)
        XCTAssertEqual(summary.state, .active, "a completed turn after the hit means it recovered")
    }

    func testHitAfterEarlierCompletionStaysBlocked() {
        // Completed an early turn, then a later turn hit the wall: still blocked.
        let lines = [
            meta(),
            tokenCount(timestamp: "2026-07-13T09:01:00.000Z", reached: NSNull()),
            taskComplete(timestamp: "2026-07-13T09:02:00.000Z"),
            tokenCount(timestamp: "2026-07-13T09:09:00.000Z", reached: "primary")
        ]
        let summary = CodexRolloutClassifier.classify(fallbackID: "f", lines: lines)
        guard case .blocked = summary.state else {
            return XCTFail("expected blocked after a later hit, got \(summary.state)")
        }
    }

    // MARK: - False-positive guards

    func testNullReachedTypeIsNotBlocked() {
        let lines = [meta(), tokenCount(reached: NSNull())]
        let summary = CodexRolloutClassifier.classify(fallbackID: "f", lines: lines)
        XCTAssertEqual(summary.state, .indeterminate, "normal usage (null reached type) is never a block")
    }

    func testRateLimitWordsInMessageContentDoNotBlock() {
        // A session that merely *discusses* rate limits must not read as blocked.
        let chatter = line([
            "type": "response_item", "timestamp": "2026-07-13T09:05:00.000Z",
            "payload": [
                "type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "You hit a 429 rate limit; usage limit reached, resets soon."]]
            ]
        ])
        let summary = CodexRolloutClassifier.classify(fallbackID: "f", lines: [meta(), chatter])
        XCTAssertEqual(summary.state, .indeterminate, "prose about limits is not a structured hit")
    }

    func testEmptyReachedStringIsNotBlocked() {
        let lines = [meta(), tokenCount(reached: "")]
        let summary = CodexRolloutClassifier.classify(fallbackID: "f", lines: lines)
        XCTAssertEqual(summary.state, .indeterminate)
    }

    // MARK: - Robustness

    func testGarbledAndTruncatedLinesDoNotCrash() {
        let lines = [
            "{ this is not json",
            String("{\"type\":\"session_meta\",\"payload\":{\"id\":\"sess-9\"".dropLast(4)), // truncated tail
            meta(id: "sess-9"),
            tokenCount(reached: "primary")
        ]
        let summary = CodexRolloutClassifier.classify(fallbackID: "fallback", lines: lines)
        XCTAssertEqual(summary.sessionID, "sess-9")
        guard case .blocked = summary.state else { return XCTFail("expected blocked despite garbled lines") }
    }

    func testFallbackIDUsedWhenNoSessionMeta() {
        let summary = CodexRolloutClassifier.classify(fallbackID: "on-disk-id", lines: [tokenCount(reached: "primary")])
        XCTAssertEqual(summary.sessionID, "on-disk-id")
    }

    func testMissingResetWindowStillBlocksWithoutHint() {
        // reached=primary but no primary window object: blocked, nil resetHint.
        let lines = [meta(), tokenCount(reached: "primary", primaryResetsAt: nil)]
        let summary = CodexRolloutClassifier.classify(fallbackID: "f", lines: lines)
        guard case let .blocked(reason, _, resetHint) = summary.state else {
            return XCTFail("expected blocked, got \(summary.state)")
        }
        XCTAssertEqual(reason, .sessionLimit)
        XCTAssertNil(resetHint)
    }
}
