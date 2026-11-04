import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 14 A1 (D83, plan decision 3): a preview is fetched with no login attached, its one redirect is followed only
/// to Deezer's HTTPS audio hosts (`*.dzcdn.net`), and the signed link is handed over, never kept.
@Suite struct PreviewResolverTests {
    let stub: StubAurral
    let resolver: PreviewResolver
    let preview = AurralPreview(trackId: "3135556")!

    init() {
        stub = StubAurral()
        stub.useAurral213()
        resolver = PreviewResolver(base: stub.base, transport: stub)
    }

    @Test func previewPathsAreAurralsOwnOnly() {
        #expect(AurralPreview(path: "/api/deezer/preview/3135556.mp3")?.trackId == "3135556")
        for bad in ["/api/deezer/preview/abc.mp3", "/api/deezer/preview/1.mp3?download", "/api/deezer/preview/.mp3",
                    "https://cdnt-preview.dzcdn.net/x.mp3", "/api/deezer/preview/1/2.mp3", "api/deezer/preview/1.mp3",
                    "/api/deezer/preview/123456789012345678901.mp3", "/api/image-proxy/1.mp3", "/api/deezer/preview/1.mp3/"] {
            #expect(AurralPreview(path: bad) == nil, "\(bad)")
        }
        #expect(AurralPreview(trackId: "1")?.url(on: URL(string: "https://music.home/aurral/")!)?.absoluteString
                == "https://music.home/aurral/api/deezer/preview/1.mp3")
    }

    @Test func resolvesTheRedirectToDeezer() async throws {
        let result = try await resolver.resolve(preview)
        guard case .playable(let url) = result else { Issue.record("\(result)"); return }
        #expect(url.host() == "cdnt-preview.dzcdn.net" && url.scheme == "https")
        #expect(stub.asked == ["GET /api/deezer/preview/3135556.mp3"])
    }

    /// Nothing that could identify the owner goes with it: no Authorization, no cookie, no API key, even with a
    /// session signed in on the same Aurral.
    @Test func sendsNoLoginOrCookie() async throws {
        _ = stub.signedInSession()
        _ = try await resolver.resolve(preview)
        let request = try #require(stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    /// Only `https://<anything>.dzcdn.net/...` (or dzcdn.net itself) on the default port, without user info.
    @Test func redirectHostIsPinned() async throws {
        let refused = [
            "http://cdnt-preview.dzcdn.net/a.mp3",                // not https
            "https://evil.example/a.mp3",
            "https://dzcdn.net.evil.example/a.mp3",
            "https://evildzcdn.net/a.mp3",
            "https://cdnt-preview.dzcdn.net.evil.example/a.mp3",
            "https://user:pw@cdnt-preview.dzcdn.net/a.mp3",
            "https://cdnt-preview.dzcdn.net:8443/a.mp3",
            "/api/deezer/preview/3135556.mp3?download",           // relative: back into Aurral
            "//cdnt-preview.dzcdn.net/a.mp3",
            "ftp://cdnt-preview.dzcdn.net/a.mp3",
            "https://cdnt-preview.dzcdn.net",                     // no path
            "not a url",
        ]
        for target in refused {
            stub.setPreviewTarget(target)
            await #expect(throws: PreviewError.refused, "\(target)") { _ = try await resolver.resolve(preview) }
        }
        for target in ["https://cdnt-preview.dzcdn.net/api/1/1/a.mp3?hdnea=exp=1~hmac=x", "https://e-cdns-preview-a.dzcdn.net/a.mp3",
                       "https://CDNT-PREVIEW.DZCDN.NET/a.mp3", "https://dzcdn.net/a.mp3", "https://cdnt-preview.dzcdn.net:443/a.mp3"] {
            stub.setPreviewTarget(target)
            #expect(try await resolver.resolve(preview) != .noPreview, "\(target)")
        }
    }

    @Test func noPreviewIs404() async throws {
        stub.setPreviewTarget(nil)
        #expect(try await resolver.resolve(preview) == .noPreview)
    }

    /// Anything but one 302 or a 404 is refused: Deezer down (502), the bytes (200, also what a transport that followed
    /// the redirect itself would give), any other redirect code.
    @Test func everythingElseIsRefused() async throws {
        stub.setPreviewStatus(502)
        await #expect(throws: PreviewError.unavailable(status: 502)) { _ = try await resolver.resolve(preview) }
        for status in [200, 301, 303, 307, 308, 401, 500] {
            stub.setPreviewStatus(status)
            await #expect(throws: PreviewError.self, "\(status)") { _ = try await resolver.resolve(preview) }
        }
    }

    /// A transport that followed the redirect itself (the answer's URL isn't the one asked) is refused.
    @Test func aFollowedRedirectIsRefused() async throws {
        let mock = MockTransport()
        mock.stub(pathSuffix: "/3135556.mp3") { _ in .init(status: 200, body: Data([0xFF, 0xFB])) }
        let followed = FollowingTransport(inner: mock, finalURL: URL(string: "https://evil.example/a.mp3")!)
        await #expect(throws: PreviewError.refused) {
            _ = try await PreviewResolver(base: stub.base, transport: followed).resolve(preview)
        }
    }

    /// The signed link is never kept: each resolve asks Aurral again (the link expires after about 15 minutes).
    @Test func neverCachesTheSignedLink() async throws {
        _ = try await resolver.resolve(preview)
        _ = try await resolver.resolve(preview)
        #expect(stub.requests.count == 2)
    }

    /// The real transport: an ephemeral session with no cookies and no cache, which never follows a redirect.
    @Test func defaultTransportNeverFollowsKeepsNoCookiesOrCache() async throws {
        let config = PreviewResolver.sessionConfiguration()
        #expect(config.httpCookieStorage == nil && config.httpShouldSetCookies == false)
        #expect(config.urlCache == nil && config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(config.httpCookieAcceptPolicy == .never)
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: URLRequest(url: URL(string: "http://aurral-stub:3001/api/deezer/preview/1.mp3")!))
        let redirect = HTTPURLResponse(url: URL(string: "http://aurral-stub:3001/api/deezer/preview/1.mp3")!, statusCode: 302,
                                       httpVersion: "HTTP/1.1", headerFields: ["Location": "https://cdnt-preview.dzcdn.net/a.mp3"])!
        let next = await PreviewResolver.NoRedirects.shared.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                                                                       newRequest: URLRequest(url: URL(string: "https://cdnt-preview.dzcdn.net/a.mp3")!))
        #expect(next == nil)
        task.cancel()
        session.invalidateAndCancel()
    }

    /// The preview route is open on Aurral and in the allow-list as such: never sent by the signed-in client.
    @Test func theSignedInClientNeverSendsIt() {
        #expect(AurralRoute.deezerPreview.isAuthorised == false)
    }
}

/// A transport that pretends it followed a redirect: the answer's URL is `finalURL`.
private struct FollowingTransport: HTTPTransport {
    let inner: MockTransport
    let finalURL: URL
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await inner.send(request)
        return (data, HTTPURLResponse(url: finalURL, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}
