import CommonCrypto
import Foundation
import MeterBarShared
import Security
import SQLite3

/// Cursor owns storage and refresh. Reads/decrypts only the access token in memory;
/// never writes Cursor's database, Keychain, or a plaintext credential cache.
nonisolated enum CursorCredentialReader {
    enum Result: Equatable, Sendable {
        case credentials(userID: String, token: String)
        case failure(CursorDatabaseProbe)

        var probe: CursorDatabaseProbe {
            switch self {
            case .credentials: .tokenPresent
            case let .failure(probe): probe
            }
        }
    }

    enum DatabaseRead: Equatable, Sendable {
        case stored(String)
        case missingToken
        case failure(Int32)
    }

    static let encryptedPrefix = "cursor-safe-storage:v1:"
    static let keychainService = "Cursor Safe Storage"
    static let keychainAccount = "Cursor Key"

    static func read(
        databasePath: String?,
        mode: ClaudeKeychainAccessMode = .background,
        keychain: (ClaudeKeychainAccessMode) -> ClaudeKeychainReadOutcome<Data> = readKeychain,
        database: (String) -> DatabaseRead = readDatabase
    ) -> Result {
        guard let databasePath else {
            return .failure(.notFound)
        }
        // Reopen on transient WAL/journal races. Never use immutable mode or a
        // copied main file: either can miss Cursor's most recent token in WAL.
        for attempt in 0 ..< 3 {
            switch database(databasePath) {
            case let .stored(value):
                return decode(value, mode: mode, keychain: keychain)
            case .missingToken:
                return .failure(.missingToken)
            case let .failure(code):
                let retryable = [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_IOERR, SQLITE_CANTOPEN, SQLITE_PROTOCOL]
                    .contains(code & 0xFF)
                if !retryable || attempt == 2 {
                    return .failure(.unreadable)
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return .failure(.unreadable)
    }

    static func readDatabase(at path: String) -> DatabaseRead {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK else {
            return .failure(opened)
        }
        sqlite3_busy_timeout(database, 250)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(
            database, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &statement, nil
        )
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else {
            return .failure(prepared)
        }
        let stepped = sqlite3_step(statement)
        if stepped == SQLITE_DONE {
            return .missingToken
        }
        guard stepped == SQLITE_ROW else {
            return .failure(stepped)
        }
        guard let text = sqlite3_column_text(statement, 0) else {
            return .missingToken
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count <= 64 * 1024,
              let value = String(data: Data(bytes: text, count: count), encoding: .utf8) else {
            return .failure(SQLITE_MISMATCH)
        }
        return .stored(value)
    }

    static func decode(
        _ stored: String,
        mode: ClaudeKeychainAccessMode = .background,
        keychain: (ClaudeKeychainAccessMode) -> ClaudeKeychainReadOutcome<Data> = readKeychain
    ) -> Result {
        guard !stored.isEmpty else {
            return .failure(.missingToken)
        }
        var token = stored
        if stored.hasPrefix(encryptedPrefix) {
            guard let encrypted = Data(base64Encoded: String(stored.dropFirst(encryptedPrefix.count))),
                  encrypted.starts(with: Data("v10".utf8)),
                  encrypted.count > 3,
                  (encrypted.count - 3).isMultiple(of: kCCBlockSizeAES128) else {
                return .failure(.encryptedCredentialUnavailable)
            }
            switch keychain(mode) {
            case let .value(password):
                guard let plaintext = decrypt(encrypted, password: password) else {
                    return .failure(.encryptedCredentialUnavailable)
                }
                token = plaintext
            case .interactionRequired,
                 .denied:
                return .failure(.needsKeychainAccess)
            case .notFound,
                 .failure:
                return .failure(.encryptedCredentialUnavailable)
            }
        } else if stored.hasPrefix("cursor-safe-storage:") {
            return .failure(.encryptedCredentialUnavailable)
        }
        let jwtCharacters =
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let subjectCharacters =
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard token.split(separator: ".", omittingEmptySubsequences: false).count == 3,
              !token.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty),
              token.unicodeScalars.allSatisfy(jwtCharacters.contains),
              let userID = CursorLocalService.extractUserIdFromJWT(token), !userID.isEmpty,
              userID.unicodeScalars.allSatisfy(subjectCharacters.contains) else {
            return .failure(.invalidToken)
        }
        return .credentials(userID: userID, token: token)
    }

    /// Electron/Chromium macOS OSCrypt v10: PBKDF2-SHA1 (1003, saltysalt),
    /// AES-128-CBC, a 16-space IV, PKCS#7 padding. Unknown versions fail closed.
    /// Source: Chromium 140 components/os_crypt/sync/os_crypt_mac.mm.
    static func decrypt(_ encrypted: Data, password: Data) -> String? {
        guard !password.isEmpty, encrypted.starts(with: Data("v10".utf8)) else {
            return nil
        }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derived = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                bytes.bindMemory(to: Int8.self).baseAddress,
                password.count,
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &key,
                key.count
            )
        }
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard derived == kCCSuccess else {
            return nil
        }
        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = ciphertext.withUnsafeBytes { bytes in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                key,
                key.count,
                iv,
                bytes.baseAddress,
                ciphertext.count,
                &output,
                capacity,
                &written
            )
        }
        defer { _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard status == kCCSuccess else {
            return nil
        }
        return String(bytes: output.prefix(written), encoding: .utf8)
    }

    static func keychainQuery(mode: ClaudeKeychainAccessMode) -> [String: Any] {
        ClaudeKeychainQuery.applyingAccessMode(mode, to: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
    }

    static func readKeychain(
        mode: ClaudeKeychainAccessMode,
        gate: KeychainInteractionGate = LegacyKeychainInteractionGate(),
        copy: (CFDictionary) -> (OSStatus, Data?) = secureCopy
    ) -> ClaudeKeychainReadOutcome<Data> {
        var payload: Data?
        let query = keychainQuery(mode: mode) as CFDictionary
        let status = gate.withUserInteraction(allowed: mode == .interactive) {
            let (status, data) = copy(query)
            payload = data
            return status
        }
        return ClaudeKeychainQuery.outcome(status: status, result: payload, mode: mode)
    }

    // MARK: Private

    private static func readKeychain(mode: ClaudeKeychainAccessMode) -> ClaudeKeychainReadOutcome<Data> {
        readKeychain(mode: mode, gate: LegacyKeychainInteractionGate(), copy: secureCopy)
    }

    private static func secureCopy(_ query: CFDictionary) -> (OSStatus, Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query, &item)
        return (status, item as? Data)
    }
}
