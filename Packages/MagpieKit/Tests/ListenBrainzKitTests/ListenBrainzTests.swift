import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import ListenBrainzKit

@Suite struct LBTests {
    @Test func labsSearchMaps() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/recording-search/json", body: Fixtures.data("labs-recording-search", dir: "listenbrainz"))
        let client = ListenBrainzClient(transport: t, token: nil)
        let rows = try await client.searchRecordings("harbour lights")
        #expect(rows.count >= 5)
        let judie = try #require(rows.first { $0.artist == "Judie Tzuke" })
        #expect(judie.title == "Harbour Lights")
        #expect(judie.releaseTitle == "The Cat Is Out")
        #expect(judie.recordingMBID == MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d"))
        #expect(judie.source == .listenBrainz)
        #expect(rows.allSatisfy { $0.recordingMBID != nil })
        let url = try #require(t.requests.first?.url)
        #expect(url.host == "labs.api.listenbrainz.org")
        #expect(url.query == "query=harbour%20lights")
    }

    @Test func limitApplies() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/recording-search/json", body: Fixtures.data("labs-recording-search", dir: "listenbrainz"))
        let rows = try await ListenBrainzClient(transport: t, token: nil).searchRecordings("harbour lights", limit: 2)
        #expect(rows.count == 2)
    }

    @Test func tokenNeverSentToLabs() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/recording-search/json", body: json("[]"))
        t.stub(pathSuffix: "/playlists/createdfor", body: Fixtures.data("createdfor", dir: "listenbrainz"))
        let client = ListenBrainzClient(transport: t, token: "secret-token-123")
        _ = try await client.searchRecordings("anything")
        _ = try await client.createdForPlaylists(user: "rob")
        let labs = try #require(t.requests.first { $0.url?.host == "labs.api.listenbrainz.org" })
        #expect(labs.allHTTPHeaderFields?.isEmpty == false)
        #expect(labs.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!(labs.url?.absoluteString.contains("secret-token-123") ?? true))
        for (k, v) in labs.allHTTPHeaderFields ?? [:] { #expect(!v.contains("secret-token-123"), "header \(k)") }
        let api = try #require(t.requests.first { $0.url?.host == "api.listenbrainz.org" })
        #expect(api.value(forHTTPHeaderField: "Authorization") == "Token secret-token-123")
    }

    @Test func badRowsDroppedAndStringsCapped() async throws {
        let long = String(repeating: "x", count: 900)
        let body = json("""
        [{"recording_name":"Good","recording_mbid":"c2272a15-8f3a-4cdc-8f32-7e723352d44d","artist_credit_name":"A"},
         {"recording_name":"Bad mbid","recording_mbid":"nope","artist_credit_name":"B"},
         {"recording_name":"","artist_credit_name":"C"},
         {"recording_name":"No artist"},
         "garbage", 42, null,
         {"recording_name":"\(long)","artist_credit_name":"D","release_name":"\(long)"}]
        """)
        let t = MockTransport()
        t.stub(pathSuffix: "/recording-search/json", body: body)
        let rows = try await ListenBrainzClient(transport: t, token: nil).searchRecordings("q")
        #expect(rows.map(\.artist) == ["A", "B", "D"])
        #expect(rows[1].recordingMBID == nil)
        #expect(rows[2].title.count == 500)
        #expect(rows[2].releaseTitle?.count == 500)
    }

    @Test func labsErrorsAndNonArrayThrow() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/recording-search/json", status: 503)
        await #expect(throws: ListenBrainzError.http(status: 503)) {
            _ = try await ListenBrainzClient(transport: t, token: nil).searchRecordings("q")
        }
        let t2 = MockTransport()
        t2.stub(pathSuffix: "/recording-search/json", body: json("{\"a\":1}"))
        await #expect(throws: ListenBrainzError.decoding) {
            _ = try await ListenBrainzClient(transport: t2, token: nil).searchRecordings("q")
        }
    }

    @Test func labsTimesOut() async throws {
        let client = ListenBrainzClient(transport: HangingTransport(), token: nil, labsTimeout: 0.05)
        await #expect(throws: ListenBrainzError.timedOut) { _ = try await client.searchRecordings("q") }
    }

    @Test func emptyQueryMakesNoRequest() async throws {
        let t = MockTransport()
        #expect(try await ListenBrainzClient(transport: t, token: nil).searchRecordings("   ").isEmpty)
        #expect(t.requests.isEmpty)
    }

    @Test func createdForMaps() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/playlists/createdfor", body: Fixtures.data("createdfor", dir: "listenbrainz"))
        let refs = try await ListenBrainzClient(transport: t, token: "tok").createdForPlaylists(user: "rob")
        #expect(refs.count == 2)
        let daily = try #require(refs.first { $0.sourcePatch == "daily-jams" })
        #expect(daily.id == MBID("83883041-9abe-440e-9aae-d37f0d384694"))
        #expect(daily.title.hasPrefix("Daily Jams for rob"))
        #expect(daily.expiresAt != nil)
        #expect(refs.contains { $0.sourcePatch == "weekly-exploration" })
        #expect(t.requests.first?.url?.path == "/1/user/rob/playlists/createdfor")
    }

    @Test func createdForDropsBadItemsAndMapsAuthErrors() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/playlists/createdfor", body: json("""
        {"playlists":[{"playlist":{"identifier":"https://listenbrainz.org/playlist/not-a-uuid","title":"x"}},
                      {"playlist":{"title":"no id"}}, 5,
                      {"playlist":{"identifier":"https://listenbrainz.org/playlist/83883041-9abe-440e-9aae-d37f0d384694","title":"Ok"}}]}
        """))
        let refs = try await ListenBrainzClient(transport: t, token: nil).createdForPlaylists(user: "rob")
        #expect(refs.map(\.title) == ["Ok"])
        let t2 = MockTransport()
        t2.stub(pathSuffix: "/playlists/createdfor", status: 401)
        await #expect(throws: ListenBrainzError.unauthorized) {
            _ = try await ListenBrainzClient(transport: t2, token: "bad").createdForPlaylists(user: "rob")
        }
    }
}
