import CoreGraphics
import Foundation
import MagpieCore
import MagpieTestSupport
import os
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A tiny PNG (any actor).
func b1png(side: Int = 8) -> Data {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// A transport whose answers wait `delay` (nil: forever) and counts how many run at once.
final class SlowArtTransport: HTTPTransport, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (running: 0, peak: 0, urls: [String]()))
    let delay: Duration?
    let answer: @Sendable (URL) -> Int
    init(delay: Duration?, answer: @escaping @Sendable (URL) -> Int = { _ in 200 }) { self.delay = delay; self.answer = answer }
    var peak: Int { state.withLock { $0.peak } }
    var urls: [String] { state.withLock { $0.urls } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running); $0.urls.append(request.url!.absoluteString) }
        defer { state.withLock { $0.running -= 1 } }
        if let delay { try await Task.sleep(for: delay) } else { try await Task.sleep(for: .seconds(600)) }
        let status = answer(request.url!)
        return (status == 200 ? b1png() : Data(),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// B1 (owner items 4–6): outside pictures fill every time. An album's cover falls back (release group → a release →
/// Lidarr's named cover → placeholder), pictures that loaded are kept on disk and shown at once next time, a miss or a
/// load cut short is never kept (a later look or a pull to refresh tries again), loads take turns (at most a few at
/// once), and a source that never answers is cut off. Stubs only: nothing reaches the internet.
@MainActor @Suite struct B1OutsideArtTests {
    static let rg = OutsideArtTests.rg
    static let release = OutsideArtTests.release
    static let artist = OutsideArtTests.artist
    static let other = MBID("0383dadf-2a4e-4d10-a46a-e9e041da8eb3")!

    let dir = FileManager.default.temporaryDirectory.appending(path: "B1OutsideArt-\(UUID().uuidString)")

    func loader(_ t: HTTPTransport, covers: OutsideCoverFallbacks = .init(), disk: Bool = true,
                artistImage: OutsideArtLoader.ArtistImage? = nil, limiter: AsyncLimiter? = nil,
                timeout: Duration = .seconds(30), lookups: Int = .max) -> OutsideArtLoader {
        OutsideArtLoader(transport: t, userAgent: OutsideArtTests.ua, artistImage: artistImage, isOffline: { false },
                         maxArtistLookups: lookups, covers: covers,
                         disk: disk ? OutsideArtDiskCache(directory: dir) : nil, limiter: limiter, timeout: timeout)
    }

    @Test func aMissingReleaseGroupCoverFallsBackToAReleaseThenLidarr() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/release/\(Self.other.rawValue)/front-250", body: b1png())
        let (release, other) = (Self.release, Self.other)
        let covers = OutsideCoverFallbacks(releases: { _ in [release, other] }, lidarrCover: { _ in nil })
        #expect(await loader(t, covers: covers).image(.releaseGroup(Self.rg)) != nil)
        #expect(t.requests.map { $0.url!.path } == ["/release-group/\(Self.rg.rawValue)/front-250",
                                                     "/release/\(Self.release.rawValue)/front-250",
                                                     "/release/\(Self.other.rawValue)/front-250"])

        let lidarr = MockTransport()
        lidarr.stub(pathSuffix: "/cover.jpg", body: b1png())
        let named = OutsideCoverFallbacks(releases: { _ in [] },
                                          lidarrCover: { _ in URL(string: "https://images.example.org/a/cover.jpg") })
        #expect(await loader(lidarr, covers: named, disk: false).image(.releaseGroup(Self.rg)) != nil, "Lidarr's cover last")
        #expect(lidarr.requests.last?.url?.host() == "images.example.org")
    }

    @Test func lidarrsCoverNeverFromDeezerAppleOrTheOwnersNetwork() async {
        for bad in ["https://e-cdns-images.dzcdn.net/images/cover/x/250x250.jpg", "https://is1-ssl.mzstatic.com/a.jpg",
                    "http://images.example.org/a.jpg", "https://192.168.1.10/a.jpg", "https://nas.local/a.jpg"] {
            let t = MockTransport()
            t.stub(pathSuffix: ".jpg", body: b1png())
            let covers = OutsideCoverFallbacks(releases: nil, lidarrCover: { _ in URL(string: bad) })
            #expect(await loader(t, covers: covers, disk: false).image(.releaseGroup(Self.rg)) == nil, "\(bad)")
            #expect(!t.requests.contains { $0.url?.absoluteString == bad }, "\(bad) never asked")
        }
    }

    /// Kept on disk: another screen (a new loader) shows it at once, with no request.
    @Test func aLoadedPictureShowsAtOnceNextTime() async {
        let t = MockTransport()
        t.stub(pathSuffix: "/front-250", body: b1png())
        #expect(await loader(t).image(.releaseGroup(Self.rg)) != nil)
        let later = MockTransport()
        let next = loader(later)
        #expect(next.cached(.releaseGroup(Self.rg)) != nil, "from the phone, synchronously")
        #expect(await next.image(.releaseGroup(Self.rg)) != nil)
        #expect(later.requests.isEmpty)
    }

    /// A cover that fails, then works on the next try (a pull to refresh): the miss was never kept.
    @Test func aCoverThatFailsThenSucceedsOnRefresh() async {
        let flaky = OSAllocatedUnfairLock(initialState: 0)
        let t = MockTransport()
        t.stub(pathSuffix: "/front-250") { _ in
            let n = flaky.withLock { $0 += 1; return $0 }
            return n == 1 ? .init(status: 503, body: Data()) : .init(status: 200, body: b1png())
        }
        let art = loader(t)
        #expect(await art.image(.releaseGroup(Self.rg)) == nil, "the first try fails: placeholder")
        #expect(OutsideArtDiskCache(directory: dir).count == 0, "a miss is never kept")
        #expect(await art.image(.releaseGroup(Self.rg)) != nil, "the next try asks again and fills it")
        #expect(OutsideArtDiskCache(directory: dir).count == 1)
    }

    /// A load cut short (the screen closed) keeps nothing, and the next look loads it.
    @Test func aCancelledLoadNeverPoisonsTheCache() async {
        let slow = SlowArtTransport(delay: .milliseconds(300))
        let art = loader(slow)
        async let first = art.image(.releaseGroup(Self.rg))
        try? await Task.sleep(for: .milliseconds(50))
        art.reset()
        #expect(await first == nil)
        #expect(OutsideArtDiskCache(directory: dir).count == 0)
        #expect(await art.image(.releaseGroup(Self.rg)) != nil, "asked again, it loads")
    }

    /// A source that never answers is cut off at the timeout; the page never waits on it.
    @Test func aSilentSourceTimesOut() async {
        let silent = SlowArtTransport(delay: nil)
        let art = loader(silent, timeout: .milliseconds(200))
        let start = ContinuousClock.now
        #expect(await art.image(.releaseGroup(Self.rg)) == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(OutsideArtDiskCache(directory: dir).count == 0)
    }

    /// A page of recommended artists: every picture is fetched, at most four at once, then kept.
    @Test func prefetchTakesTurnsAndKeepsEveryPicture() async {
        let slow = SlowArtTransport(delay: .milliseconds(40))
        let ids = (0..<12).map { MBID(String(format: "%08d-0000-4000-8000-000000000000", $0))! }
        let art = loader(slow, artistImage: { mbid in URL(string: "https://pictures.example.org/\(mbid.rawValue).jpg") },
                         limiter: AsyncLimiter(limit: 4), lookups: .max)
        await art.prefetch(ids.map(OutsideArtKey.artist))
        #expect(slow.urls.count == 12)
        #expect(slow.peak <= 4, "bounded: \(slow.peak) at once")
        #expect(OutsideArtDiskCache(directory: dir).count == 12)
        let again = loader(MockTransport())
        #expect(ids.allSatisfy { again.cached(.artist($0)) != nil }, "shown at once on the next open")
    }

    @Test func signOutRemovesThePictures() async {
        let t = MockTransport()
        t.stub(pathSuffix: "/front-250", body: b1png())
        _ = await loader(t).image(.releaseGroup(Self.rg))
        let disk = OutsideArtDiskCache(directory: dir)
        #expect(disk.count == 1)
        disk.removeAll()
        #expect(disk.count == 0)
    }
}
