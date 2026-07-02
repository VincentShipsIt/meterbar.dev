import XCTest
import MeterBarShared
@testable import MeterBar

final class ServiceTypeTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(ServiceType.claude.rawValue, "Claude")
        XCTAssertEqual(ServiceType.claudeCode.rawValue, "Claude Code")
        XCTAssertEqual(ServiceType.openai.rawValue, "OpenAI")
        XCTAssertEqual(ServiceType.codexCli.rawValue, "Codex CLI")
        XCTAssertEqual(ServiceType.cursor.rawValue, "Cursor")
    }

    func testDisplayNames() {
        XCTAssertEqual(ServiceType.claude.displayName, "Claude API")
        XCTAssertEqual(ServiceType.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(ServiceType.openai.displayName, "OpenAI")
        XCTAssertEqual(ServiceType.codexCli.displayName, "OpenAI Codex")
        XCTAssertEqual(ServiceType.cursor.displayName, "Cursor")
    }

    func testIconNames() {
        XCTAssertEqual(ServiceType.claude.iconName, "sparkles")
        XCTAssertEqual(ServiceType.claudeCode.iconName, "terminal")
        XCTAssertEqual(ServiceType.openai.iconName, "brain")
        XCTAssertEqual(ServiceType.codexCli.iconName, "terminal.fill")
        XCTAssertEqual(ServiceType.cursor.iconName, "cursorarrow.click")
    }

    func testIdProperty() {
        XCTAssertEqual(ServiceType.claude.id, "Claude")
        XCTAssertEqual(ServiceType.claudeCode.id, "Claude Code")
        XCTAssertEqual(ServiceType.openai.id, "OpenAI")
        XCTAssertEqual(ServiceType.codexCli.id, "Codex CLI")
        XCTAssertEqual(ServiceType.cursor.id, "Cursor")
    }

    func testAllCasesCount() {
        XCTAssertEqual(ServiceType.allCases.count, 5)
    }

    func testCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for service in ServiceType.allCases {
            let encoded = try encoder.encode(service)
            let decoded = try decoder.decode(ServiceType.self, from: encoded)
            XCTAssertEqual(service, decoded)
        }
    }

    func testDecodingFromRawValue() throws {
        let decoder = JSONDecoder()

        let claudeJSON = "\"Claude\"".data(using: .utf8)!
        let claude = try decoder.decode(ServiceType.self, from: claudeJSON)
        XCTAssertEqual(claude, .claude)

        let cursorJSON = "\"Cursor\"".data(using: .utf8)!
        let cursor = try decoder.decode(ServiceType.self, from: cursorJSON)
        XCTAssertEqual(cursor, .cursor)
    }
}
