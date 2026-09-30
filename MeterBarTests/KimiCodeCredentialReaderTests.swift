import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class KimiCodeCredentialReaderTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("KimiCodeCredentialReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private var credentialsDirectory: URL {
        home.appendingPathComponent(".kimi-code/credentials", isDirectory: true)
    }

    private func write(_ json: String, to root: URL? = nil) throws {
        let directory = (root ?? home).appendingPathComponent(".kimi-code/credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("kimi-code.json"))
    }

    private func read(environment: [String: String] = [:]) -> KimiCodeCredentialReader.Result {
        KimiCodeCredentialReader.read(environment: environment, realHomeDirectory: home.path, now: now)
    }

    func testDefaultPathIsTheOfficialManagedCredentialSlot() {
        XCTAssertEqual(
            KimiCodeCredentialReader.credentialFilePath(environment: [:], realHomeDirectory: "/Users/example"),
            "/Users/example/.kimi-code/credentials/kimi-code.json"
        )
    }

    func testKimiCodeHomeOverridesTheDataRoot() {
        XCTAssertEqual(
            KimiCodeCredentialReader.credentialFilePath(
                environment: ["KIMI_CODE_HOME": "/opt/kimi"],
                realHomeDirectory: "/Users/example"
            ),
            "/opt/kimi/credentials/kimi-code.json"
        )
        XCTAssertEqual(
            KimiCodeCredentialReader.credentialFilePath(
                environment: ["KIMI_CODE_HOME": "~/data/kimi"],
                realHomeDirectory: "/Users/example"
            ),
            "/Users/example/data/kimi/credentials/kimi-code.json"
        )
        XCTAssertEqual(
            KimiCodeCredentialReader.directory(environment: ["KIMI_CODE_HOME": "  "], realHomeDirectory: "/h"),
            "/h/.kimi-code",
            "a blank override falls back to the default root"
        )
    }

    func testMissingFileIsNotFound() {
        XCTAssertEqual(read(), .notFound)
        XCTAssertEqual(read().probe, .notFound)
        XCTAssertFalse(KimiCodeCredentialReader.credentialFileExists(environment: [:], realHomeDirectory: home.path))
    }

    func testUnexpiredTokenIsReturned() throws {
        try write(#"{"access_token":"tok-abc","refresh_token":"r","expires_at":1790003600,"token_type":"Bearer"}"#)

        XCTAssertEqual(read(), .token("tok-abc"))
        XCTAssertEqual(read().probe, .ready)
        XCTAssertTrue(KimiCodeCredentialReader.credentialFileExists(environment: [:], realHomeDirectory: home.path))
    }

    func testExpiredTokenIsReportedAsExpiredNeverRefreshed() throws {
        try write(#"{"access_token":"tok-abc","refresh_token":"r","expires_at":1789999999}"#)

        XCTAssertEqual(read(), .expired)
        XCTAssertEqual(read().probe, .expired)
    }

    func testUnknownExpiryIsNotTreatedAsExpired() throws {
        try write(#"{"access_token":"tok-abc"}"#)
        XCTAssertEqual(read(), .token("tok-abc"))

        try write(#"{"access_token":"tok-abc","expires_at":0}"#)
        XCTAssertEqual(read(), .token("tok-abc"))
    }

    func testMalformedOrIncompleteFilesAreUnreadable() throws {
        for body in ["", "not json", "[]", "{}", #"{"access_token":""}"#, #"{"access_token":"  "}"#, #"{"access_token":5}"#] {
            try write(body)
            XCTAssertEqual(read(), .unreadable, body)
            XCTAssertEqual(read().probe, .unreadable, body)
        }
    }

    func testSymlinkedCredentialFileIsRefused() throws {
        let target = home.appendingPathComponent("elsewhere.json")
        try Data(#"{"access_token":"tok-abc"}"#.utf8).write(to: target)
        try FileManager.default.createDirectory(at: credentialsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: credentialsDirectory.appendingPathComponent("kimi-code.json"),
            withDestinationURL: target
        )

        XCTAssertEqual(read(), .unreadable)
    }

    func testOversizedFileIsRefused() throws {
        try write(#"{"access_token":"tok-abc","padding":""# + String(repeating: "x", count: 70_000) + #""}"#)

        XCTAssertEqual(read(), .unreadable)
    }

    func testOnlyTheDefaultManagedSlotIsRead() throws {
        let directory = credentialsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"access_token":"scoped"}"#.utf8)
            .write(to: directory.appendingPathComponent("kimi-code-env-0123456789abcdef.json"))

        XCTAssertEqual(read(), .notFound, "credentials scoped to another host or base URL belong to another endpoint")
    }
}
