import CoreGraphics
import Foundation
import ImageIO
import MagpieCore
import MagpieTestSupport
import Testing
import UniformTypeIdentifiers

/// R15: artwork for search results outside the library. Cover Art Archive for songs and albums, Lidarr's lookup images
/// for artists, in memory for the current results only, HTTPS from expected hosts, at most 2 MB, nothing when offline.
/// Every request goes to a stub; nothing here reaches coverartarchive.org or any other internet host.
@MainActor @Suite struct OutsideArtTests {
    static let rg = MBID("b1392450-e666-3926-a536-22c65f834433")!
    static let release = MBID("59c3d6a7-6fdb-4d99-9135-ade798449106")!
    static let artist = MBID("a74b1b7f-71a5-4011-9441-d0b5e4122711")!
    static let ua = "Magpie/9.9.9 ( https://github.com/bleak-rooster )"

    /// A tiny PNG, made here so no fixture is needed.
    static func png(side: Int = 8) -> Data {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func loader(_ transport: MockTransport, offline: Bool = false,
                artistImage: OutsideArtLoader.ArtistImage? = nil) -> OutsideArtLoader {
        OutsideArtLoader(transport: transport, userAgent: Self.ua, artistImage: artistImage, isOffline: { offline })
    }

    // MARK: - Songs and albums: Cover Art Archive

    @Test func albumRowAsksCoverArtArchiveForItsReleaseGroup() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/front-250", body: Self.png(), headers: ["Content-Type": "image/png"])
        let image = await loader(t).image(.releaseGroup(Self.rg))
        #expect(image != nil)
        let request = try #require(t.requests.first)
        #expect(request.url?.absoluteString == "https://coverartarchive.org/release-group/\(Self.rg.rawValue)/front-250")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == Self.ua)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func songRowAsksCoverArtArchiveForItsRelease() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/front-250", body: Self.png())
        _ = await loader(t).image(.release(Self.release))
        #expect(t.requests.map { $0.url?.absoluteString } == ["https://coverartarchive.org/release/\(Self.release.rawValue)/front-250"])
    }

    @Test func keyForARecordingPrefersTheReleaseGroupThenTheRelease() {
        var r = ExternalRecording(title: "T", artist: "A", source: .listenBrainz)
        #expect(OutsideArtKey.cover(releaseGroup: nil, release: r.releaseMBID) == nil)
        r.releaseMBID = Self.release
        #expect(OutsideArtKey.cover(releaseGroup: nil, release: r.releaseMBID) == .release(Self.release))
        #expect(OutsideArtKey.cover(releaseGroup: Self.rg, release: r.releaseMBID) == .releaseGroup(Self.rg))
    }

    @Test func aMissingCoverOrAnOutageIsThePlaceholderSilently() async {
        let t = MockTransport()   // every route 404s
        #expect(await loader(t).image(.releaseGroup(Self.rg)) == nil)
        let broken = MockTransport()
        broken.stub(pathSuffix: "/front-250") { _ in throw URLError(.notConnectedToInternet) }
        #expect(await loader(broken).image(.releaseGroup(Self.rg)) == nil)
        let junk = MockTransport()
        junk.stub(pathSuffix: "/front-250", body: Data("not an image".utf8))
        #expect(await loader(junk).image(.releaseGroup(Self.rg)) == nil)
    }

    // MARK: - Memory only, fetched again for every search

    @Test func heldForTheCurrentResultsThenFetchedAgainOnANewSearch() async {
        let t = MockTransport()
        t.stub(pathSuffix: "/front-250", body: Self.png())
        let l = loader(t)
        _ = await l.image(.releaseGroup(Self.rg))
        _ = await l.image(.releaseGroup(Self.rg))
        #expect(t.requests.count == 1)   // same results: memory
        l.reset()                        // a new search
        #expect(l.cachedCount == 0)
        _ = await l.image(.releaseGroup(Self.rg))
        #expect(t.requests.count == 2)
    }

    @Test func theRealTransportKeepsNothing() {
        let c = OutsideArtTransport.configuration
        #expect(c.urlCache == nil)
        #expect(c.httpCookieStorage == nil)
        #expect(c.httpShouldSetCookies == false)
        #expect(c.urlCredentialStorage == nil)
        #expect(c.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(OutsideArtTransport().sessionConfiguration.urlCache == nil)
        #expect(OutsideArtTransport().sessionConfiguration.httpCookieStorage == nil)
    }

