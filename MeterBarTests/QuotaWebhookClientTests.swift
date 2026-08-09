import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class QuotaWebhookClientTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testURLPolicyAllowsPublicHTTPSAndRejectsLocalOrCredentialBearingTargets() {
        XCTAssertNotNil(QuotaWebhookURLPolicy.validatedURL("https://hooks.example.com/meterbar"))
        XCTAssertFalse(QuotaWebhookURLPolicy.hostResolvesOnlyToPublicAddresses("127.0.0.1"))
        XCTAssertFalse(QuotaWebhookURLPolicy.hostResolvesOnlyToPublicAddresses("::1"))

        let rejected = [
            "http://hooks.example.com/meterbar",
            "file:///tmp/secret",
            "https://user:password@hooks.example.com/meterbar",
            "https://hooks.example.com:8443/meterbar",
            "https://hooks.example.com/meterbar#fragment",
            "https://localhost/meterbar",
            "https://service.local/meterbar",
            "https://127.0.0.1/meterbar",
            "https://10.0.0.1/meterbar",
            "https://172.16.0.1/meterbar",
            "https://192.168.1.1/meterbar",
            "https://169.254.169.254/latest/meta-data",
            "https://[::1]/meterbar",
            "https://[fd00::1]/meterbar",
            "https://[fe80::1]/meterbar",
        ]

        for value in rejected {
            XCTAssertNil(QuotaWebhookURLPolicy.validatedURL(value), value)
        }
    }

    func testUnsafeAddressLiteralClassification() {
        let unsafeAddresses = [
            "127.0.0.1",
            "10.0.0.1",
            "172.16.0.1",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "::1",
            "fd00::1",
            "fe80::1%en0",
            "[::1]",
            "127.0.0.1:443",
            "[::1]:443",
            "::ffff:127.0.0.1",
        ]
        let safeOrUnknownAddresses = [
            "93.184.216.34",
            "2606:2800:220:1:248:1893:25c8:1946",
            "garbage",
            "",
        ]

        for address in unsafeAddresses {
            XCTAssertTrue(QuotaWebhookURLPolicy.isUnsafeAddressLiteral(address), address)
        }
        for address in safeOrUnknownAddresses {
            XCTAssertFalse(QuotaWebhookURLPolicy.isUnsafeAddressLiteral(address), address)
        }
    }

    func testPostsOnlyTheVersionedMinimalJSONContractWithoutSecrets() async throws {
        let client = makeClient()
        let url = try XCTUnwrap(QuotaWebhookURLPolicy.validatedURL("https://hooks.example.com/meterbar"))
        let payload = QuotaEventPayload(
            provider: .codexCli,
            account: QuotaEventAccount(id: "account-id", name: "Work"),
            event: .exhausted,
            window: .weekly,
            percentage: 100,
            band: .exhausted,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url, url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(
                Set(object.keys),
                ["schema_version", "provider", "account", "event", "window", "percentage", "band", "timestamp"]
            )
            XCTAssertEqual(object["schema_version"] as? Int, 1)
            XCTAssertEqual(object["provider"] as? String, ServiceType.codexCli.rawValue)
            XCTAssertEqual(object["event"] as? String, "exhausted")
            XCTAssertEqual(object["window"] as? String, "weekly")
            XCTAssertEqual(object["band"] as? String, "exhausted")
            let account = try XCTUnwrap(object["account"] as? [String: Any])
            XCTAssertEqual(Set(account.keys), ["id", "name"])
            XCTAssertFalse(String(decoding: body, as: UTF8.self).localizedCaseInsensitiveContains("token"))
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("configDirectory"))
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("homeDirectory"))

            return (
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)),
                Data()
            )
        }

        let result = await client.post(payload: payload, to: url)
        XCTAssertEqual(result, .succeeded)
    }

    func testTransportAndHTTPFailuresReturnSafeNonfatalResultsWithoutResponseBodies() async throws {
        let client = makeClient()
        let url = try XCTUnwrap(QuotaWebhookURLPolicy.validatedURL("https://hooks.example.com/meterbar"))
        let payload = makePayload()

        StubURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let timeout = await client.post(payload: payload, to: url)
        XCTAssertEqual(timeout, .failed("Webhook request timed out."))

        StubURLProtocol.handler = { _ in
            (
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)),
                Data("secret response body".utf8)
            )
        }
        let serverError = await client.post(payload: payload, to: url)
        XCTAssertEqual(serverError, .failed("Webhook returned HTTP 500."))
    }

    func testDNSResolutionToPrivateSpaceIsRejectedBeforeTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = QuotaWebhookClient(
            configuration: configuration,
            timeout: 0.1,
            hostIsPublic: { _ in false }
        )
        StubURLProtocol.handler = { _ in
            XCTFail("Transport must not start after private DNS resolution.")
            throw URLError(.badURL)
        }
        let url = try XCTUnwrap(QuotaWebhookURLPolicy.validatedURL("https://hooks.example.com/meterbar"))

        let result = await client.post(payload: makePayload(), to: url)

        XCTAssertEqual(result, .failed("Webhook host is not public."))
    }

    func testTransportRevalidatesURLPolicyBeforeStartingRequest() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in
            XCTFail("Transport must not start for a URL outside the public HTTPS policy.")
            throw URLError(.badURL)
        }

        let result = await client.post(
            payload: makePayload(),
            to: try XCTUnwrap(URL(string: "http://hooks.example.com/meterbar"))
        )

        XCTAssertEqual(result, .failed("Webhook URL is not allowed."))
    }

    func testPrivateObservedRemoteAddressOverridesSuccessfulHTTPResponseAndIsConsumed() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let connectionDelegate = QuotaWebhookConnectionDelegate()
        let client = QuotaWebhookClient(
            configuration: configuration,
            timeout: 0.1,
            hostIsPublic: { _ in true },
            connectionDelegate: connectionDelegate,
            taskCreatedForTesting: { task in
                connectionDelegate.recordRemoteAddress(
                    "127.0.0.1",
                    forTaskIdentifier: task.taskIdentifier
                )
            }
        )
        let url = try XCTUnwrap(QuotaWebhookURLPolicy.validatedURL("https://hooks.example.com/meterbar"))
        StubURLProtocol.handler = { _ in
            (
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)),
                Data()
            )
        }

        let result = await client.post(payload: makePayload(), to: url)

        XCTAssertEqual(result, .failed("Webhook connected to a non-public address."))
        XCTAssertEqual(connectionDelegate.observedAddressCount, 0)
    }

    private func makeClient() -> QuotaWebhookClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return QuotaWebhookClient(
            configuration: configuration,
            timeout: 0.1,
            hostIsPublic: { _ in true }
        )
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                return nil
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private func makePayload() -> QuotaEventPayload {
        QuotaEventPayload(
            provider: .cursor,
            account: QuotaEventAccount(id: "default", name: "Cursor"),
            event: .warning,
            window: .session,
            percentage: 76,
            band: .tight,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
