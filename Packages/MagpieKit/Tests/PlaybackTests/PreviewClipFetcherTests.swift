import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Playback

/// Round 14 A2 (D88): the preview clip is fetched by Magpie, not by AVPlayer, so every hop after Aurral's pinned one stays
/// https (the app allows plain http everywhere for the owner's servers, and AVPlayer would follow an http redirect).
@Suite struct PreviewClipFetcherTests {
    static let signed = URL(string: "https://cdnt-preview.dzcdn.net/api/1/1/a/b/c/preview.mp3?hdnea=exp=1790000000~hmac=x")!

    @Test func fetchesTheClipWithNoCookieAndNoCache() async throws {
        let transport = MockTransport()
        transport.stub(pathSuffix: "preview.mp3", body: Data(repeating: 7, count: 1_000), headers: ["Content-Type": "audio/mpeg"])
        let data = try await PreviewClipFetcher(transport: transport).fetch(Self.signed)
        #expect(data.count == 1_000)
        let request = try #require(transport.requests.first)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url == Self.signed)
    }

    @Test(arguments: ["http://cdnt-preview.dzcdn.net/a.mp3", "ftp://cdnt-preview.dzcdn.net/a.mp3",
                      "https://user:pw@cdnt-preview.dzcdn.net/a.mp3", "file:///tmp/a.mp3", "https:///a.mp3"])
    func refusesAnythingButHTTPSAndSendsNothing(_ text: String) async throws {
        let transport = MockTransport()
        let url = try #require(URL(string: text))
        await #expect(throws: PreviewClipError.refused) { try await PreviewClipFetcher(transport: transport).fetch(url) }
        #expect(transport.requests.isEmpty)
    }

    /// An expired signed link (Deezer answers 403) or any other status is a failure the player resolves again once.
    @Test(arguments: [403, 404, 410, 500, 302])
    func anythingButA200Fails(_ status: Int) async throws {
        let transport = MockTransport()
        transport.stub(pathSuffix: "preview.mp3", status: status, body: Data("denied".utf8))
        await #expect(throws: PreviewClipError.status(status)) { try await PreviewClipFetcher(transport: transport).fetch(Self.signed) }
    }

    @Test func emptyOrOversizedClipsAreRefused() async throws {
        let empty = MockTransport()
        empty.stub(pathSuffix: "preview.mp3", body: Data())
        await #expect(throws: PreviewClipError.refused) { try await PreviewClipFetcher(transport: empty).fetch(Self.signed) }
        let huge = MockTransport()
        huge.stub(pathSuffix: "preview.mp3", body: Data(count: PreviewClipFetcher.maxBytes + 1))
        await #expect(throws: PreviewClipError.refused) { try await PreviewClipFetcher(transport: huge).fetch(Self.signed) }
    }

    /// The real session follows a redirect only to https, never with user info; it keeps no cookie and no cache.
    @Test func redirectsStayHTTPS() async throws {
        let delegate = PreviewClipFetcher.HTTPSOnlyRedirects.shared
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: Self.signed)
        let response = try #require(HTTPURLResponse(url: Self.signed, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
        func follow(_ text: String) async -> URL? {
            await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                      newRequest: URLRequest(url: URL(string: text)!))?.url
        }
        #expect(await follow("https://e-cdns-preview-1.dzcdn.net/stream/x.mp3") != nil)
        #expect(await follow("https://other-cdn.example.com/x.mp3") != nil, "https anywhere: no credential rides along")
        #expect(await follow("http://e-cdns-preview-1.dzcdn.net/stream/x.mp3") == nil)
        #expect(await follow("https://u:p@e-cdns-preview-1.dzcdn.net/x.mp3") == nil)
        task.cancel()

        let config = PreviewClipFetcher.sessionConfiguration()
        #expect(config.httpCookieStorage == nil && config.httpShouldSetCookies == false && config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    /// A transport that followed a redirect to plain http itself hands back that URL: refused.
    @Test func aResponseFromPlainHTTPIsRefused() async throws {
        struct Downgrading: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = URL(string: "http://evil.example.com/x.mp3")!
                return (Data(repeating: 1, count: 10), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        await #expect(throws: PreviewClipError.refused) { try await PreviewClipFetcher(transport: Downgrading()).fetch(Self.signed) }
    }
}