    // MARK: - Artists: Lidarr lookup images

    @Test func artistRowUsesTheLookupImageOverHTTPS() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/poster.jpg", body: Self.png())
        let asked = Box<[MBID]>([])
        let l = loader(t, artistImage: { mbid in
            await asked.append(mbid)
            return URL(string: "https://images.lidarr.audio/cache/poster.jpg")
        })
        #expect(await l.image(.artist(Self.artist)) != nil)
        #expect(await asked.value == [Self.artist])
        #expect(t.requests.map { $0.url?.absoluteString } == ["https://images.lidarr.audio/cache/poster.jpg"])
    }

    @Test func anArtistImageOverPlainHTTPIsRefused() async {
        let t = MockTransport()
        t.stub(pathSuffix: "/poster.jpg", body: Self.png())
        let l = loader(t, artistImage: { _ in URL(string: "http://images.lidarr.audio/cache/poster.jpg") })
        #expect(await l.image(.artist(Self.artist)) == nil)
        #expect(t.requests.isEmpty)
    }

    @Test func atMostEightArtistLookupsPerSearch() async {
        let t = MockTransport()
        t.stub(pathSuffix: ".jpg", body: Self.png())
        let lookups = Box(0)
        let l = loader(t, artistImage: { mbid in
            await lookups.add(1)
            return URL(string: "https://images.lidarr.audio/\(mbid.rawValue).jpg")
        })
        for _ in 0..<12 { _ = await l.image(.artist(MBID(UUID().uuidString)!)) }
        #expect(await lookups.value == OutsideArtPolicy.maxArtistLookups)
        #expect(OutsideArtPolicy.maxArtistLookups == 8)
        l.reset()   // the next search has its own eight
        _ = await l.image(.artist(MBID(UUID().uuidString)!))
        #expect(await lookups.value == 9)
    }

    @Test func aQueryChangeCancelsLookupsInFlight() async {
        let t = MockTransport()
        let cancelled = Box(false)
        let l = loader(t, artistImage: { _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { await cancelled.set(true) }
            return URL(string: "https://images.lidarr.audio/late.jpg")
        })
        let pending = Task { await l.image(.artist(Self.artist)) }
        try? await Task.sleep(for: .milliseconds(50))
        l.reset()
        #expect(await pending.value == nil)
        #expect(await cancelled.value)
        #expect(t.requests.isEmpty)   // the image of a stale result is never fetched
    }

    // MARK: - Hosts, size, offline

    @Test func onlyHTTPSFromExpectedHostsIsFollowed() {
        let caa = URL(string: "https://coverartarchive.org/release-group/x/front-250")!
        #expect(OutsideArtPolicy.isAllowed(caa, for: .releaseGroup(Self.rg)))
        #expect(!OutsideArtPolicy.isAllowed(URL(string: "http://coverartarchive.org/release-group/x/front-250")!,
                                            for: .releaseGroup(Self.rg)))
        #expect(!OutsideArtPolicy.isAllowed(URL(string: "https://evil.example/x.jpg")!, for: .releaseGroup(Self.rg)))
        #expect(!OutsideArtPolicy.isAllowed(URL(string: "https://user:pw@coverartarchive.org/x")!, for: .release(Self.release)))
        #expect(OutsideArtPolicy.isAllowed(URL(string: "https://images.lidarr.audio/a.jpg")!, for: .artist(Self.artist)))
        #expect(!OutsideArtPolicy.isAllowed(URL(string: "http://images.lidarr.audio/a.jpg")!, for: .artist(Self.artist)))
        #expect(!OutsideArtPolicy.isAllowed(URL(string: "ftp://images.lidarr.audio/a.jpg")!, for: .artist(Self.artist)))

        // Redirects: Cover Art Archive hands off to archive.org; nowhere else, and never down to http.
        let toArchive = URL(string: "https://ia800100.us.archive.org/1/items/mbid-x/mbid-x-250.jpg")!
        #expect(OutsideArtPolicy.allowsRedirect(from: caa, to: toArchive))
        #expect(OutsideArtPolicy.allowsRedirect(from: caa, to: URL(string: "https://archive.org/download/x.jpg")!))
        #expect(!OutsideArtPolicy.allowsRedirect(from: caa, to: URL(string: "http://ia800100.us.archive.org/x.jpg")!))
        #expect(!OutsideArtPolicy.allowsRedirect(from: caa, to: URL(string: "https://notarchive.org/x.jpg")!))
        #expect(!OutsideArtPolicy.allowsRedirect(from: caa, to: URL(string: "https://evilarchive.org/x.jpg")!))
        #expect(!OutsideArtPolicy.allowsRedirect(from: caa, to: URL(string: "https://192.168.1.2/x.jpg")!))
        let lidarrImage = URL(string: "https://images.lidarr.audio/a.jpg")!
        #expect(OutsideArtPolicy.allowsRedirect(from: lidarrImage, to: URL(string: "https://images.lidarr.audio/b.jpg")!))
        #expect(!OutsideArtPolicy.allowsRedirect(from: lidarrImage, to: URL(string: "https://elsewhere.example/b.jpg")!))
    }

    @Test func anAnswerFromAnUnexpectedHostIsDropped() async {
        // A transport that followed a redirect somewhere it shouldn't have: the answer's URL gives it away.
        let t = RedirectingTransport(to: URL(string: "https://evil.example/x.png")!, body: Self.png())
        let l = OutsideArtLoader(transport: t, userAgent: Self.ua, artistImage: nil, isOffline: { false })
        #expect(await l.image(.releaseGroup(Self.rg)) == nil)
    }

    @Test func overTwoMegabytesIsRefused() async {
        #expect(OutsideArtPolicy.maxBytes == 2 * 1024 * 1024)
        let t = MockTransport()
        var big = Self.png()
        big.append(Data(count: OutsideArtPolicy.maxBytes + 1 - big.count))
        t.stub(pathSuffix: "/front-250", body: big)
        #expect(await loader(t).image(.releaseGroup(Self.rg)) == nil)
        let declared = MockTransport()
        declared.stub(pathSuffix: "/front-250", body: Self.png(),
                      headers: ["Content-Length": String(OutsideArtPolicy.maxBytes + 1)])
        #expect(await loader(declared).image(.releaseGroup(Self.rg)) == nil)
    }

    @Test func decodedWithDownsampling() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/front-250", body: Self.png(side: 1200))
        let l = OutsideArtLoader(transport: t, userAgent: Self.ua, artistImage: nil, isOffline: { false }, maxPixel: 300)
        let image = try #require(await l.image(.releaseGroup(Self.rg)))
        #expect(max(image.width, image.height) == 300)
    }

    @Test func offlineSendsNothing() async {
        let t = MockTransport()
        t.stub(pathSuffix: "/front-250", body: Self.png())
        let asked = Box(0)
        let l = loader(t, offline: true, artistImage: { _ in
            await asked.add(1)
            return URL(string: "https://images.lidarr.audio/a.jpg")
        })
        #expect(await l.image(.releaseGroup(Self.rg)) == nil)
        #expect(await l.image(.release(Self.release)) == nil)
        #expect(await l.image(.artist(Self.artist)) == nil)
        #expect(t.requests.isEmpty)
        #expect(await asked.value == 0)
    }

    @Test func carPlayTokensRoundTrip() {
        for key in [OutsideArtKey.releaseGroup(Self.rg), .release(Self.release), .artist(Self.artist)] {
            #expect(OutsideArtKey(token: key.token) == key)
            #expect(key.token.hasPrefix(OutsideArtKey.tokenPrefix))
        }
        #expect(OutsideArtKey(token: "al-123") == nil)
        #expect(OutsideArtKey(token: "outside:release:not-an-mbid") == nil)
    }
}

/// Answers every request as if it had been redirected to `to`.
private struct RedirectingTransport: HTTPTransport {
    let to: URL
    let body: Data
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: to, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

actor Box<T: Sendable> {
    var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { value = v }
}

extension Box where T == Int { func add(_ n: Int) { value += n } }
extension Box where T == [MBID] { func append(_ m: MBID) { value.append(m) } }
