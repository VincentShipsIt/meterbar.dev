import Foundation
import XCTest
@testable import MeterBar

final class ServeTokenSourceTests: XCTestCase {
    func testExplicitArgumentWinsOverFileEnvironmentAndGeneration() throws {
        var didReadFile = false
        var didGenerate = false

        let resolved = try ServeTokenSource.resolve(
            explicitToken: "argument token with spaces",
            tokenFilePath: "/ignored/token",
            environment: ["METERBAR_SERVE_TOKEN": "environment-token"],
            readFile: { _ in
                didReadFile = true
                return "file-token"
            },
            generate: {
                didGenerate = true
                return "generated-token"
            }
        )

        XCTAssertEqual(
            resolved,
            ResolvedServeToken(token: "argument token with spaces", origin: .explicitArgument)
        )
        XCTAssertFalse(didReadFile)
        XCTAssertFalse(didGenerate)
    }

    func testFileWinsOverEnvironmentAndGenerationAndTrimsOnlyTrailingWhitespace() throws {
        var didGenerate = false

        let resolved = try ServeTokenSource.resolve(
            explicitToken: nil,
            tokenFilePath: "/token",
            environment: ["METERBAR_SERVE_TOKEN": "environment-token"],
            readFile: { path in
                XCTAssertEqual(path, "/token")
                return "  file token with internal spaces \t\n"
            },
            generate: {
                didGenerate = true
                return "generated-token"
            }
        )

        XCTAssertEqual(
            resolved,
            ResolvedServeToken(token: "  file token with internal spaces", origin: .file)
        )
        XCTAssertFalse(didGenerate)
    }

    func testEnvironmentWinsOverGenerationAndPreservesTokenVerbatim() throws {
        var didGenerate = false

        let resolved = try ServeTokenSource.resolve(
            explicitToken: nil,
            tokenFilePath: nil,
            environment: ["METERBAR_SERVE_TOKEN": "environment token with spaces"],
            readFile: { _ in XCTFail("No file should be read."); return "" },
            generate: {
                didGenerate = true
                return "generated-token"
            }
        )

        XCTAssertEqual(
            resolved,
            ResolvedServeToken(token: "environment token with spaces", origin: .environment)
        )
        XCTAssertFalse(didGenerate)
    }

    func testGeneratesOnlyWhenNoOtherSourceIsSupplied() throws {
        var generationCount = 0

        let resolved = try ServeTokenSource.resolve(
            explicitToken: nil,
            tokenFilePath: nil,
            environment: [:],
            readFile: { _ in XCTFail("No file should be read."); return "" },
            generate: {
                generationCount += 1
                return "generated-token"
            }
        )

        XCTAssertEqual(resolved, ResolvedServeToken(token: "generated-token", origin: .generated))
        XCTAssertEqual(generationCount, 1)
    }

    func testBlankExplicitArgumentThrowsTypedErrorWithoutConsultingLowerPrecedenceSources() {
        assertResolutionError(.blankExplicitArgument) {
            _ = try ServeTokenSource.resolve(
                explicitToken: " \t\n",
                tokenFilePath: "/ignored/token",
                environment: ["METERBAR_SERVE_TOKEN": "environment-token"],
                readFile: { _ in XCTFail("No file should be read."); return "" },
                generate: { XCTFail("No token should be generated."); return "" }
            )
        }
    }

    func testUnreadableTokenFileThrowsTypedError() {
        assertResolutionError(.unreadableTokenFile(path: "/missing/token")) {
            _ = try ServeTokenSource.resolve(
                explicitToken: nil,
                tokenFilePath: "/missing/token",
                environment: [:],
                readFile: { _ in throw TestFileError.unreadable },
                generate: { XCTFail("No token should be generated."); return "" }
            )
        }
    }

    func testBlankTokenFileThrowsTypedErrorAfterTrimming() {
        assertResolutionError(.blankTokenFile(path: "/blank/token")) {
            _ = try ServeTokenSource.resolve(
                explicitToken: nil,
                tokenFilePath: "/blank/token",
                environment: [:],
                readFile: { _ in " \t\n" },
                generate: { XCTFail("No token should be generated."); return "" }
            )
        }
    }

    func testBlankEnvironmentTokenThrowsTypedErrorInsteadOfGenerating() {
        assertResolutionError(.blankEnvironment) {
            _ = try ServeTokenSource.resolve(
                explicitToken: nil,
                tokenFilePath: nil,
                environment: ["METERBAR_SERVE_TOKEN": " \t\n"],
                readFile: { _ in XCTFail("No file should be read."); return "" },
                generate: { XCTFail("No token should be generated."); return "" }
            )
        }
    }

    private func assertResolutionError(
        _ expected: ServeTokenResolutionError,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? ServeTokenResolutionError, expected)
        }
    }
}

private enum TestFileError: Error {
    case unreadable
}
