import Foundation
import MeterBarShared

/// Pure request handling for `meterbar serve`: authenticates, routes, and
/// builds responses from the same DTOs `meterbar usage --json` / `cost --json`
/// already emit. Deliberately has no socket code so it can be unit-tested
/// directly against `ServeHTTPRequest` values.
nonisolated public enum ServeRouter {
    /// Reads MeterBar's existing cached snapshots. Never triggers a provider
    /// refresh — serving must not be able to amplify into a request storm
    /// under polling (docs/cli-json-schema.md).
    public struct DataSource: Sendable {
        public let loadUsageMetrics: @Sendable () -> [ServiceType: UsageMetrics]
        public let loadCostCache: @Sendable () -> CostSummaryCache?

        public init(
            loadUsageMetrics: @escaping @Sendable () -> [ServiceType: UsageMetrics],
            loadCostCache: @escaping @Sendable () -> CostSummaryCache?
        ) {
            self.loadUsageMetrics = loadUsageMetrics
            self.loadCostCache = loadCostCache
        }

        public static let liveCache = DataSource(
            loadUsageMetrics: { SharedDataStore.shared.loadMetrics() },
            loadCostCache: { CostSummaryStore.load() }
        )
    }

    /// Auth is checked before routing so an unauthenticated caller can't use
    /// the status code to learn which paths exist or which methods they take.
    public static func handle(_ request: ServeHTTPRequest, token: String, dataSource: DataSource) -> ServeHTTPResponse {
        guard ServeToken.matches(presented: request.authorizationHeader, expected: token) else {
            return unauthorizedResponse()
        }

        switch request.path {
        case "/usage":
            guard request.method == "GET" else { return methodNotAllowedResponse() }
            return usageResponse(dataSource: dataSource, query: request.query)
        case "/cost":
            guard request.method == "GET" else { return methodNotAllowedResponse() }
            return costResponse(dataSource: dataSource, query: request.query)
        default:
            return notFoundResponse()
        }
    }

    public static func tooManyRequestsResponse() -> ServeHTTPResponse {
        errorResponse(status: 429, code: "too_many_requests", message: "Rate limit exceeded.")
    }

    public static func malformedRequestResponse() -> ServeHTTPResponse {
        errorResponse(status: 400, code: "bad_request", message: "Malformed HTTP request.")
    }

    // MARK: Endpoints

    private static func usageResponse(dataSource: DataSource, query: [String: String]) -> ServeHTTPResponse {
        let metrics = dataSource.loadUsageMetrics()
        guard !metrics.isEmpty else {
            return errorResponse(
                code: "usage_cache_missing",
                message: "No cached metrics found. Open MeterBar app to fetch data."
            )
        }

        let filtered: [ServiceType: UsageMetrics]
        if let provider = query["provider"]?.lowercased(), !provider.isEmpty {
            filtered = metrics.filter {
                $0.key.rawValue.lowercased().contains(provider)
                    || $0.key.displayName.lowercased().contains(provider)
            }
        } else {
            filtered = metrics
        }

        return jsonResponse(UsageCLIJSONResponse(metrics: filtered))
    }

    private static func costResponse(dataSource: DataSource, query: [String: String]) -> ServeHTTPResponse {
        guard let cache = dataSource.loadCostCache() else {
            return errorResponse(
                code: "cost_cache_missing",
                message: "No cost data cached. Open MeterBar and run a scan (Costs tab)."
            )
        }

        // Mirrors `meterbar cost --days`: an invalid or non-positive value is
        // ignored rather than rejected, falling back to the full cached summary.
        let days = query["days"].flatMap(Int.init).flatMap { $0 >= 1 ? $0 : nil }
        return jsonResponse(CostCLIJSONResponse(cache: cache, days: days))
    }

    // MARK: Response construction

    private static let staticEncodingFailureBody = """
    {"schemaVersion":1,"error":{"code":"internal_error","message":"Failed to encode the error payload."}}
    """

    /// An encoding failure must not surface as an empty body labelled
    /// `200 OK` / `application/json` — a client would read that as success it
    /// merely failed to parse, rather than as the server-side fault it is.
    /// Internal rather than private so tests can drive the failure path.
    static func jsonResponse(_ document: some CLIJSONDocument) -> ServeHTTPResponse {
        guard let body = try? document.jsonData() else {
            return errorResponse(
                status: 500,
                code: "internal_error",
                message: "Failed to encode the response payload."
            )
        }

        return ServeHTTPResponse(
            status: 200,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
            ],
            body: body
        )
    }

    private static func unauthorizedResponse() -> ServeHTTPResponse {
        errorResponse(status: 401, code: "unauthorized", message: "Missing or invalid bearer token.")
    }

    private static func notFoundResponse() -> ServeHTTPResponse {
        errorResponse(status: 404, code: "not_found", message: "Unknown path.")
    }

    private static func methodNotAllowedResponse() -> ServeHTTPResponse {
        errorResponse(status: 405, code: "method_not_allowed", message: "Only GET is supported.")
    }

    /// The last stop for every failure path, so its own fallback is a literal
    /// rather than an empty body: a caller must always get something it can
    /// parse, even if encoding the real detail failed.
    private static func errorResponse(status: Int = 200, code: String, message: String) -> ServeHTTPResponse {
        let body = (try? CLIJSONErrorResponse(code: code, message: message).jsonData())
            ?? Data(Self.staticEncodingFailureBody.utf8)
        return ServeHTTPResponse(
            status: status,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
            ],
            body: body
        )
    }
}
