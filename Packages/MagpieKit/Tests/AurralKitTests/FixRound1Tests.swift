import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

private let rec1 = MBID("0383dadf-2a4e-4d10-a46a-e9e041da8eb3")!

private func playlist(_ id: String, _ name: String) -> Playlist {
    Playlist(id: id, name: name, songCount: 10, duration: 0, owner: "admin")
}

private func song(_ id: String, _ title: String, _ artist: String, _ duration: TimeInterval, mbid: MBID? = nil) -> Song {
    Song(id: id, title: title, artist: artist, album: "A", duration: duration, recordingMBID: mbid)
}

/// Y6 fix I1: a playlist is Discover's only when its name is a flow's AND its songs are the flow's (most of them).
@Suite struct ConfirmedFlowPlaylistTests {
    let flow = AurralFlow(id: "f1", name: "Discover Weekly")
    let jobs = [AurralJob(id: "1", flowId: "f1", artistName: "Low", trackName: "Lullaby", trackMBID: rec1, status: "done"),
                AurralJob(id: "2", flowId: "f1", artistName: "Low", trackName: "Words", durationMs: 200_000, status: "done"),
                AurralJob(id: "3", flowId: "f2", artistName: "Elsewhere", trackName: "Other", status: "done")]

    @Test func confirmedByContent() {
        let real = DiscoverPlaylist(flow: flow, playlist: playlist("real", "Discover Weekly"))
        let mine = DiscoverPlaylist(flow: flow, playlist: playlist("mine", "Discover Weekly"))
        let empty = DiscoverPlaylist(flow: flow, playlist: playlist("empty", "Discover Weekly"))
        let entries: [String: [Song]] = [
            "real": [song("a1", "Lullaby (x)", "LOW", 251, mbid: rec1), song("a2", "Words", "Low", 201), song("a3", "New", "Z", 100)],
            "mine": [song("m1", "Some Song", "Someone", 200), song("m2", "Words", "Low", 260)],
            "empty": [],
        ]
        let confirmed = DiscoverRules.confirmedFlowPlaylists([mine, real, empty], entries: entries, jobs: jobs, aurralSongIds: [])
        #expect(confirmed.map(\.playlist.id) == ["real"], "2 of 3 are the flow's; the owner's has none (Words is 60 s off)")
    }

    /// Songs known to be in Aurral's library count too (an Aurral without the jobs route).
    @Test func confirmedByAurralLibrary() {
        let real = DiscoverPlaylist(flow: flow, playlist: playlist("real", "Discover Weekly"))
        let entries = ["real": [song("a1", "X", "Y", 1), song("a2", "Z", "W", 2)]]
        #expect(DiscoverRules.confirmedFlowPlaylists([real], entries: entries, jobs: [], aurralSongIds: ["a1"]).isEmpty,
                "half isn't most")
        #expect(DiscoverRules.confirmedFlowPlaylists([real], entries: entries, jobs: [], aurralSongIds: ["a1", "a2"])
            .map(\.playlist.id) == ["real"])
    }

    /// Several candidates for one flow: only the best.
    @Test func bestCandidatePerFlow() {
        let a = DiscoverPlaylist(flow: flow, playlist: playlist("a", "Discover Weekly"))
        let b = DiscoverPlaylist(flow: flow, playlist: playlist("b", "admin - Discover Weekly"))
        let entries = ["a": [song("1", "Lullaby", "Low", 251, mbid: rec1), song("2", "Q", "Q", 1), song("3", "Words", "Low", 200)],
                       "b": [song("1", "Lullaby", "Low", 251, mbid: rec1), song("3", "Words", "Low", 200)]]
        #expect(DiscoverRules.confirmedFlowPlaylists([a, b], entries: entries, jobs: jobs, aurralSongIds: [])
            .map(\.playlist.id) == ["b"])
    }

    /// M3: a job is a song's only with the duration within 3 s when both are known, and only in its flow.
    @Test func jobRecordingNeedsTheDuration() {
        let jobs = [AurralJob(id: "1", flowId: "f1", artistName: "Low", trackName: "Lullaby", trackMBID: rec1,
                              durationMs: 251_000)]
        #expect(DiscoverRules.jobRecording(for: song("e", "Lullaby", "Low", 252), jobs: jobs, flowId: nil) == rec1)
        #expect(DiscoverRules.jobRecording(for: song("e", "Lullaby", "Low", 300), jobs: jobs, flowId: nil) == nil)
        #expect(DiscoverRules.jobRecording(for: song("e", "Lullaby", "Low", 252), jobs: jobs, flowId: "f2") == nil)
    }
}

@Suite struct FlowIdFixTests {
    /// Aurral's real flow ids are UUIDs: allowed; anything with "/", "?" or "%" isn't.
    @Test func uuidFlowIdsAreAllowed() async throws {
        let stub = StubAurral()
        let client = AurralClient(base: stub.base, apiKey: stub.apiKey, transport: stub, log: { _ in })
        let id = "8f0c2a4e-1b7d-4f7a-9a51-3c2e6d0b9f12"
        stub.setFlows([.init(id: id, name: "Discover Weekly")])
        #expect(try await client.startFlow(id).queued)
        #expect(stub.asked == ["POST /api/playlists/start/\(id)"])
        for bad in [id + "/x", id + "?a=1", id + "%2F", "%" + id] {
            #expect(!AurralRoute.isAllowed(method: "POST", path: "api/playlists/start/" + bad), "\(bad)")
        }
        let status = try await client.status()
        #expect(status.flows.first?.lastRunAt != nil, "lastRunAt is read (Refresh Flow's latch)")
    }
}
