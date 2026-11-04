import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 14 A4 (D92): the Recommended page's rails, as Aurral's own web page groups them (recommendedRails.ts).
@Suite struct RecommendedRailsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func artist(_ name: String, depth: Int = 1, seeds: [String] = [], daysAgo: Double = 30, tags: [String] = ["indie"])
        -> AurralRecommendedArtist {
        AurralRecommendedArtist(mbid: nil, name: name, tags: tags, sourceArtists: seeds, supportingSeeds: seeds,
                                discoveryDepth: depth, firstDiscoveredAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    var sample: AurralRecommendations {
        var artists = [artist("Top", seeds: ["Seed A"])]
        artists += (1...4).map { artist("A\($0)", seeds: ["Seed A"]) }
        artists += (1...3).map { artist("B\($0)", seeds: ["Seed B"]) }   // only 3 picks: no rail
        artists += [artist("New One", daysAgo: 2), artist("Far", depth: 2, seeds: ["Seed B"]), artist("Plain")]
        return AurralRecommendations(artists: artists, globalTop: [], basedOn: [.init(name: "Seed B"), .init(name: "Seed A")],
                                     topTags: [], topGenres: [], lastUpdated: nil, isEnriching: false, configured: true)
    }

    @Test func railsGroupLikeAurralsPage() {
        let rails = RecommendedRails(sample, now: now)
        #expect(rails.topPick?.name == "Top")
        #expect(rails.newThisWeek.map(\.name) == ["New One"])
        #expect(rails.becauseYouLike.map(\.seed) == ["Seed A"], "a seed needs at least four picks")
        #expect(rails.becauseYouLike.first?.artists.map(\.name) == ["A1", "A2", "A3", "A4"])
        #expect(rails.furtherOut.map(\.name) == ["Far"])
        #expect(rails.closeToHome.map(\.name) == ["B1", "B2", "B3", "Plain"], "what no rail above showed, depth 1")
        #expect(rails.all.count == 11)
    }

    @Test func atMostThreeSeedRows() {
        var artists = [artist("Top")]
        for seed in ["S1", "S2", "S3", "S4"] { artists += (1...4).map { artist("\(seed)-\($0)", seeds: [seed]) } }
        let recs = AurralRecommendations(artists: artists, globalTop: [], basedOn: [], topTags: [], topGenres: [],
                                         lastUpdated: nil, isEnriching: false, configured: true)
        #expect(RecommendedRails(recs, now: now).becauseYouLike.map(\.seed) == ["S1", "S2", "S3"])
        #expect(RecommendedRails(recs, now: now, seedRows: 1).becauseYouLike.count == 1)
    }

    @Test func hiddenArtistsLeaveEveryRail() {
        let rails = RecommendedRails(sample, now: now, hidden: ["name:top", "name:far"])
        #expect(rails.topPick?.name == "A1")
        #expect(rails.furtherOut.isEmpty && !rails.all.contains { $0.name == "Top" })
    }

    @Test func sortingAll() {
        let rails = RecommendedRails(sample, now: now)
        #expect(rails.sorted(.rank).first?.name == "Top")
        #expect(rails.sorted(.name).prefix(2).map(\.name) == ["A1", "A2"])
        #expect(rails.sorted(.firstSeen).first?.name == "New One")
    }

    @Test func subtitles() {
        #expect(RecommendedRails.subtitle(artist("x", seeds: ["Seed A", "Seed B", "Seed C"])) == "Like Seed A, Seed B")
        #expect(RecommendedRails.subtitle(artist("x", depth: 3, seeds: ["Seed A"])) == "Via Seed A")
        #expect(RecommendedRails.subtitle(artist("x", tags: ["dream pop"])) == "Dream pop")
        #expect(RecommendedRails.subtitle(artist("x", tags: [])) == nil)
        #expect(RecommendedRails.key(artist("Mixed Case")) == "name:mixed case")
    }
}

/// Round 14 A4 (D94): Add flow's synced playlists are listed beside the flows (`sharedPlaylists`), the user's only.
@Suite struct SyncedPlaylistStatusTests {
    @Test func sharedPlaylistsDecodeAndScope() throws {
        let json = #"{"flows":[{"id":"f1","name":"Weekly","ownerUserId":1,"autoDownload":false}],"sharedPlaylists":[{"id":"static-9","name":"Indie Pop Picks","ownerUserId":1,"trackCount":40},{"id":7,"name":"Theirs","ownerUserId":2},{"name":"No id"},"junk"],"flowStats":{"static-9":{"total":40,"done":12,"pending":28}}}"#
        let status = try AurralStatus.decode(Data(json.utf8))
        #expect(status.flows.first?.autoDownload == false)
        #expect(status.sharedPlaylists.map(\.id) == ["static-9", "7"])
        #expect(status.sharedPlaylists.first?.size == 40)
        let mine = status.scoped(to: AurralUser(id: 1, username: "me", role: "user"))
        #expect(mine.sharedPlaylists.map(\.id) == ["static-9"] && mine.flowStats["static-9"]?.done == 12)
        #expect(status.scoped(to: nil).sharedPlaylists.isEmpty, "no user, nothing")
    }

    /// Fix round 1 (M1): upstream 2.13's item: a UUID id, owner, `trackCount`, and `importSource.provider`.
    @Test func importSourceProviderDecodes() throws {
        let json = #"{"sharedPlaylists":[{"id":"5b9e0c1a-1111-4222-8333-444455556666","name":"Indie Pop Picks","ownerUserId":1,"ownerUsername":"me","trackCount":40,"importSource":{"provider":"deezer-playlist","syncEnabled":true,"syncIntervalHours":24,"keepRemovedTracks":true}},{"id":"6c","name":"Road","ownerUserId":1,"importSource":{"provider":"spotify-playlist"}},{"id":"7d","name":"Mine","ownerUserId":1,"importSource":null}]}"#
        let shared = try AurralStatus.decode(Data(json.utf8)).sharedPlaylists
        #expect(shared.map(\.importProvider) == ["deezer-playlist", "spotify-playlist", nil])
        #expect(shared.first?.ownerUsername == "me" && shared.first?.size == 40)
    }

    /// Fix round 1 (I1): 2.13 queues the creation. Until it runs, the status doesn't list it and its jobs are 404 (nil).
    @Test func addFlowIsQueuedThenListedWithItsSongs() async throws {
        let stub = StubAurral()
        stub.useAurral213()
        stub.setSyncedCreationDelay(reads: 2)
        let client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
        let added = try await client.addEditorialPlaylist("908622995")
        let id = StubAurral.syncedId("908622995")
        #expect(added.playlistId == id && added.tracksQueued == 4)
        #expect(try await client.playlistJobs(id) == nil, "queued: not there yet")
        #expect(try await client.status().sharedPlaylists.isEmpty)
        #expect(try await client.status().sharedPlaylists.isEmpty)
        let status = try await client.status()
        #expect(status.sharedPlaylists.map(\.name) == ["Indie Pop Picks"])
        #expect(status.sharedPlaylists.first?.importProvider == "deezer-playlist")
        let jobs = try #require(try await client.playlistJobs(id))
        #expect(jobs.map(\.status) == ["done", "done", "downloading", "failed"])
        _ = try await client.retrySong(playlistId: id, jobId: jobs[3].id)
        #expect(try await client.playlistJobs(id)?.last?.status == "pending")
        #expect(try await client.playlistJobs("00000000-0000-4000-8000-000000000000") == nil, "unknown: 404 for an admin too")
    }
}
