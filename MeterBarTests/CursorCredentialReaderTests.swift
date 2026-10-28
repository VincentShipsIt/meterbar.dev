import Foundation
import MeterBarShared
import Security
import SQLite3
import XCTest
@testable import MeterBar

// MARK: - CursorCredentialReaderTests

final class CursorCredentialReaderTests: XCTestCase {

    // MARK: Internal

    func testEncryptedCredentialResolvesToJWT() {
        let result = CursorCredentialReader.decode(encrypted) { mode in
            XCTAssertEqual(mode, .background)
            return .value(self.password)
        }
        XCTAssertEqual(result, .credentials(userID: "synthetic-user", token: token))
    }

    func testPlaintextCompatibilityDoesNotReadKeychain() {
        XCTAssertEqual(CursorCredentialReader.decode(token) { _ in
            XCTFail("Plaintext must not touch Keychain")
            return .notFound
        }, .credentials(userID: "synthetic-user", token: token))
    }

    func testKeychainFailureIsSeparateFromDatabaseAndMissingToken() {
        for outcome: ClaudeKeychainReadOutcome<Data> in [.interactionRequired, .denied] {
            XCTAssertEqual(CursorCredentialReader.decode(encrypted) { _ in outcome }.probe, .needsKeychainAccess)
        }
        for outcome: ClaudeKeychainReadOutcome<Data> in [.notFound, .failure(errSecInternalError)] {
            XCTAssertEqual(
                CursorCredentialReader.decode(encrypted) { _ in outcome }.probe, .encryptedCredentialUnavailable
            )
        }
        XCTAssertEqual(CursorCredentialReader.decode("").probe, .missingToken)
        XCTAssertEqual(CursorCredentialReader.decode("not-a-jwt").probe, .invalidToken)
        XCTAssertEqual(CursorCredentialReader.decode(token + "\n").probe, .invalidToken)
    }

    func testUnsupportedAndMalformedEncryptedValuesNeverReachKeychain() {
        let values = [
            "cursor-safe-storage:v2:unknown", "cursor-safe-storage:v1:not base64",
            "cursor-safe-storage:v1:" + Data("v11unknown".utf8).base64EncodedString(),
            "cursor-safe-storage:v1:" + Data("v10short".utf8).base64EncodedString(),
        ]
        for value in values {
            XCTAssertEqual(CursorCredentialReader.decode(value) { _ in
                XCTFail("Invalid envelope must fail before Keychain")
                return .value(self.password)
            }.probe, .encryptedCredentialUnavailable)
        }
    }

    func testWrongKeyFailsWithoutReturningEncryptedText() {
        XCTAssertEqual(CursorCredentialReader.decode(encrypted) { _ in
            .value(Data("wrong-key".utf8))
        }, .failure(.encryptedCredentialUnavailable))
    }

    func testTransientJournalFailureReopensDatabase() {
        var attempts = 0
        let result = CursorCredentialReader.read(databasePath: "synthetic.db", database: { _ in
            attempts += 1
            return attempts == 1 ? .failure(SQLITE_IOERR | (2 << 8)) : .stored(self.token)
        })
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(result.probe, .tokenPresent)
    }

    func testPersistentAndSchemaErrorsAreUnreadableNotMissingToken() {
        for code in [SQLITE_IOERR, SQLITE_CANTOPEN, SQLITE_BUSY, SQLITE_LOCKED, SQLITE_ERROR] {
            var attempts = 0
            let result = CursorCredentialReader.read(databasePath: "synthetic.db", database: { _ in
                attempts += 1
                return .failure(code)
            })
            XCTAssertEqual(result.probe, .unreadable)
            XCTAssertEqual(attempts, code == SQLITE_ERROR ? 1 : 3)
        }
        XCTAssertEqual(CursorCredentialReader.read(databasePath: nil).probe, .notFound)
        XCTAssertEqual(CursorCredentialReader.read(databasePath: "synthetic.db", database: { _ in
            .missingToken
        }).probe, .missingToken)
    }

    func testReadOnlySQLiteWorksWithWriterOpenAndClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.vscdb").path
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            writer,
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
            nil,
            nil,
            nil
        ), SQLITE_OK)
        XCTAssertEqual(CursorCredentialReader.read(databasePath: path).probe, .missingToken)
        let insert = "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(encrypted)')"
        XCTAssertEqual(sqlite3_exec(writer, insert, nil, nil, nil), SQLITE_OK)
        let read = {
            CursorCredentialReader.read(databasePath: path, keychain: { _ in .value(self.password) })
        }
        XCTAssertEqual(read(), .credentials(userID: "synthetic-user", token: token))
        // An uncommitted sign-out must not hide the committed token in WAL.
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE; DELETE FROM ItemTable", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(read().probe, .tokenPresent)
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        writer = nil
        XCTAssertEqual(read().probe, .tokenPresent)
    }

    func testBackgroundKeychainReadSuppressesBothPromptMechanisms() {
        let query = CursorCredentialReader.keychainQuery(mode: .background)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "Cursor Safe Storage")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "Cursor Key")
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        let gate = RecordingGate()
        let result = CursorCredentialReader.readKeychain(mode: .background, gate: gate) { _ in
            (errSecInteractionNotAllowed, nil)
        }
        XCTAssertEqual(gate.allowed, false)
        XCTAssertEqual(result, .interactionRequired)
        XCTAssertNil(CursorCredentialReader.keychainQuery(mode: .interactive)[kSecUseAuthenticationUI as String])
        _ = CursorCredentialReader.readKeychain(mode: .interactive, gate: gate) { _ in (errSecUserCanceled, nil) }
        XCTAssertEqual(gate.allowed, true)
    }

    // MARK: Private

    // Independent fixture: OpenSSL AES-128-CBC / Python hashlib.pbkdf2_hmac.
    // Every value here is synthetic; no real credentials or Keychain reads.
    private var token: String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64EncodedString()
        let payload = Data(#"{"sub":"auth0|synthetic-user"}"#.utf8).base64EncodedString()
        return [header, payload, "sig"].map { $0.replacingOccurrences(of: "=", with: "") }.joined(separator: ".")
    }
    private let encrypted = "cursor-safe-storage:v1:djEwSqvFXSUCdQkQVWOBHvdaERg/jBPiXjcP1+Qm5r4W+0oZk3O7GMtPetZ7QG3u7L7uNGbnvn8leTLnFLuycevU52+URSs67nV3WXsdok9Tvyw="
    private let password = Data("synthetic-password".utf8)

}

// MARK: - RecordingGate

private final class RecordingGate: KeychainInteractionGate, @unchecked Sendable {
    var allowed: Bool?

    func withUserInteraction(allowed: Bool, perform: () -> OSStatus) -> OSStatus {
        self.allowed = allowed
        return perform()
    }
}
