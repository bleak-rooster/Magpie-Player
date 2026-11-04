import Foundation
import os
import Testing
@testable import MagpieCore

/// Round 14 security S14 M1 (D115): a keyed call can ask for its answer to be capped. The transport reads the body as it
/// arrives, refuses it at once when the headers already say it is bigger, and stops reading past the cap; the redirect
/// rules (`SameOriginRedirects`) still hold on that path.
@Suite(.serialized) struct CappedResponseTests {
    func transport() -> URLSessionTransport {
        URLSessionTransport(session: URLSession(configuration: BigBodyStub.configuration()))
    }

    func request(_ path: String) -> URLRequest {
        // Into BigBodyStub only (never sent anywhere else).
        var request = URLRequest(url: URL(string: "https://aurral.example\(path)")!)
        request.setValue("Bearer SECRET", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test func smallAnswerIsReturnedWhole() async throws {
        BigBodyStub.reset()
        let (data, response) = try await transport().send(request("/body?bytes=1000&chunk=100"), maxBytes: 4_096)
        #expect(response.statusCode == 200)
        #expect(data.count == 1_000)
    }

    @Test func answerAtTheCapIsReturned() async throws {
        BigBodyStub.reset()
        let (data, _) = try await transport().send(request("/body?bytes=4096&chunk=512"), maxBytes: 4_096)
        #expect(data.count == 4_096)
    }

    /// No Content-Length: the body streams past the cap and the read stops there.
    @Test func streamedAnswerPastTheCapIsRefused() async throws {
        BigBodyStub.reset()
        await #expect(throws: ResponseTooLarge.self) {
            _ = try await transport().send(request("/body?bytes=200000&chunk=8192"), maxBytes: 64 * 1024)
        }
        #expect(BigBodyStub.chunksSent < 200_000 / 8_192, "the read stopped early (\(BigBodyStub.chunksSent) chunks)")
    }

    /// A Content-Length over the cap is refused before any of the body is read.
    @Test func declaredLengthOverTheCapIsRefusedAtOnce() async throws {
        BigBodyStub.reset()
        await #expect(throws: ResponseTooLarge.self) {
            _ = try await transport().send(request("/body?bytes=200000&chunk=8192&declare=1"), maxBytes: 64 * 1024)
        }
        #expect(BigBodyStub.chunksSent <= 1)
    }

    /// The capped path keeps the redirect rules: a keyed GET is never redirected, even on the same origin.
    @Test func cappedKeyedGetIsNotRedirected() async throws {
        BigBodyStub.reset()
        let to = "https://aurral.example/api/auth/api-key"
        let request = request("/redirect?to=\(to)")
        _ = try? await transport().send(request, maxBytes: 4_096)
        #expect(BigBodyStub.landedPaths.isEmpty, "landed at \(BigBodyStub.landedPaths)")
    }

    /// A plain same-origin GET is still followed on the capped path, and its answer capped.
    @Test func cappedPlainGetFollowsSameOrigin() async throws {
        BigBodyStub.reset()
        var request = URLRequest(url: URL(string: "https://music.example/redirect?to=https://music.example/landed")!)
        request.httpMethod = "GET"
        let (data, response) = try await transport().send(request, maxBytes: 4_096)
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "landed")
    }

    /// Any transport without its own capped read still refuses an oversized answer (checked once read).
    @Test func defaultCappedSendChecksTheSize() async throws {
        struct Fixed: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                (Data(count: 5_000), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let request = URLRequest(url: URL(string: "https://aurral.example/x")!)   // never sent: Fixed answers itself
        await #expect(throws: ResponseTooLarge.self) { _ = try await Fixed().send(request, maxBytes: 4_096) }
        let (data, _) = try await Fixed().send(request, maxBytes: 5_000)
        #expect(data.count == 5_000)
    }

    @Test func cancelledCallSendsNothing() async throws {
        BigBodyStub.reset()
        let transport = transport()
        let request = request("/body?bytes=10&chunk=10")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(request, maxBytes: 4_096)
        }
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(BigBodyStub.landedPaths.isEmpty)
    }
}

/// `/body?bytes=&chunk=&declare=`: that many bytes in chunks (with a Content-Length when `declare`); `/redirect?to=`: a
/// 302 there; anything else 200 "landed", recording the path.
final class BigBodyStub: URLProtocol, @unchecked Sendable {
    private static let state = OSAllocatedUnfairLock(initialState: (chunks: 0, paths: [String]()))
    static var chunksSent: Int { state.withLock { $0.chunks } }
    static var landedPaths: [String] { state.withLock { $0.paths } }
    static func reset() { state.withLock { $0 = (0, []) } }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionTransport.defaultConfiguration()
        config.protocolClasses = [BigBodyStub.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    override func stopLoading() { stopped.withLock { $0 = true } }

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if url.path == "/redirect", let to = value("to").flatMap(URL.init(string:)) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": to.absoluteString])!
            var next = request
            next.url = to
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if url.path == "/body" {
            let total = value("bytes").flatMap(Int.init) ?? 0
            let chunk = max(1, value("chunk").flatMap(Int.init) ?? total)
            var headers = ["Content-Type": "application/json"]
            if value("declare") != nil { headers["Content-Length"] = "\(total)" }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Off the loading thread, so a cancel (stopLoading) gets through while the body streams.
            DispatchQueue.global().async { [self] in
                var sent = 0
                while sent < total, !stopped.withLock({ $0 }) {
                    let n = min(chunk, total - sent)
                    client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: n))
                    Self.state.withLock { $0.chunks += 1 }
                    sent += n
                    Thread.sleep(forTimeInterval: 0.002)
                }
                if !stopped.withLock({ $0 }) { client?.urlProtocolDidFinishLoading(self) }
            }
            return
        }
        Self.state.withLock { $0.paths.append(url.path) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("landed".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
