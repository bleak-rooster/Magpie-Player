import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import ListenBrainzKit

/// Round 14 A1 (D84): an artist's most-listened songs worldwide, `GET /1/popularity/top-recordings-for-artist/:mbid`
/// (listenbrainz-server `webserver/views/popularity_api.py`, registered at `/1/popularity`). ListenBrainz now wants a
/// user token for its "expensive" popularity routes (`ensure_user_token_for_expensive_endpoint`). Mocked only.
@Suite struct TopRecordingsTests {
    static let portishead = MBID("8f6bd1e4-fbe1-4f50-aa9b-94c450ec0f11")!

    @Test func readsTheArtistsTopRecordings() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/1/popularity/top-recordings-for-artist/\(Self.portishead.rawValue)",
               body: Fixtures.data("top-recordings-for-artist", dir: "listenbrainz"))
        let client = ListenBrainzClient(transport: t, token: "secret-token-123")
        let rows = try await client.topRecordingsForArtist(Self.portishead)
        #expect(rows.map(\.title) == ["Glory Box", "Roads", "Sour Times"], "rows without a title, and junk, dropped")
        let glory = rows[0]
        #expect(glory.recordingMBID == MBID("e97f805a-ab48-4c52-855e-07049142113d"))
        #expect(glory.artistMBID == Self.portishead && glory.artist == "Portishead")
        #expect(glory.releaseTitle == "Dummy" && glory.releaseMBID == MBID("76df3287-6cda-33eb-8e9a-044b5e15ffdd"))
        #expect(glory.duration == 253 && glory.source == .listenBrainz)
        #expect(rows[1].releaseTitle == nil && rows[1].releaseMBID == nil)
        #expect(rows[2].recordingMBID == nil && rows[2].duration == nil && rows[2].artistMBID == Self.portishead,
                "the artist asked for when the row names none")
        let request = try #require(t.requests.first)
        #expect(request.url?.host == "api.listenbrainz.org")
        #expect(request.url?.path == "/1/popularity/top-recordings-for-artist/8f6bd1e4-fbe1-4f50-aa9b-94c450ec0f11")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token secret-token-123")
        #expect(request.httpMethod == "GET")
    }

    @Test func limitApplies() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/top-recordings-for-artist/\(Self.portishead.rawValue)",
               body: Fixtures.data("top-recordings-for-artist", dir: "listenbrainz"))
        let rows = try await ListenBrainzClient(transport: t, token: "x").topRecordingsForArtist(Self.portishead, limit: 1)
        #expect(rows.map(\.title) == ["Glory Box"])
    }

    /// Without a token ListenBrainz refuses (401): nothing is asked.
    @Test func withoutATokenNothingIsSent() async throws {
        let t = MockTransport()
        await #expect(throws: ListenBrainzError.unauthorized) {
            _ = try await ListenBrainzClient(transport: t, token: nil).topRecordingsForArtist(Self.portishead)
        }
        #expect(t.requests.isEmpty)
    }

    @Test func refusalsAndJunk() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/top-recordings-for-artist/\(Self.portishead.rawValue)", status: 401)
        await #expect(throws: ListenBrainzError.unauthorized) {
            _ = try await ListenBrainzClient(transport: t, token: "bad").topRecordingsForArtist(Self.portishead)
        }
        let junk = MockTransport()
        junk.stub(pathSuffix: "/top-recordings-for-artist/\(Self.portishead.rawValue)", body: json(#"{"error":"x"}"#))
        await #expect(throws: ListenBrainzError.decoding) {
            _ = try await ListenBrainzClient(transport: junk, token: "x").topRecordingsForArtist(Self.portishead)
        }
    }
}
