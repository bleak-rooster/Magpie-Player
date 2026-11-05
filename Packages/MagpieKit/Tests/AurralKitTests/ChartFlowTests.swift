import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 15 C2 (owner items 5 and 5b, D130–D134; fix round I1/I2): a flow of a chart's top N songs, as the user's own
/// Aurral playlist. Aurral 2.13: `POST /api/playlists/shared-playlists {name, sourceName, tracks}` is queued and
/// answers 200 whatever the name (a taken name fails later in the worker, so Magpie picks a free name first);
/// `POST …/:id/tracks {tracks}` adds songs; `POST …/:id/track-removals {jobIds}` takes songs out and deletes their files
/// (only in Aurral's download folder, sparing files another playlist or the library uses); `DELETE …/:id` removes it.
@Suite struct ChartFlowTests {
    let stub: StubAurral
    let client: AurralClient

    init() {
        stub = StubAurral()
        stub.useAurral213()
        stub.setSyncedCreationDelay(reads: 0)
        client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
    }

    static func songs(_ n: Int) -> [ChartFlowTrack] {
        (1...n).map { ChartFlowTrack(artistName: "Artist \($0)", trackName: "Song \($0)", albumName: "Album \($0)",
                                     durationMs: 180_000 + $0 * 1_000) }
    }

    // MARK: - The routes (pinned in AurralRoute and check-writes)

    @Test func theFourRoutesAndNothingNear() {
        #expect(AurralRoute.route(method: "POST", path: "api/playlists/shared-playlists") == .chartFlowCreate)
        #expect(AurralRoute.route(method: "POST", path: "api/playlists/shared-playlists/a4000000-0000-4000-8000-000000000001/tracks") == .chartFlowAppend)
        #expect(AurralRoute.route(method: "POST", path: "api/playlists/shared-playlists/pl_1/track-removals") == .chartFlowRemoveSongs)
        #expect(AurralRoute.route(method: "DELETE", path: "api/playlists/shared-playlists/pl_1") == .chartFlowDelete)
        for (method, path) in [("GET", "api/playlists/shared-playlists"), ("PUT", "api/playlists/shared-playlists"),
                               ("DELETE", "api/playlists/shared-playlists"), ("POST", "api/playlists/shared-playlists/pl-1"),
                               ("PUT", "api/playlists/shared-playlists/pl-1"), ("GET", "api/playlists/shared-playlists/pl-1"),
                               ("PATCH", "api/playlists/shared-playlists/pl-1"), ("DELETE", "api/playlists/shared-playlists/a b"),
                               ("PUT", "api/playlists/shared-playlists/../settings"),
                               ("GET", "api/playlists/shared-playlists/pl-1/tracks"), ("DELETE", "api/playlists/shared-playlists/pl-1/tracks"),
                               ("PUT", "api/playlists/shared-playlists/pl-1/tracks"),
                               ("GET", "api/playlists/shared-playlists/pl-1/track-removals"),
                               ("POST", "api/playlists/shared-playlists/../track-removals"),
                               ("POST", "api/playlists/shared-playlists/pl-1/sync"), ("POST", "api/playlists/shared-playlists/pl-1/track-moves"),
                               ("DELETE", "api/playlists/shared-playlists/pl-1/tracks/job-1"),
                               ("PUT", "api/playlists/shared-playlists/pl-1/track-availability")] {
            #expect(!AurralRoute.isAllowed(method: method, path: path), "\(method) \(path)")
        }
        for route in [AurralRoute.chartFlowCreate, .chartFlowAppend, .chartFlowRemoveSongs, .chartFlowDelete] {
            #expect(route.isAuthorised && route.queryNames.isEmpty, "\(route)")
        }
    }

    // MARK: - Create

    @Test func createSendsExactlyTheTopSongsAndTheStatusListsIt() async throws {
        let made = try await client.createChartFlow(name: "Top Worldwide", tracks: Self.songs(10))
        #expect(!made.playlistId.isEmpty)
        #expect(stub.asked == ["POST /api/playlists/shared-playlists"])
        let body = try #require(stub.requests.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(body.keys) == ["name", "sourceName", "tracks"])
        #expect(body["name"] as? String == "Top Worldwide" && body["sourceName"] as? String == "Charts")
        let tracks = try #require(body["tracks"] as? [[String: Any]])
        #expect(tracks.count == 10)
        #expect(Set(tracks[0].keys) == ["artistName", "trackName", "albumName", "durationMs"])
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(stub.sharedPlaylistSongs(made.playlistId)?.count == 10)
        let status = try await client.status()
        let listed = try #require(status.sharedPlaylists.first { $0.id == made.playlistId })
        #expect(listed.name == "Top Worldwide" && listed.sourceName == "Charts")
    }

