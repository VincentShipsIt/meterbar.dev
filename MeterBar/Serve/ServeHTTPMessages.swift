import Foundation

/// A parsed HTTP request, decoupled from the socket it arrived on so routing
/// logic (`ServeRouter`) can be unit-tested without a real listener.
nonisolated public struct ServeHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let authorizationHeader: String?

    public init(method: String, path: String, query: [String: String] = [:], authorizationHeader: String? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.authorizationHeader = authorizationHeader
    }
}

/// A rendered HTTP response, independent of how it gets serialized onto the
/// wire — `ServeHTTPServer` turns this into an HTTP/1.1 status line + headers.
nonisolated public struct ServeHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}
