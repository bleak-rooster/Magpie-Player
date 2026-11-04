import Foundation
import MagpieCore
import MagpieTestSupport
import Synchronization
import Testing
@testable import AurralKit

/// Round 14 A7 (D111, D112, plan decision 11): Deezer's and Apple's pictures that Aurral names are shown through
/// Aurral's image proxy, never loaded from their hosts. `POST /api/image-proxy {src}` only for a link Aurral itself
/// returned this session; the src → local mapping is kept on disk per server; at most four at once; any failure is
/// the placeholder (nil).
@Suite struct AurralImageProxyTests {
    let stub: StubAurral
    let session: AurralSession
    let client: AurralClient
    let directory: URL
    static let songArt = "https://cdn-images.dzcdn.net/images/cover/3135556/250x250-000000-80-0-0.jpg"

    init() {
        stub = StubAurral()
        stub.useAurral213()
        session = stub.signedInSession()
        client = AurralClient(base: stub.base, session: session, transport: stub)
        directory = FileManager.default.temporaryDirectory.appending(path: "image-proxy-\(UUID().uuidString)")
    }

    func proxy(base: URL? = nil, transport: HTTPTransport? = nil) -> AurralImageProxy {
        AurralImageProxy(base: base ?? stub.base, directory: directory, openTransport: transport ?? stub)
    }

    var fileGets: [URLRequest] {
        stub.requests.filter { $0.httpMethod == "GET" && $0.url?.path.hasPrefix("/api/image-proxy/") == true }
    }

    @Test func theRoutesAreExact() {
        let key = String(repeating: "ab", count: 32)
        #expect(AurralRoute.route(method: AurralRoute.imageProxyMethod, path: "api/image-proxy") == .imageProxy)
        #expect(AurralRoute.route(method: "GET", path: "api/image-proxy/\(key).jpg") == .imageProxyFile)
        #expect(AurralRoute.route(method: "GET", path: "api/image-proxy/\(key)") == .imageProxyFile)
        for bad in ["api/image-proxy/\(key.uppercased()).jpg", "api/image-proxy/abc.jpg", "api/image-proxy/\(key).j/pg",
                    "api/image-proxy/\(key).jpeg123", "api/image-proxy/\(key)..jpg", "api/image-proxy/\(key)/x"] {
            #expect(AurralRoute.route(method: "GET", path: bad) == nil, "\(bad)")
        }
        #expect(AurralRoute.route(method: "GET", path: "api/image-proxy") == nil, "the cache step is a POST only")
        #expect(AurralRoute.route(method: AurralRoute.imageProxyMethod, path: "api/image-proxy/\(key).jpg") == nil)
        #expect(AurralRoute.imageProxy.isAuthorised && !AurralRoute.imageProxyFile.isAuthorised)
        #expect(AurralRoute.imageProxy.queryNames.isEmpty && AurralRoute.imageProxyFile.queryNames.isEmpty)
    }

    /// Before Aurral has named the picture this session, nothing is sent; once a read returned it, it is proxied with
    /// exactly `{"src": <url>}` and fetched from Aurral with no login.
    @Test func onlyPicturesAurralReturnedAreSent() async throws {
        let art = try #require(AurralImage(Self.songArt))
        #expect(await proxy().imageData(for: art, client: client) == nil)
        #expect(stub.imageProxySources.isEmpty && fileGets.isEmpty, "never sent before Aurral named it")

        _ = try await client.trending()
        let data = try #require(await proxy().imageData(for: art, client: client))
        #expect(data == StubAurral.proxiedPicture)
        #expect(stub.imageProxySources == [Self.songArt])
        let post = try #require(stub.requests.last { $0.url?.path == "/api/image-proxy" })
        let body = try #require(post.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Array(body.keys) == ["src"])
        #expect(post.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        let get = try #require(fileGets.last)
        #expect(get.value(forHTTPHeaderField: "Authorization") == nil && get.httpShouldHandleCookies == false)
        #expect(get.url?.host() == stub.base.host())

        // A picture no Aurral answer named is never sent, even after reads.
        let stranger = try #require(AurralImage("https://e-cdns-images.dzcdn.net/images/cover/999/1.jpg"))
        #expect(await proxy().imageData(for: stranger, client: client) == nil)
        #expect(stub.imageProxySources == [Self.songArt])
    }

