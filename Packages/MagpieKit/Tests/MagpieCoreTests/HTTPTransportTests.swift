import Foundation
import os
import Testing
@testable import MagpieCore

@Suite(.serialized) struct HTTPTransportTests {
    /// Subsonic auth lives in the query string (`u`, `t`, `s`), so requests must never reach the
    /// on-disk URLCache.
    @Test func defaultConfigurationHasNoURLCache() {
        let config = URLSessionTransport.defaultConfiguration()
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func defaultTransportUsesEphemeralSessionWithoutCache() {
        let config = URLSessionTransport().sessionConfiguration
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(config.identifier == nil)
    }

    // MARK: - Security M1: redirects stay within the original origin

    @Test func redirectPolicyComparesOrigins() {
        func ok(_ a: String, _ b: String) -> Bool { SameOriginRedirects.allows(from: URL(string: a), to: URL(string: b)) }
        #expect(ok("https://music.example/navidrome/rest/ping", "https://music.example/navidrome/rest/ping/"))
        #expect(ok("https://music.example/a", "https://MUSIC.example:443/b"))
        #expect(ok("http://192.168.1.20:8686/api/v1/artist", "http://192.168.1.20:8686/lidarr/api/v1/artist"))
        #expect(!ok("https://music.example/a", "http://music.example/a"), "https to http downgrade")
        #expect(!ok("http://music.example/a", "https://music.example/a"), "another origin, even if upgraded")
        #expect(!ok("https://music.example/a", "https://evil.example/a"))
        #expect(!ok("https://music.example/a", "https://music.example.evil.example/a"))
        #expect(!ok("http://192.168.1.20:4533/a", "http://192.168.1.20:8686/a"), "another port")
        #expect(!ok("https://music.example/a", "https://user:pw@evil.example/a"))
        #expect(!SameOriginRedirects.allows(from: URL(string: "https://music.example/a"), to: nil))
    }

    /// The transport (any session passed in) and the policy session refuse a cross-origin 302/307: the key
    /// header and the login body never reach the other host. A same-origin redirect is still followed.
    @Test(arguments: [302, 307])
    func crossOriginRedirectIsNotFollowed(_ status: Int) async throws {
        RedirectStub.reset()
        let transport = URLSessionTransport(session: URLSession(configuration: RedirectStub.configuration()))
        var request = URLRequest(url: URL(string: "https://music.example/redirect?status=\(status)&to=https://evil.example/landed")!)
        request.httpMethod = "POST"
        request.setValue("SECRETKEY", forHTTPHeaderField: "X-Api-Key")
        request.httpBody = Data(#"{"username":"u","password":"PLAINPW"}"#.utf8)
        do {
            let (_, response) = try await transport.send(request)
            #expect((300..<400).contains(response.statusCode), "the refused redirect is the answer")
        } catch {
            // A refused redirect may also surface as an error; either way nothing reached the other host.
        }
        #expect(RedirectStub.landedHosts.isEmpty, "landed at \(RedirectStub.landedHosts)")
    }

    @Test func downgradeRedirectIsNotFollowed() async throws {
        RedirectStub.reset()
        let session = SameOriginRedirects.session(configuration: RedirectStub.configuration())
        let url = URL(string: "https://music.example/redirect?status=302&to=http://music.example/landed")!
        _ = try? await session.data(from: url)
        #expect(RedirectStub.landedHosts.isEmpty)
    }

    @Test func sameOriginRedirectIsFollowed() async throws {
        RedirectStub.reset()
        let transport = URLSessionTransport(session: URLSession(configuration: RedirectStub.configuration()))
        let url = URL(string: "https://music.example/redirect?status=302&to=https://music.example/landed")!
        let (data, response) = try await transport.send(URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "landed")
        #expect(RedirectStub.landedHosts == ["music.example"])
    }
}

/// Answers `/redirect?status=&to=` with that redirect (carrying the original headers and body over, as
/// URLSession does) and anything else with 200 "landed", recording the host it landed on.
final class RedirectStub: URLProtocol, @unchecked Sendable {
    private static let landed = OSAllocatedUnfairLock(initialState: [String]())
    static var landedHosts: [String] { landed.withLock { $0 } }
    static func reset() { landed.withLock { $0 = [] } }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionTransport.defaultConfiguration()
        config.protocolClasses = [RedirectStub.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.path == "/redirect", let to = query.first(where: { $0.name == "to" })?.value.flatMap(URL.init(string:)) {
            let status = query.first { $0.name == "status" }?.value.flatMap(Int.init) ?? 302
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": to.absoluteString])!
            var next = request
            next.url = to
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        Self.landed.withLock { $0.append(url.host() ?? "") }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("landed".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
