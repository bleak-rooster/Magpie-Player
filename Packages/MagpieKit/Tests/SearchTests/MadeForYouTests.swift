import Foundation
import ListenBrainzKit
import MagpieCore
import MagpieTestSupport
import MatchIndex
import Testing
@testable import Search

private func data(_ text: String) -> Data { Data(text.utf8) }

private func ref(_ id: String, _ title: String, patch: String?, date: String?) -> LBPlaylistRef {
    LBPlaylistRef(id: MBID(id)!, title: title, date: date, sourcePatch: patch)
}

private let createdFor = data("""
{"playlists":[
 {"playlist":{"identifier":"https://listenbrainz.org/playlist/83883041-9abe-440e-9aae-d37f0d384694","title":"Daily Jams for rob, 2026-10-26 Mon","date":"2026-10-25T23:03:53+00:00",
  "extension":{"https://musicbrainz.org/doc/jspf#playlist":{"additional_metadata":{"algorithm_metadata":{"source_patch":"daily-jams"}}}}}},
 {"playlist":{"identifier":"https://listenbrainz.org/playlist/5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11","title":"Weekly Exploration for rob","date":"2026-10-26T01:00:00+00:00",
  "extension":{"https://musicbrainz.org/doc/jspf#playlist":{"additional_metadata":{"algorithm_metadata":{"source_patch":"weekly-exploration"}}}}}}]}
""")

private let playlist = data("""
{"playlist":{"track":[
 {"title":"Harbour Lights","creator":"Corin Hale","duration":232000},
 {"title":"Tidal","creator":"Ines Morrow","identifier":["https://musicbrainz.org/recording/4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11"]}]}}
""")

@Suite struct MadeForYouTests {
    @Test func shelfKeepsTheNewestOfEachKindWithFriendlyTitles() {
        let refs = [
            ref("83883041-9abe-440e-9aae-d37f0d384694", "Daily Jams for rob, 2026-10-26 Mon", patch: "daily-jams", date: "2026-10-25T23:03:53+00:00"),
            ref("5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11", "Weekly Jams for rob", patch: "weekly-jams", date: "2026-10-20T01:00:00+00:00"),
            ref("6b3c9d5f-8b1c-4a72-8b1f-1d9e3e2f0c22", "Daily Jams for rob, 2026-10-27 Tue", patch: "daily-jams", date: "2026-10-26T23:03:53+00:00"),
            ref("7c4dae60-9c2d-4b83-9c20-2eaf4f301d33", "Something special", patch: nil, date: nil),
        ]
        let shelf = MadeForYou.shelf(refs)
        #expect(shelf.map(\.title) == ["Daily Jams", "Weekly Jams", "Something special"])
        #expect(shelf[0].id == MBID("6b3c9d5f-8b1c-4a72-8b1f-1d9e3e2f0c22"))   // the newer Daily Jams
        #expect(shelf[0].date != nil)
        #expect(shelf[2].date == nil)
        let many = (0..<20).map { i in
            ref(String(format: "00000000-0000-4000-8000-%012d", i), "P\(i)", patch: "patch-\(i)", date: nil)
        }
        #expect(MadeForYou.shelf(many).count == MadeForYou.shelfLimit)
    }

    @Test func libraryTracksResolveThroughTheMatchLadderOthersAreNotYet() {
        let index = MatchIndex(songs: [Song(id: "lib-1", title: "Harbour Lights", artist: "Corin Hale", album: "Saltwater Hymns",
                                            duration: 232)])
        let tracks = [
            ExternalRecording(title: "Harbour Lights", artist: "Corin Hale", duration: 233, source: .listenBrainz),
            ExternalRecording(title: "Tidal", artist: "Ines Morrow", source: .listenBrainz),
            ExternalRecording(title: "Harbour Lights", artist: "Corin Hale", duration: 400, source: .listenBrainz),
        ]
        let rows = MadeForYou.resolve(tracks, index: index)
        #expect(rows == [.library(songId: "lib-1", tracks[0]), .notYet(tracks[1]), .notYet(tracks[2])])
    }

    @Test func playlistsComeFromTheTokensUser() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/1/validate-token", body: data(#"{"valid":true,"user_name":"rob"}"#))
        t.stub(pathSuffix: "/1/user/rob/playlists/createdfor", body: createdFor)
        let made = MadeForYou(client: ListenBrainzClient(transport: t, token: "secret-token-123"))
        let shelf = await made.playlists()
        #expect(shelf.map(\.title) == ["Weekly Exploration", "Daily Jams"])   // newest first
        #expect(t.requests.allSatisfy { $0.url?.host == "api.listenbrainz.org" && $0.httpMethod == "GET" })
    }

    @Test func anyFailureLeavesTheSectionOut() async throws {
        let unauthorized = MockTransport()
        unauthorized.stub(pathSuffix: "/1/validate-token", status: 401)
        #expect(await MadeForYou(client: ListenBrainzClient(transport: unauthorized, token: "bad")).playlists().isEmpty)

        let noToken = MockTransport()
        #expect(await MadeForYou(client: ListenBrainzClient(transport: noToken, token: nil)).playlists().isEmpty)
        #expect(noToken.requests.isEmpty)

        let failing = MockTransport()
        failing.stub(pathSuffix: "/1/validate-token", body: data(#"{"valid":true,"user_name":"rob"}"#))
        failing.stub(pathSuffix: "/playlists/createdfor", status: 503)
        #expect(await MadeForYou(client: ListenBrainzClient(transport: failing, token: "tok")).playlists().isEmpty)

        let id = try #require(MBID("5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11"))
        #expect(await MadeForYou(client: ListenBrainzClient(transport: failing, token: "tok")).tracks(id, index: .empty) == nil)
    }

    @Test func tracksResolveAgainstTheIndex() async throws {
        let t = MockTransport()
        let id = try #require(MBID("5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11"))
        t.stub(pathSuffix: "/1/playlist/\(id.rawValue)", body: playlist)
        let index = MatchIndex(songs: [Song(id: "lib-1", title: "Harbour Lights", artist: "Corin Hale", album: "Saltwater Hymns",
                                            duration: 232)])
        let rows = try #require(await MadeForYou(client: ListenBrainzClient(transport: t, token: "tok")).tracks(id, index: index))
        #expect(rows.count == 2)
        guard case .library(let songId, _) = rows[0], case .notYet(let other) = rows[1] else {
            Issue.record("unexpected rows \(rows)"); return
        }
        #expect(songId == "lib-1")
        #expect(other.title == "Tidal")
    }

    @Test func aHangingServiceIsGivenUpOnQuietly() async throws {
        let made = MadeForYou(client: ListenBrainzClient(transport: HangingTransport(), token: "tok", apiTimeout: 0.05))
        #expect(await made.playlists().isEmpty)
    }
}
