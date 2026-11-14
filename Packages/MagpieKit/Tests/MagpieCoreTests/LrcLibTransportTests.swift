import Foundation
import Network
import os
import Testing
@testable import MagpieCore

/// A one-request-at-a-time HTTP server on 127.0.0.1 (a port the system picks): records each request's head and answers
/// with what `respond` gives for its path. Only for these tests; nothing leaves the machine.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let heads = OSAllocatedUnfairLock(initialState: [String]())
    private let queue = DispatchQueue(label: "LoopbackServer")
    private(set) var port: UInt16 = 0

    var requests: [String] { heads.withLock { $0 } }

    init(respond: @escaping @Sendable (String) -> String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [heads, queue] connection in
            connection.start(queue: queue)
            Self.read(connection, buffer: Data()) { head in
                heads.withLock { $0.append(head) }
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                connection.send(content: Data(respond(path).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private static func read(_ c: NWConnection, buffer: Data, done: @escaping @Sendable (String) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let text = String(data: buffer, encoding: .utf8), let end = text.range(of: "\r\n\r\n") {
                done(String(text[..<end.lowerBound]))
            } else if !complete, error == nil {
                read(c, buffer: buffer, done: done)
            } else {
                c.cancel()
            }
        }
    }

    func start() async throws {
        let listener = self.listener
        let ready = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if ready.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume() }
                case .failed(let error):
                    if ready.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
}

/// L fix round 1 (security LL1, LL2): LRCLIB's own transport never follows a redirect (not even within its origin), keeps
/// no cookies, and what goes on the wire is the request's two headers plus URLSession's own fixed ones.
@Suite(.serialized) struct LrcLibTransportTests {
    static func answer(_ status: String, _ headers: [String] = [], body: String = "") -> String {
        (["HTTP/1.1 \(status)", "Content-Length: \(body.utf8.count)", "Connection: close"] + headers)
            .joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    @Test func lrclib_redirectIsNotFollowed() async throws {
        let server = try LoopbackServer { path in
            path.hasPrefix("/api/get") ? Self.answer("302 Found", ["Location: /api/search?q=x"])
                                       : Self.answer("200 OK", body: #"{"plainLyrics":"followed"}"#)
        }
        try await server.start()
        defer { server.stop() }
        var request = try #require(LrcLib.request(title: "A", artist: "B", album: nil, duration: nil, userAgent: "Magpie/1"))
        request.url = URL(string: "\(server.base.absoluteString)/api/get?track_name=A&artist_name=B")
        let (_, response) = try await LrcLibTransport().send(request, maxBytes: LrcLib.maxResponseBytes)
        #expect(response.statusCode == 302, "the 3xx comes back; nothing follows it")
        #expect(server.requests.count == 1 && server.requests.allSatisfy { $0.hasPrefix("GET /api/get") })
    }

    @Test func lrclib_wireHeadersAreOnlyTheFixedOnes() async throws {
        let server = try LoopbackServer { _ in Self.answer("404 Not Found", ["Set-Cookie: id=1"]) }
        try await server.start()
        defer { server.stop() }
        var request = try #require(LrcLib.request(title: "A", artist: "B", album: "C", duration: 200, userAgent: "Magpie/1"))
        request.url = URL(string: "\(server.base.absoluteString)/api/get?track_name=A")
        for _ in 0..<2 { _ = try await LrcLibTransport().send(request, maxBytes: LrcLib.maxResponseBytes) }
        #expect(server.requests.count == 2)
        for head in server.requests {
            var fields: [String: String] = [:]
            for line in head.split(separator: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            #expect(Set(fields.keys).isSubset(of: ["host", "user-agent", "accept-language", "accept", "accept-encoding",
                                                   "connection"]), "\(fields.keys.sorted())")
            #expect(fields["user-agent"] == "Magpie/1" && fields["accept-language"] == "en")
            #expect(fields["cookie"] == nil && fields["authorization"] == nil, "a cookie set before is never sent back")
        }
    }

    @Test func lrclib_bodyCappedOnTheWire() async throws {
        let big = String(repeating: "x", count: 600 * 1024)
        let server = try LoopbackServer { _ in Self.answer("200 OK", body: big) }
        try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: server.base.appending(path: "api/get"))
        request.httpMethod = "GET"
        await #expect(throws: ResponseTooLarge.self) {
            _ = try await LrcLibTransport().send(request, maxBytes: LrcLib.maxResponseBytes)
        }
    }
}
