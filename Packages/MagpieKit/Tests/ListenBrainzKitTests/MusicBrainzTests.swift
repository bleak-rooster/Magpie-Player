import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import ListenBrainzKit

private let harbour = MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d")!

@Suite struct MBTests {
    @Test func rateLimited() async throws {
        let clock = FakeClock()
        let t = MockTransport()
        t.stub(pathSuffix: "/recording/\(harbour.rawValue)", body: Fixtures.data("recording-c2272a15", dir: "musicbrainz"))
        let mb = MusicBrainzClient(transport: t, limiter: clock.limiter())
        _ = try await mb.recording(harbour)
        _ = try await mb.recording(harbour)
        _ = try await mb.recording(harbour)
        #expect(t.requests.count == 3)
        // First call goes straight through; each later call waits the full second (clock does not move on its own).
        #expect(clock.sleeps == [1, 1])
    }

    @Test func limiterOnlyWaitsRemainderAndHandlesBursts() async throws {
        let clock = FakeClock()
        let limiter = clock.limiter(perSecond: 1)
        try await limiter.wait()
        clock.advance(0.4)
        try await limiter.wait()
        #expect(clock.sleeps.count == 1 && abs(clock.sleeps[0] - 0.6) < 1e-9)
        clock.advance(5)
        try await limiter.wait()
        #expect(clock.sleeps.count == 1)   // idle for a while: no wait
        async let a: Void = limiter.wait()
        async let b: Void = limiter.wait()
        _ = try await (a, b)
        #expect(clock.sleeps.count == 3)   // two concurrent callers: queued 1 s apart
    }

    @Test func sendsRealUserAgentAndWS2Query() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/recording/\(harbour.rawValue)", body: Fixtures.data("recording-c2272a15", dir: "musicbrainz"))
        _ = try await MusicBrainzClient(transport: t, limiter: FakeClock().limiter()).recording(harbour)
        let req = try #require(t.requests.first)
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "Magpie/0.1 ( https://github.com/bleak-rooster )")
        #expect(req.url?.host == "musicbrainz.org")
        #expect(req.url?.path == "/ws/2/recording/\(harbour.rawValue)")
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains { $0.name == "fmt" && $0.value == "json" })
        #expect(items.contains { $0.name == "inc" && $0.value == "releases+release-groups+isrcs" })
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func parsesReleaseGroupTypes() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/recording/\(harbour.rawValue)", body: Fixtures.data("recording-c2272a15", dir: "musicbrainz"))
        let rec = try await MusicBrainzClient(transport: t, limiter: FakeClock().limiter()).recording(harbour)
        #expect(rec.id == harbour)
        #expect(rec.title == "Harbour Lights")
        #expect(rec.releases.count == 7)
        let first = rec.releases[0]
        #expect(first.id == MBID("545b96d6-c867-3053-9548-3e8635390e38"))
        #expect(first.title == "The Cat Is Out")
        #expect(first.date == "1985")
        #expect(first.status == "Official")
        #expect(first.releaseGroup.id == MBID("01a340b4-1d99-4083-ad92-fa2803368bed"))
        #expect(first.releaseGroup.primaryType == "Album")
        #expect(rec.isrcs.isEmpty)
    }

    @Test func parsesSinglesEPsIsrcsAndDropsBadReleases() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/recording/\(harbour.rawValue)", body: json("""
        {"id":"C2272A15-8F3A-4CDC-8F32-7E723352D44D","title":"T","isrcs":["GBAAA8500001"," "],
         "releases":[
          {"id":"545b96d6-c867-3053-9548-3e8635390e38","title":"S","date":"","status":"Official",
           "release-group":{"id":"01a340b4-1d99-4083-ad92-fa2803368bed","primary-type":"Single","secondary-types":["Live"]}},
          {"id":"645b96d6-c867-3053-9548-3e8635390e38","title":"E",
           "release-group":{"id":"11a340b4-1d99-4083-ad92-fa2803368bed","primary-type":"EP"}},
          {"id":"745b96d6-c867-3053-9548-3e8635390e38","title":"No type",
           "release-group":{"id":"21a340b4-1d99-4083-ad92-fa2803368bed","primary-type":null}},
          {"id":"bad","title":"Bad id","release-group":{"id":"01a340b4-1d99-4083-ad92-fa2803368bed"}},
          {"id":"845b96d6-c867-3053-9548-3e8635390e38","title":"No group"},
          7]}
        """))
        let rec = try await MusicBrainzClient(transport: t, limiter: FakeClock().limiter()).recording(harbour)
        #expect(rec.id == harbour)
        #expect(rec.isrcs == ["GBAAA8500001"])
        #expect(rec.releases.map(\.title) == ["S", "E", "No type"])
        #expect(rec.releases.map(\.releaseGroup.primaryType) == ["Single", "EP", nil])
        #expect(rec.releases[0].releaseGroup.secondaryTypes == ["Live"])
        #expect(rec.releases[0].date == nil)
        #expect(rec.releases[1].status == nil)
    }

    @Test func errorsMap() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/recording/\(harbour.rawValue)", status: 404)
        await #expect(throws: MusicBrainzError.notFound) {
            _ = try await MusicBrainzClient(transport: t, limiter: FakeClock().limiter()).recording(harbour)
        }
        let t2 = MockTransport()
        t2.stub(pathSuffix: "/recording/\(harbour.rawValue)", status: 503)
        await #expect(throws: MusicBrainzError.http(status: 503)) {
            _ = try await MusicBrainzClient(transport: t2, limiter: FakeClock().limiter()).recording(harbour)
        }
        let t3 = MockTransport()
        t3.stub(pathSuffix: "/recording/\(harbour.rawValue)", body: json("[]"))
        await #expect(throws: MusicBrainzError.decoding) {
            _ = try await MusicBrainzClient(transport: t3, limiter: FakeClock().limiter()).recording(harbour)
        }
    }
}
