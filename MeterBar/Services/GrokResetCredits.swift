import Foundation
import MeterBarShared

/// Banked Grok usage-limit resets — the Redeem row in grok.com Settings → Usage.
///
/// Weekly percent still comes from official `_x.ai/billing`. This RPC is the
/// same class of unofficial HTTP Codex uses for reset credits: grok.com
/// `prod_mc_billing.ConsumerUiSvc/GetRemainingResets`, authenticated with the
/// cached OIDC access token from `$GROK_HOME/auth.json`. The token is held only
/// for the request and is never logged.
nonisolated enum GrokResetCredits {
    /// One still-valid (or already-expired) reset token.
    struct Token: Equatable, Sendable {
        let tokenID: String
        let validFrom: Date?
        let expiresAt: Date?
    }

    struct Snapshot: Equatable, Sendable {
        let tokens: [Token]
        /// Tokens whose `expiresAt` is still in the future at decode time.
        /// Missing expiry is treated as still valid — the server accepted it.
        let availableCount: Int

        init(tokens: [Token], now: Date = Date()) {
            self.tokens = tokens
            availableCount = tokens.filter { token in
                guard let expiresAt = token.expiresAt else { return true }
                return expiresAt > now
            }.count
        }
    }

    /// Reads the cached Grok Build OIDC access token. The outer object is keyed
    /// by issuer + client id; any first non-empty `key` that is not a
    /// parseably-expired JWT is usable.
    static func accessToken(from data: Data?, now: Date = Date()) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for value in object.values {
            guard let credential = value as? [String: Any],
                  let key = credential["key"] as? String else {
                continue
            }
            let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            guard !OAuthTokenExpiry.isExpired(jwt: token, now: now) else { continue }
            return token
        }
        return nil
    }

    static func decode(grpcWeb data: Data, now: Date = Date()) throws -> Snapshot {
        guard let message = GrpcWeb.unprefixedMessage(in: data) else {
            throw GrokResetCreditsRPC.Error.invalidResponse
        }
        let tokens = try Proto.resetTokens(in: message)
        return Snapshot(tokens: tokens, now: now)
    }
}

// MARK: - Transport

nonisolated enum GrokResetCreditsRPC {
    enum Error: Swift.Error, Equatable {
        case invalidResponse
        case requestFailed
    }

    static let remainingResetsURL = URL(
        string: "https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets"
    )!

    /// Empty protobuf framed as one uncompressed grpc-web data frame.
    static let emptyRequest = Data([0x00, 0x00, 0x00, 0x00, 0x00])

    static func fetchAvailableCount(
        accessToken: String,
        session: URLSession = ServiceSupport.session,
        now: Date = Date()
    ) async throws -> Int {
        var request = URLRequest(url: remainingResetsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.httpBody = emptyRequest

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.requestFailed
        }
        return try GrokResetCredits.decode(grpcWeb: data, now: now).availableCount
    }
}

// MARK: - grpc-web + proto

/// grpc-web: 1 flag byte + 4-byte big-endian length + payload. The high bit on
/// the flag marks a trailer frame (`grpc-status: 0`), which we skip.
private enum GrpcWeb {
    static func unprefixedMessage(in data: Data) -> Data? {
        var offset = 0
        var message: Data?
        while offset + 5 <= data.count {
            let flags = data[offset]
            let length = Int(data[offset + 1]) << 24
                | Int(data[offset + 2]) << 16
                | Int(data[offset + 3]) << 8
                | Int(data[offset + 4])
            offset += 5
            guard offset + length <= data.count else { return nil }
            let payload = data.subdata(in: offset..<(offset + length))
            offset += length
            if flags & 0x80 == 0 {
                message = payload
            }
        }
        return message
    }
}

/// Just enough protobuf to read `ConsumerGetRemainingResetsResp`.
///
///     message ConsumerGetRemainingResetsResp {
///       repeated ConsumerResetToken tokens = 10;
///     }
///     message ConsumerResetToken {
///       string token_id = 10;
///       google.protobuf.Timestamp validity_start = 20;
///       google.protobuf.Timestamp validity_end = 30;
///     }
private enum Proto {
    static let tokensField = 10
    static let tokenIDField = 10
    static let validFromField = 20
    static let expiresAtField = 30
    static let timestampSecondsField = 1

    static func resetTokens(in message: Data) throws -> [GrokResetCredits.Token] {
        try fields(in: message).compactMap { field, value -> GrokResetCredits.Token? in
            guard field == tokensField else { return nil }
            return token(in: value)
        }
    }

    private static func token(in message: Data) -> GrokResetCredits.Token? {
        var tokenID: String?
        var validFrom: Date?
        var expiresAt: Date?
        for (field, value) in (try? fields(in: message)) ?? [] {
            switch field {
            case tokenIDField:
                tokenID = String(data: value, encoding: .utf8)
            case validFromField:
                validFrom = timestamp(in: value)
            case expiresAtField:
                expiresAt = timestamp(in: value)
            default:
                continue
            }
        }
        guard let tokenID, !tokenID.isEmpty else { return nil }
        return GrokResetCredits.Token(tokenID: tokenID, validFrom: validFrom, expiresAt: expiresAt)
    }

    private static func timestamp(in message: Data) -> Date? {
        for (field, value) in (try? fields(in: message)) ?? [] {
            guard field == timestampSecondsField, let seconds = varint(value) else { continue }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        return nil
    }

    /// Length-delimited fields only — every field this decoder cares about is a
    /// nested message or a string. Unknown wire types are skipped when possible.
    private static func fields(in data: Data) throws -> [(Int, Data)] {
        var offset = 0
        var result: [(Int, Data)] = []
        while offset < data.count {
            guard let (tag, tagEnd) = readVarint(data, at: offset) else {
                throw GrokResetCreditsRPC.Error.invalidResponse
            }
            offset = tagEnd
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            switch wire {
            case 0:
                guard let (_, next) = readVarint(data, at: offset) else {
                    throw GrokResetCreditsRPC.Error.invalidResponse
                }
                let raw = data.subdata(in: tagEnd..<next)
                result.append((field, raw))
                offset = next
            case 1:
                guard offset + 8 <= data.count else { throw GrokResetCreditsRPC.Error.invalidResponse }
                offset += 8
            case 2:
                guard let (length, lenEnd) = readVarint(data, at: offset),
                      lenEnd + Int(length) <= data.count else {
                    throw GrokResetCreditsRPC.Error.invalidResponse
                }
                result.append((field, data.subdata(in: lenEnd..<(lenEnd + Int(length)))))
                offset = lenEnd + Int(length)
            case 5:
                guard offset + 4 <= data.count else { throw GrokResetCreditsRPC.Error.invalidResponse }
                offset += 4
            default:
                throw GrokResetCreditsRPC.Error.invalidResponse
            }
        }
        return result
    }

    private static func varint(_ data: Data) -> UInt64? {
        readVarint(data, at: 0)?.value
    }

    private static func readVarint(_ data: Data, at start: Int) -> (value: UInt64, end: Int)? {
        var value: UInt64 = 0
        var shift = 0
        var index = start
        while index < data.count {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return (value, index) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