    /// I1: 2.13 queues the create and answers 200 whatever the name; a taken name (a playlist **or a flow** of the
    /// user's) fails in the worker and the playlist never appears. So the client never reads a 400 as "name taken".
    @Test func aTakenNameIsAcceptedThenNeverAppears() async throws {
        stub.addSharedPlaylist(id: "own-1", name: "Top Worldwide", provider: nil, songs: [])
        let made = try await client.createChartFlow(name: "top worldwide ", tracks: Self.songs(2))
        #expect(try await client.status().sharedPlaylists.contains { $0.id == made.playlistId } == false)
        stub.setFlows([StubAurral.Flow(id: "flow-1", name: "Pop Weekly")])
        let clash = try await client.createChartFlow(name: "Pop Weekly", tracks: Self.songs(2))
        #expect(stub.sharedPlaylistSongs(clash.playlistId) == nil, "a flow's name is taken too")
        #expect(stub.chartFlowCreates.map(\.failed) == [true, true])
    }

    /// I1: the free name is picked before sending, from the names the user's playlists and flows have now
    /// (trimmed and case folded, as Aurral compares them).
    @Test func theFirstFreeName() {
        #expect(ChartFlowPlan.freeName("Top Australia", taken: []) == "Top Australia")
        #expect(ChartFlowPlan.freeName("Top Australia", taken: [" top australia", "Discover Weekly"]) == "Top Australia 2")
        #expect(ChartFlowPlan.freeName("Top Australia", taken: ["Top Australia", "TOP AUSTRALIA 2", "Top Australia 3"])
                == "Top Australia 4")
    }

    // MARK: - Shorten, extend, refresh (I2)

    /// What changes: the flow's songs no longer wanted go (their jobs), the wanted ones it lacks come.
    @Test func theChangesBetweenTheFlowAndTheTopN() {
        let jobs = (1...5).map { AurralJob(id: "job-\($0)", flowId: "pl", artistName: "Artist \($0)", trackName: "Song \($0)") }
            + [AurralJob(id: "job-9", flowId: "pl", artistName: "ARTIST 1", trackName: "song 1")]   // a repeat
        let shorter = ChartFlowPlan.changes(jobs: jobs, wanted: Array(Self.songs(5).prefix(3)))
        #expect(shorter.remove == ["job-4", "job-5", "job-9"] && shorter.add.isEmpty)
        let longer = ChartFlowPlan.changes(jobs: jobs, wanted: Self.songs(7))
        #expect(longer.remove == ["job-9"] && longer.add.map(\.trackName) == ["Song 6", "Song 7"])
        let same = ChartFlowPlan.changes(jobs: Array(jobs.prefix(5)), wanted: Self.songs(5))
        #expect(same.remove.isEmpty && same.add.isEmpty)
    }

    /// Re-review M-a: a quality-upgrade job (`upgradeForJobId`) is never the song's job: it is neither kept in place of
    /// the original nor removed (2.13 refuses to select it anyway).
    @Test func upgradeJobsAreLeftOut() throws {
        var upgrade = AurralJob(id: "job-up", flowId: "pl", artistName: "Artist 1", trackName: "Song 1")
        upgrade.upgradeForJobId = "job-1"
        let original = AurralJob(id: "job-1", flowId: "pl", artistName: "Artist 1", trackName: "Song 1")
        let change = ChartFlowPlan.changes(jobs: [upgrade, original], wanted: Array(Self.songs(1)))
        #expect(change.remove.isEmpty && change.add.isEmpty, "the original stays; the upgrade is left alone")
        let gone = ChartFlowPlan.changes(jobs: [upgrade, original], wanted: Array(Self.songs(2).suffix(1)))
        #expect(gone.remove == ["job-1"])
        let json = #"[{"id":"job-up","playlistId":"pl","artistName":"A","trackName":"T","upgradeForJobId":"job-1"}]"#
        #expect(try AurralJob.decodeList(Data(json.utf8)).first?.upgradeForJobId == "job-1")
    }

    @Test func shortenRemovesTheTailsSongsAndTheirFilesExtendAddsSongs() async throws {
        let made = try await client.createChartFlow(name: "Top Australia", tracks: Self.songs(10))
        let jobs = try #require(try await client.playlistJobs(made.playlistId))
        let tail = ChartFlowPlan.changes(jobs: jobs, wanted: Array(Self.songs(10).prefix(5)))
        let accepted = try await client.removeChartFlowSongs(playlistId: made.playlistId, jobIds: tail.remove)
        #expect(accepted == tail.remove && accepted.count == 5)
        #expect(stub.sharedPlaylistSongs(made.playlistId)?.map(\.title) == ["Song 1", "Song 2", "Song 3", "Song 4", "Song 5"])
        #expect(stub.chartFlowDeletedFiles == (6...10).map { "artist \($0)|song \($0)" }, "their files go")
        let removal = try #require(stub.requests.last)
        #expect(removal.httpMethod == "POST" && removal.url?.path == "/api/playlists/shared-playlists/\(made.playlistId)/track-removals")
        let removalBody = try #require(removal.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(removalBody.keys) == ["jobIds"] && removalBody["jobIds"] as? [String] == tail.remove)

        _ = try await client.appendChartFlowSongs(playlistId: made.playlistId, tracks: Array(Self.songs(8).suffix(3)))
        #expect(stub.sharedPlaylistSongs(made.playlistId)?.count == 8)
        let append = try #require(stub.requests.last)
        #expect(append.url?.path == "/api/playlists/shared-playlists/\(made.playlistId)/tracks")
        let appendBody = try #require(append.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(appendBody.keys) == ["tracks"])
    }

    @Test func removeDeletesItAndAGoneOneIsAlreadyRemoved() async throws {
        let made = try await client.createChartFlow(name: "Pop", tracks: Self.songs(3))
        try await client.deleteChartFlow(playlistId: made.playlistId)
        // Re-review I3: 2.13 queues the delete: the next status read still lists it, the one after doesn't.
        #expect(try await client.status().sharedPlaylists.contains { $0.id == made.playlistId })
        #expect(try await client.status().sharedPlaylists.contains { $0.id == made.playlistId } == false)
        #expect(stub.sharedPlaylistSongs(made.playlistId) == nil && stub.chartFlowDeletedFiles.count == 3)
        #expect(stub.requests.last?.httpBody == nil, "no body")
        try await client.deleteChartFlow(playlistId: made.playlistId)   // 404: already gone, nothing to do
        await #expect(throws: AurralError.notFound) {
            _ = try await client.appendChartFlowSongs(playlistId: made.playlistId, tracks: Self.songs(2))
        }
        await #expect(throws: AurralError.notFound) {
            _ = try await client.removeChartFlowSongs(playlistId: made.playlistId, jobIds: ["job-0"])
        }
    }

    @Test func withoutAccessFlowItIsRefused() async throws {
        stub.addUser(id: 2, username: "kid", password: "pw", role: "user")
        let kid = AurralClient(base: stub.base, session: AurralSession(username: "kid", password: "pw", login: nil), transport: stub)
        await #expect(throws: AurralError.notPermitted) { _ = try await kid.createChartFlow(name: "x", tracks: Self.songs(1)) }
    }

    @Test func oddIdsAndEmptyListsAreRefusedUnsent() async throws {
        for id in ["", "../settings", "a b", "a/b", String(repeating: "a", count: 101)] {
            await #expect(throws: AurralError.self, "\(id)") { _ = try await client.appendChartFlowSongs(playlistId: id, tracks: Self.songs(1)) }
            await #expect(throws: AurralError.self, "\(id)") { _ = try await client.removeChartFlowSongs(playlistId: id, jobIds: ["job-1"]) }
            await #expect(throws: AurralError.self, "\(id)") { try await client.deleteChartFlow(playlistId: id) }
        }
        for jobIds in [[String](), ["a/b"], ["../x"], Array(repeating: "job-1", count: 101)] {
            await #expect(throws: AurralError.self) { _ = try await client.removeChartFlowSongs(playlistId: "pl", jobIds: jobIds) }
        }
        await #expect(throws: AurralError.self) { _ = try await client.createChartFlow(name: "x", tracks: []) }
        await #expect(throws: AurralError.self) { _ = try await client.appendChartFlowSongs(playlistId: "pl", tracks: []) }
        await #expect(throws: AurralError.self) { _ = try await client.createChartFlow(name: "  ", tracks: Self.songs(1)) }
        await #expect(throws: AurralError.self) { _ = try await client.createChartFlow(name: "x", tracks: Self.songs(101)) }
        #expect(stub.requests.isEmpty)
    }

    // MARK: - The plan: which songs

    @Test func theTopNSkippingRepeatsAndBlanks() {
        var songs = Self.songs(6)
        songs.insert(ChartFlowTrack(artistName: "ARTIST 1", trackName: "song 1 ", albumName: nil, durationMs: nil), at: 1)
        songs.insert(ChartFlowTrack(artistName: " ", trackName: "Nameless", albumName: nil, durationMs: nil), at: 2)
        let plan = ChartFlowPlan.tracks(from: songs, count: 3)
        #expect(plan.map(\.trackName) == ["Song 1", "Song 2", "Song 3"])
        #expect(ChartFlowPlan.tracks(from: songs, count: 0).count == 1, "at least one")
        #expect(ChartFlowPlan.tracks(from: songs, count: 500).count == 6, "at most what the chart has")
        #expect(ChartFlowPlan.tracks(from: Self.songs(150), count: 150).count == ChartFlowPlan.maxSongs)
    }

    @Test func theCountsOffered() {
        #expect(ChartFlowPlan.presets(chartLength: 100) == [10, 20, 25, 50, 100])
        #expect(ChartFlowPlan.presets(chartLength: 50) == [10, 20, 25, 50])
        #expect(ChartFlowPlan.presets(chartLength: 30) == [10, 20, 25, 30])
        #expect(ChartFlowPlan.presets(chartLength: 4) == [4])
        #expect(ChartFlowPlan.presets(chartLength: 0) == [])
        #expect(ChartFlowPlan.defaultCount(chartLength: 100) == 25 && ChartFlowPlan.defaultCount(chartLength: 12) == 12)
    }

    // MARK: - Each chart its own flow (D133)

    @Test func eachChartHasItsOwnFlowAndCount() throws {
        var book = ChartFlowBook()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        book.set(ChartFlow(chartKey: "worldwide", playlistId: "pl-w", name: "Top Worldwide", count: 10, createdAt: now, refreshedAt: now))
        book.set(ChartFlow(chartKey: "country:AU", playlistId: "pl-au", name: "Top Australia", count: 50, createdAt: now, refreshedAt: now))
        book.set(ChartFlow(chartKey: "genre:132", playlistId: "pl-pop", name: "Pop", count: 20, createdAt: now, refreshedAt: now))
        #expect(book.flow(for: "worldwide")?.count == 10 && book.flow(for: "country:AU")?.count == 50)
        var smaller = try #require(book.flow(for: "worldwide"))
        smaller.count = 5
        book.set(smaller)
        #expect(book.flow(for: "worldwide")?.count == 5 && book.flow(for: "country:AU")?.count == 50, "only that chart")
        #expect(book.playlistIds == ["pl-w", "pl-au", "pl-pop"])
        book.remove("country:AU")
        #expect(book.flow(for: "country:AU") == nil && book.playlistIds == ["pl-w", "pl-pop"])
        let decoded = try JSONDecoder().decode(ChartFlowBook.self, from: try JSONEncoder().encode(book))
        #expect(decoded == book)
        #expect(book.chartKey(forPlaylist: "pl-pop") == "genre:132")
        #expect(book.flow(for: "worldwide")?.confirmed == false, "not seen on the server yet")
        // Re-review I3: a removed (or retried-away) playlist is remembered so it's never taken back.
        book.noteRemoved("pl-w")
        #expect(book.wasRemoved("pl-w") && !book.wasRemoved("pl-pop"))
        #expect(try JSONDecoder().decode(ChartFlowBook.self, from: try JSONEncoder().encode(book)).wasRemoved("pl-w"))
        for n in 0..<300 { book.noteRemoved("x-\(n)") }
        #expect(book.wasRemoved("x-299") && !book.wasRemoved("pl-w"), "the list stays small: the oldest go")
    }

    /// M3: one entry a later build wrote that this one can't read never costs the others.
    @Test func aBookWithAnUnreadableEntryKeepsTheRest() throws {
        let json = #"{"flows":[{"chartKey":"worldwide","playlistId":"pl-w","name":"Top Worldwide","count":10,"createdAt":0,"refreshedAt":0,"confirmed":true},{"chartKey":7},{"chartKey":"genre:132","playlistId":"pl-pop","name":"Top Pop","count":3,"createdAt":0,"refreshedAt":0}]}"#
        let book = try JSONDecoder().decode(ChartFlowBook.self, from: Data(json.utf8))
        #expect(book.playlistIds == ["pl-w", "pl-pop"] && book.flow(for: "worldwide")?.confirmed == true)
        #expect(book.flow(for: "genre:132")?.confirmed == false)
    }
}