    /// Another session (a relaunch) doesn't know what the last one read: nothing is sent for it, except through the
    /// mapping already on disk (only Aurral's own path is asked, never the picture's link).
    @Test func theMappingIsKeptOnDiskPerServer() async throws {
        let art = try #require(AurralImage(Self.songArt))
        _ = try await client.trending()
        #expect(await proxy().imageData(for: art, client: client) != nil)
        #expect(stub.imageProxySources.count == 1)

        let relaunched = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
        let again = try #require(await proxy().imageData(for: art, client: relaunched))
        #expect(again == StubAurral.proxiedPicture)
        #expect(stub.imageProxySources.count == 1, "the saved mapping: no second POST")
        #expect(fileGets.count == 2)

        // Another server has its own mapping.
        let other = proxy(base: URL(string: "http://aurral-other:3001")!)
        #expect(await other.imageData(for: art, client: relaunched) == nil)
    }

    /// Aurral forgot its copy (its cache was cleared): the mapping is dropped and, when this session knows the link,
    /// asked for again once.
    @Test func aStaleMappingIsRefreshedOnce() async throws {
        let art = try #require(AurralImage(Self.songArt))
        _ = try await client.trending()
        _ = await proxy().imageData(for: art, client: client)
        stub.clearImageProxyCache()
        #expect(await proxy().imageData(for: art, client: client) == StubAurral.proxiedPicture)
        #expect(stub.imageProxySources.count == 2)

        // A new session doesn't know the link: the stale mapping is dropped and nothing more is sent.
        stub.clearImageProxyCache()
        let relaunched = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
        #expect(await proxy().imageData(for: art, client: relaunched) == nil)
        #expect(stub.imageProxySources.count == 2)
    }

    /// Any failure is the placeholder: Aurral refusing the source, its file route failing, a redirect, an answer from
    /// another host, something that isn't a picture.
    @Test func failuresAreThePlaceholder() async throws {
        let art = try #require(AurralImage(Self.songArt))
        _ = try await client.trending()
        stub.setImageProxyRefused(Self.songArt)
        #expect(await proxy().imageData(for: art, client: client) == nil)

        let album = try #require(try await client.trending().albums?.first?.artwork)
        for status in [302, 401, 500] {
            stub.setImageProxyFileStatus(status)
            #expect(await proxy().imageData(for: album, client: client) == nil, "\(status)")
        }
        stub.setImageProxyFileStatus(nil)
        let elsewhere = LandingTransport(inner: stub, finalURL: URL(string: "https://cdn-images.dzcdn.net/x.jpg")!)
        #expect(await proxy(transport: elsewhere).imageData(for: album, client: client) == nil)
        #expect(await proxy().imageData(for: album, client: client) != nil)
    }

    /// A picture Aurral already names on itself (`/api/image-proxy/<key>`) is fetched as it is; no other Aurral path is.
    @Test func anAurralPathIsFetchedDirectly() async throws {
        _ = try await client.trending()
        let art = try #require(AurralImage(Self.songArt))
        _ = await proxy().imageData(for: art, client: client)
        let path = try #require(fileGets.last?.url?.path)
        let posts = stub.imageProxySources.count
        #expect(await proxy().imageData(for: try #require(AurralImage(path)), client: client) == StubAurral.proxiedPicture)
        #expect(stub.imageProxySources.count == posts)
        #expect(await proxy().imageData(for: try #require(AurralImage("/api/settings")), client: client) == nil)
        #expect(!stub.asked.contains("GET /api/settings"))
    }

    /// At most four pictures are asked for at once.
    @Test func atMostFourAtOnce() async throws {
        let slow = SlowCountingTransport(inner: stub)
        let slowClient = AurralClient(base: stub.base, session: session, transport: slow)
        let trending = try await slowClient.trending()
        let songArt: [AurralImage] = (trending.songs?.items ?? []).compactMap(\.artwork)
        let albumArt: [AurralImage] = (trending.albums ?? []).compactMap(\.artwork)
        let artistArt: [AurralImage] = (trending.artists ?? []).compactMap(\.image)
        let pictures = Array(Set(songArt + albumArt + artistArt))
        #expect(pictures.count >= 5, "more pictures than the bound")
        let loader = proxy(transport: slow)
        await withTaskGroup(of: Data?.self) { group in
            for picture in pictures { group.addTask { await loader.imageData(for: picture, client: slowClient) } }
            for await _ in group {}
        }
        #expect(slow.peak <= 4 && slow.peak >= 2, "peak \(slow.peak)")
        #expect(stub.imageProxySources.count == pictures.count)
    }
}

/// Holds each image-proxy request a little and records how many were in flight at once.
final class SlowCountingTransport: HTTPTransport, Sendable {
    let inner: HTTPTransport
    private let counts = Mutex((now: 0, peak: 0))
    init(inner: HTTPTransport) { self.inner = inner }
    var peak: Int { counts.withLock { $0.peak } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.path.hasPrefix("/api/image-proxy") == true else { return try await inner.send(request) }
        counts.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
        defer { counts.withLock { $0.now -= 1 } }
        try await Task.sleep(for: .milliseconds(30))
        return try await inner.send(request)
    }
}
