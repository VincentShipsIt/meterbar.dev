import XCTest
import MeterBarShared
@testable import MeterBar

final class ServiceTypeTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(ServiceType.claudeCode.rawValue, "Claude Code")
        XCTAssertEqual(ServiceType.codexCli.rawValue, "Codex CLI")
        XCTAssertEqual(ServiceType.cursor.rawValue, "Cursor")
        XCTAssertEqual(ServiceType.openRouter.rawValue, "OpenRouter")
    }

    func testDisplayNames() {
        XCTAssertEqual(ServiceType.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(ServiceType.codexCli.displayName, "OpenAI Codex")
        XCTAssertEqual(ServiceType.cursor.displayName, "Cursor")
        XCTAssertEqual(ServiceType.openRouter.displayName, "OpenRouter")
    }

    func testIconNames() {
        XCTAssertEqual(ServiceType.claudeCode.iconName, "terminal")
        XCTAssertEqual(ServiceType.codexCli.iconName, "terminal.fill")
        XCTAssertEqual(ServiceType.cursor.iconName, "cursorarrow.click")
        XCTAssertEqual(ServiceType.openRouter.iconName, "point.3.connected.trianglepath.dotted")
    }

    func testIdProperty() {
        XCTAssertEqual(ServiceType.claudeCode.id, "Claude Code")
        XCTAssertEqual(ServiceType.codexCli.id, "Codex CLI")
        XCTAssertEqual(ServiceType.cursor.id, "Cursor")
        XCTAssertEqual(ServiceType.openRouter.id, "OpenRouter")
    }

    func testAllCasesCount() {
        XCTAssertEqual(ServiceType.allCases.count, 4)
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

        let claudeCodeJSON = "\"Claude Code\"".data(using: .utf8)!
        let claudeCode = try decoder.decode(ServiceType.self, from: claudeCodeJSON)
        XCTAssertEqual(claudeCode, .claudeCode)

        let cursorJSON = "\"Cursor\"".data(using: .utf8)!
        let cursor = try decoder.decode(ServiceType.self, from: cursorJSON)
        XCTAssertEqual(cursor, .cursor)
    }
}
