import Foundation
import MagpieCore
import os

/// Route-table transport for tests. Routes match on HTTP method and URL path suffix; first match wins.
/// Unmatched requests get a 404. All requests are recorded.
public final class MockTransport: HTTPTransport {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        public var headers: [String: String]

        public init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status; self.body = body; self.headers = headers
        }
    }

    private struct Route: Sendable {
        var method: String
        var pathSuffix: String
        var respond: @Sendable (URLRequest) throws -> Response
    }

    private struct State {
        var routes: [Route] = []
        var requests: [URLRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var requests: [URLRequest] { state.withLock { $0.requests } }

    public func stub(method: String = "GET", pathSuffix: String, status: Int = 200,
                     body: Data = Data(), headers: [String: String] = [:]) {
        stub(method: method, pathSuffix: pathSuffix) { _ in Response(status: status, body: body, headers: headers) }
    }

    public func stub(method: String = "GET", pathSuffix: String,
                     handler: @escaping @Sendable (URLRequest) throws -> Response) {
        state.withLock { $0.routes.append(Route(method: method, pathSuffix: pathSuffix, respond: handler)) }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let route = state.withLock { s -> Route? in
            s.requests.append(request)
            return s.routes.first { $0.method == method && path.hasSuffix($0.pathSuffix) }
        }
        let response = try route?.respond(request) ?? Response(status: 404, body: Data(), headers: [:])
        let http = HTTPURLResponse(url: request.url ?? URL(string: "about:blank")!, statusCode: response.status,
                                   httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response.body, http)
    }
}
