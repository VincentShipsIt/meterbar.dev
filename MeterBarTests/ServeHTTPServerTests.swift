import Darwin
import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class ServeHTTPServerTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let token = "integration-test-token"

    private func makeDataSource() -> ServeRouter.DataSource {
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil, windowSeconds: 18_000),
                weeklyLimit: nil,
                extraUsage: nil,
                lastUpdated: referenceDate
            ),
        ]
        return ServeRouter.DataSource(
            loadUsageMetrics: { metrics },
            loadCostCache: { nil }
        )
    }

    private func startServer(maxRequestsPerSecond: Int = 100) throws -> ServeHTTPServer {
        let server = ServeHTTPServer(configuration: ServeHTTPServer.Configuration(
            host: ServeBindConfiguration.loopbackHost,
            port: 0,
            token: token,
            maxRequestsPerSecond: maxRequestsPerSecond,
            dataSource: makeDataSource()
        ))
        try server.start()
        server.runAcceptLoop()
        return server
    }

    private func get(
        _ path: String,
        port: UInt16,
        bearerToken: String?,
        method: String = "GET"
    ) async throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }

    func testServerBindsToLoopbackAndServesAnAuthenticatedUsageRequest() async throws {
        let server = try startServer()
        defer { server.stop() }

        let (response, data) = try await get("/usage", port: server.boundPort, bearerToken: token)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }

    func testServerRejectsMissingTokenWithoutLeakingData() async throws {
        let server = try startServer()
        defer { server.stop() }

        let (response, data) = try await get("/usage", port: server.boundPort, bearerToken: nil)

        XCTAssertEqual(response.statusCode, 401)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(body.contains("providers"))
    }

    func testServerRejectsNonGetMethod() async throws {
        let server = try startServer()
        defer { server.stop() }

        let (response, _) = try await get("/usage", port: server.boundPort, bearerToken: token, method: "POST")

        XCTAssertEqual(response.statusCode, 405)
    }

    func testServerRejectsUnknownPath() async throws {
        let server = try startServer()
        defer { server.stop() }

        let (response, _) = try await get("/does-not-exist", port: server.boundPort, bearerToken: token)

        XCTAssertEqual(response.statusCode, 404)
    }

    func testServerEnforcesRateLimit() async throws {
        let server = try startServer(maxRequestsPerSecond: 1)
        defer { server.stop() }

        _ = try await get("/usage", port: server.boundPort, bearerToken: token)
        let (second, _) = try await get("/usage", port: server.boundPort, bearerToken: token)

        XCTAssertEqual(second.statusCode, 429)
    }

    func testStopClosesTheListeningSocketSoNewConnectionsAreRefused() async throws {
        let server = try startServer()
        let port = server.boundPort

        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)

        do {
            _ = try await get("/usage", port: port, bearerToken: token)
            XCTFail("expected the connection to be refused after stop()")
        } catch {
            // Connection refused (or similar) is expected; the listening socket is gone.
        }
    }

    func testStartingOnAnAlreadyBoundPortFails() throws {
        let first = try startServer()
        defer { first.stop() }

        let second = ServeHTTPServer(configuration: ServeHTTPServer.Configuration(
            host: ServeBindConfiguration.loopbackHost,
            port: first.boundPort,
            token: token,
            maxRequestsPerSecond: 10,
            dataSource: makeDataSource()
        ))

        XCTAssertThrowsError(try second.start())
    }
}
