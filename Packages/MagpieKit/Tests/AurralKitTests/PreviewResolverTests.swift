import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 14 A1 (D83), A7 (D110, plan decision 11): a preview is the clip Aurral itself sends
/// (`GET /api/deezer/preview/<id>.mp3?download`, 200 `audio/mpeg`), fetched with no login attached, never through a
/// redirect, and only as answered by the configured Aurral host. The phone never contacts Deezer.
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
                    "https://cdn.example/x.mp3", "/api/deezer/preview/1/2.mp3", "api/deezer/preview/1.mp3",
                    "/api/deezer/preview/123456789012345678901.mp3", "/api/image-proxy/1.mp3", "/api/deezer/preview/1.mp3/"] {
            #expect(AurralPreview(path: bad) == nil, "\(bad)")
        }
        #expect(AurralPreview(trackId: "1")?.url(on: URL(string: "https://music.home/aurral/")!)?.absoluteString
                == "https://music.home/aurral/api/deezer/preview/1.mp3?download")
    }

    @Test func fetchesTheClipFromAurralWithDownload() async throws {
        let result = try await resolver.resolve(preview)
        guard case .clip(let data) = result else { Issue.record("\(result)"); return }
        #expect(data == StubAurral.previewClip(size: 2_048))
        #expect(stub.asked == ["GET /api/deezer/preview/3135556.mp3"])
        #expect(stub.requests.first?.url?.query == "download")
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

    /// No redirect at all: Aurral's old 302 to Deezer's CDN (an Aurral ignoring `?download`) and every other 3xx are
    /// refused, never followed.
    @Test(arguments: [301, 302, 303, 307, 308])
    func anyRedirectIsRefused(_ status: Int) async throws {
        stub.setPreviewStatus(status)
        await #expect(throws: PreviewError.refused) { _ = try await resolver.resolve(preview) }
    }

    /// The clip must come from the configured Aurral host: an answer that landed anywhere else (a transport that
    /// followed a redirect itself) is refused, whatever it holds.
    @Test(arguments: ["https://cdnt-preview.dzcdn.net/a.mp3", "http://aurral-stub:3002/api/deezer/preview/3135556.mp3",
                      "https://aurral-stub:3001/api/deezer/preview/3135556.mp3", "http://aurral-stub.evil.example:3001/a.mp3",
                      "http://evil.example/api/deezer/preview/3135556.mp3"])
    func anAnswerFromAnotherHostIsRefused(_ landed: String) async throws {
        let followed = LandingTransport(inner: stub, finalURL: URL(string: landed)!)
        await #expect(throws: PreviewError.refused) {
            _ = try await PreviewResolver(base: stub.base, transport: followed).resolve(preview)
        }
    }

    @Test func noPreviewIs404() async throws {
        stub.setPreviewTarget(nil)
        #expect(try await resolver.resolve(preview) == .noPreview)
    }

    @Test(arguments: [500, 502, 503])
    func aurralOrDeezerDownIsUnavailable(_ status: Int) async throws {
        stub.setPreviewStatus(status)
        await #expect(throws: PreviewError.unavailable(status: status)) { _ = try await resolver.resolve(preview) }
    }

    /// Anything but the clip: another status, an empty body, something that isn't audio, more than a preview's size.
    @Test func everythingElseIsRefused() async throws {
        for status in [200, 204, 401, 403, 429] {   // the stub's status override sends no bytes
            stub.setPreviewStatus(status)
            await #expect(throws: PreviewError.refused, "\(status)") { _ = try await resolver.resolve(preview) }
        }
        stub.setPreviewStatus(nil)
        stub.setPreviewClipType("text/html")
        await #expect(throws: PreviewError.refused) { _ = try await resolver.resolve(preview) }
        stub.setPreviewClipType("audio/mpeg")
        stub.setPreviewClipSize(PreviewResolver.maxBytes + 1)
        await #expect(throws: PreviewError.refused) { _ = try await resolver.resolve(preview) }
        stub.setPreviewClipSize(PreviewResolver.maxBytes)
        guard case .clip = try await resolver.resolve(preview) else { Issue.record("a clip at the cap plays"); return }
    }

    /// Fix I1: an Aurral saved with capital letters (`http://Aurral-Stub:3001`) still plays: URLSession hands back the
    /// answer's URL canonical (lower-cased scheme and host), which must not read as another host.
    @Test func aMixedCaseBaseStillResolves() async throws {
        let mixed = PreviewResolver(base: URL(string: "HTTP://Aurral-Stub:3001")!, transport: stub)
        guard case .clip = try await mixed.resolve(preview) else { Issue.record("not a clip"); return }
        #expect(stub.requests.first?.url?.host == "Aurral-Stub", "asked as configured")
        stub.setPreviewTarget(nil)
        #expect(try await mixed.resolve(preview) == .noPreview)
    }

    /// An https Aurral is asked over https, a plain-http one over http (as the owner configured it).
    @Test func theSchemeFollowsTheConfiguredBase() async throws {
        let mock = MockTransport()
        mock.stub(pathSuffix: "/3135556.mp3") { _ in .init(status: 200, body: Data([0x49, 0x44, 0x33]),
                                                           headers: ["Content-Type": "audio/mpeg"]) }
        let https = PreviewResolver(base: URL(string: "https://aurral.example.org")!, transport: mock)
        guard case .clip = try await https.resolve(preview) else { Issue.record("not a clip"); return }
        #expect(mock.requests.first?.url?.absoluteString == "https://aurral.example.org/api/deezer/preview/3135556.mp3?download")
    }

    /// The clip is never kept: each resolve asks Aurral again.
    @Test func neverCachesTheClip() async throws {
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
                                       httpVersion: "HTTP/1.1", headerFields: ["Location": "http://aurral-stub:3001/b.mp3"])!
        let next = await AurralOpenTransport.NoRedirects.shared.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                                                                           newRequest: URLRequest(url: URL(string: "http://aurral-stub:3001/b.mp3")!))
        #expect(next == nil)
        task.cancel()
        session.invalidateAndCancel()
    }

    /// The preview route is open on Aurral and in the allow-list as such: never sent by the signed-in client, and only
    /// with `download`.
    @Test func theSignedInClientNeverSendsIt() {
        #expect(AurralRoute.deezerPreview.isAuthorised == false)
        #expect(AurralRoute.deezerPreview.queryNames == ["download"])
    }
}

/// A transport that pretends it followed a redirect: the answer's URL is `finalURL`.
struct LandingTransport: HTTPTransport {
    let inner: HTTPTransport
    let finalURL: URL
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await inner.send(request)
        return (data, HTTPURLResponse(url: finalURL, statusCode: response.statusCode, httpVersion: "HTTP/1.1",
                                      headerFields: response.allHeaderFields as? [String: String])!)
    }
}
