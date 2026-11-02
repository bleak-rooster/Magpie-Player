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

    // MARK: - Round 12 security M1: no redirect for writes or keyed requests, even on the same origin

    /// The gate's allowed `DELETE /api/v1/queue/7` answered with a same-origin 307 to
    /// `/api/v1/artist/5?deleteFiles=true` must never be followed as that DELETE.
    @Test(arguments: [301, 302, 307, 308])
    func sameOriginRedirectOfKeyedDeleteIsRefused(_ status: Int) async throws {
        RedirectStub.reset()
        let transport = URLSessionTransport(session: URLSession(configuration: RedirectStub.configuration()))
        let to = "https://lidarr.example/api/v1/artist/5?deleteFiles=true"
        var components = URLComponents(string: "https://lidarr.example/redirect")!
        components.queryItems = [URLQueryItem(name: "status", value: "\(status)"), URLQueryItem(name: "to", value: to)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        request.setValue("SECRETKEY", forHTTPHeaderField: "X-Api-Key")
        _ = try? await transport.send(request)
        #expect(RedirectStub.landedPaths.isEmpty, "landed at \(RedirectStub.landedPaths)")
    }

    /// Any non-GET is refused even with no key (the login POST, a PUT, a POST to Aurral).
    @Test(arguments: ["POST", "PUT", "DELETE", "PATCH"])
    func sameOriginRedirectOfNonGetIsRefused(_ method: String) async throws {
        RedirectStub.reset()
        let transport = URLSessionTransport(session: URLSession(configuration: RedirectStub.configuration()))
        var request = URLRequest(url: URL(string: "https://music.example/redirect?status=307&to=https://music.example/api/settings")!)
        request.httpMethod = method
        _ = try? await transport.send(request)
        #expect(RedirectStub.landedPaths.isEmpty, "\(method) landed at \(RedirectStub.landedPaths)")
    }

    /// A GET carrying a key or an auth header is not followed either (Lidarr, Aurral, Navidrome native,
    /// ListenBrainz): its target never went through the gate or the allow-list.
    @Test(arguments: ["X-Api-Key", "X-ND-Authorization", "Authorization"])
    func sameOriginRedirectOfKeyedGetIsRefused(_ header: String) async throws {
        RedirectStub.reset()
        let transport = URLSessionTransport(session: URLSession(configuration: RedirectStub.configuration()))
        var request = URLRequest(url: URL(string: "https://aurral.example/redirect?status=302&to=https://aurral.example/api/auth/api-key")!)
        request.setValue("SECRET", forHTTPHeaderField: header)
        _ = try? await transport.send(request)
        #expect(RedirectStub.landedPaths.isEmpty, "\(header) landed at \(RedirectStub.landedPaths)")
    }

    @Test func redirectPolicyRequestRules() {
        func req(_ method: String, _ headers: [String: String] = [:]) -> URLRequest {
            var r = URLRequest(url: URL(string: "https://music.example/a")!)
            r.httpMethod = method
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            return r
        }
        let same = URL(string: "https://music.example/b")
        #expect(SameOriginRedirects.allows(original: req("GET"), to: same))
        #expect(SameOriginRedirects.allows(original: req("HEAD"), to: same))
        #expect(!SameOriginRedirects.allows(original: req("GET"), to: URL(string: "https://evil.example/b")))
        #expect(!SameOriginRedirects.allows(original: req("DELETE"), to: same))
        #expect(!SameOriginRedirects.allows(original: req("POST"), to: same))
        #expect(!SameOriginRedirects.allows(original: req("get", ["x-api-key": "k"]), to: same))
        #expect(!SameOriginRedirects.allows(original: req("GET", ["X-ND-Authorization": "Bearer x"]), to: same))
        #expect(!SameOriginRedirects.allows(original: req("GET", ["Authorization": "Token x"]), to: same))
        #expect(!SameOriginRedirects.allows(original: nil, to: same))
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
    private static let landedPathList = OSAllocatedUnfairLock(initialState: [String]())
    static var landedHosts: [String] { landed.withLock { $0 } }
    static var landedPaths: [String] { landedPathList.withLock { $0 } }
    static func reset() {
        landed.withLock { $0 = [] }
        landedPathList.withLock { $0 = [] }
    }

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
        Self.landedPathList.withLock { $0.append(url.path) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("landed".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
