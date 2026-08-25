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

    /// Redeem the named reset token. Live-probed 2026-08-13: this method is
    /// implemented. A fake token id returns HTTP 200 + `grpc-status: 9`
    /// (FAILED_PRECONDITION) on the response header with an empty body and
    /// does not spend a real reset.
    static let redeemResetURL = URL(
        string: "https://grok.com/prod_mc_billing.ConsumerUiSvc/RedeemReset"
    )!

    /// Empty protobuf framed as one uncompressed grpc-web data frame.
    static let emptyRequest = Data([0x00, 0x00, 0x00, 0x00, 0x00])

    static func fetchSnapshot(
        accessToken: String,
        session: URLSession = ServiceSupport.session,
        now: Date = Date()
    ) async throws -> GrokResetCredits.Snapshot {
        let (data, _) = try await post(
            url: remainingResetsURL,
            accessToken: accessToken,
            body: emptyRequest,
            session: session
        )
        return try GrokResetCredits.decode(grpcWeb: data, now: now)
    }

    static func fetchAvailableCount(
        accessToken: String,
        session: URLSession = ServiceSupport.session,
        now: Date = Date()
    ) async throws -> Int {
        try await fetchSnapshot(accessToken: accessToken, session: session, now: now).availableCount
    }

    static func consume(
        tokenID: String,
        accessToken: String,
        session: URLSession = ServiceSupport.session
    ) async throws {
        let (data, http) = try await post(
            url: redeemResetURL,
            accessToken: accessToken,
            body: GrpcWeb.frame(Proto.encodeTokenID(tokenID)),
            session: session
        )
        // Live RedeemReset puts grpc-status on the HTTP header and may send
        // an empty body. A missing trailer is not success.
        guard GrpcWeb.status(body: data, headers: http.allHeaderFields) == 0 else {
            throw Error.requestFailed
        }
    }

    /// Test seam: production callers go through `consume`.
    static func encodeTokenIDForTesting(_ tokenID: String) -> Data {
        GrpcWeb.frame(Proto.encodeTokenID(tokenID))
    }

    static func grpcStatusForTesting(_ data: Data, headers: [AnyHashable: Any] = [:]) -> Int? {
        GrpcWeb.status(body: data, headers: headers)
    }

    static func consumeSucceededForTesting(_ data: Data, headers: [AnyHashable: Any]) -> Bool {
        GrpcWeb.status(body: data, headers: headers) == 0
    }

    private static func post(
        url: URL,
        accessToken: String,
        body: Data,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.httpBody = body

        let (data, response) = try await ServiceSupport.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.requestFailed
        }
        return (data, http)
    }
}

// MARK: - grpc-web + proto

/// grpc-web: 1 flag byte + 4-byte big-endian length + payload. The high bit on
/// the flag marks a trailer frame (`grpc-status: 0`), which we skip for the
/// message and read for the status code.
private enum GrpcWeb {
    static func frame(_ message: Data) -> Data {
        var framed = Data([0x00])
        var length = UInt32(message.count).bigEndian
        withUnsafeBytes(of: length) { framed.append(contentsOf: $0) }
        framed.append(message)
        return framed
    }

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

    static func status(body: Data, headers: [AnyHashable: Any]) -> Int? {
        status(in: body) ?? headerStatus(headers)
    }

    static func status(in data: Data) -> Int? {
        var offset = 0
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
            guard flags & 0x80 != 0,
                  let text = String(data: payload, encoding: .utf8) else {
                continue
            }
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == "grpc-status",
                      let code = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                    continue
                }
                return code
            }
        }
        return nil
    }

    /// grpc-web may put `grpc-status` on the HTTP response when the body has
    /// no trailer frame. Header names are compared case-insensitively.
    private static func headerStatus(_ headers: [AnyHashable: Any]) -> Int? {
        for (key, value) in headers {
            guard String(describing: key).caseInsensitiveCompare("grpc-status") == .orderedSame else {
                continue
            }
            if let code = value as? Int { return code }
            if let text = value as? String {
                return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let text = value as? NSString {
                return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
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

    /// `ConsumerRedeemResetReq { string token_id = 10; }` framed by the caller.
    static func encodeTokenID(_ tokenID: String) -> Data {
        let utf8 = Data(tokenID.utf8)
        var payload = encodeVarint(UInt64((tokenIDField << 3) | 2))
        payload.append(encodeVarint(UInt64(utf8.count)))
        payload.append(utf8)
        return payload
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

    private static func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
        return data
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
