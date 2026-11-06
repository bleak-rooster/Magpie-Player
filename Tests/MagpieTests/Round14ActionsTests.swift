import AurralKit
import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Requests
import Search
import Testing
@testable import Magpie

private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let stubArtist = MBID("a74b1b7f-71a5-4011-9441-d0b5e4122711")!
private let harbourRecording = MBID("5e0c3c2a-1111-4a6e-9d2c-7b1a2f3e4d51")!
private let releaseMBID = MBID("b5cdfb5f-35a5-4bc5-bbca-57839a71813a")!

private func okBody(_ body: String = "") -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(body.isEmpty ? "" : "," + body)}}"#.utf8)
}

private func queryValue(_ r: URLRequest, _ name: String) -> String? {
    URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

/// Round 14 A3 (D100–D104): an outside song's ⋯ menu (Listen to the full song, Add artist, Save to playlist), the
/// pending playlist adds ("Coming"), previews for songs the server didn't list, and the Artist top songs setting, in
/// the app against StubAurral 2.13 and a mock Navidrome (and Lidarr's and ListenBrainz's hosts on the same mock).
@MainActor @Suite(.serialized) final class Round14ActionsTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "Round14ActionsTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "Round14ActionsTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = Round14Routing()
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    var aurral: StubAurral { transport.aurral }

    func model(aurralSetUp: Bool = true, lidarr: Bool = false, listenBrainzToken: String? = nil) async throws -> AppModel {
        aurral.useAurral213()
        nav.install(on: transport.navidrome)
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: lidarrBase, apiKey: "dev-key")) }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(listenBrainzToken),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), previewTransport: transport, defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        model.aurralFeeds.phoneRegion = { nil }
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if aurralSetUp {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return model
    }

    /// The stub's No. 1: "Harbour Lights" by Stub Arrows, 196 s, preview 3135556.
    private var harbour: OutsideSong {
        OutsideSong(title: "Harbour Lights", artist: "Stub Arrows", album: "Harbour Lights (Single)", duration: 196,
                    deezerAlbumId: "3136556", previewId: "3135556")
    }

    /// MusicBrainz, as the outside pages read it: the release group's chosen release, with a track of `length` s.
    private func catalog(_ model: AppModel, length: TimeInterval?) {
        model.outsideCatalogStore = OutsideCatalog(releaseGroups: { _ in [] }, releases: { _ in
            [MBReleaseDetail(id: releaseMBID, title: "Harbour Lights", date: "2024", status: "Official",
                             tracks: [MBTrack(recording: harbourRecording, title: "Harbour Lights", length: length)])]
        })
    }

    /// S14 M2: Lidarr's lookup of the server's linked artist answers with `name`.
    private func lidarrNames(_ name: String) {
        let body = Data("[{\"foreignArtistId\":\"\(stubArtist.rawValue)\",\"artistName\":\"\(name)\"}]".utf8)
        transport.navidrome.stub(pathSuffix: "/api/v1/artist/lookup", body: body)
    }

    private var playlistWrites: [URLRequest] { transport.navidrome.requests.filter { $0.url?.path.hasSuffix("/rest/updatePlaylist") == true } }

    // MARK: - Setups (owner answer 9)

    @Test func theMenuShowsOnlyWithLidarr() async throws {
        let navidromeOnly = try await model(aurralSetUp: false)
        #expect(!navidromeOnly.outsideSongMenuAvailable && !navidromeOnly.previewsAvailable)
        navidromeOnly.signOut()
        let withAurral = try await model()
        #expect(!withAurral.outsideSongMenuAvailable && withAurral.previewsAvailable)
        withAurral.signOut()
        let withLidarr = try await model(aurralSetUp: false, lidarr: true)
        #expect(withLidarr.outsideSongMenuAvailable && !withLidarr.previewsAvailable)
        withLidarr.signOut()
        let all = try await model(lidarr: true)
        defer { all.signOut() }
        #expect(all.outsideSongMenuAvailable && all.previewsAvailable)
        #expect(!all.justThisSongAvailable, "Lidarr's setup not read yet: no Tubifarry")
        all.lidarrStatus = LidarrAudit(reachable: true, tubifarry: true)
        #expect(all.justThisSongAvailable)
    }

    // MARK: - Listen to the full song (owner answer 8)

    @Test func listenToTheFullSongMatchesTheRecordingThenOpensTheFind() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        catalog(model, length: 197)
        lidarrNames("Stub Arrows")
        await model.listenToFullSong(harbour)
        let target = try #require(model.songActions.trying)
        #expect(target.recording.recordingMBID == harbourRecording && target.recording.artistMBID == stubArtist)
        #expect(target.recording.releaseMBID == releaseMBID && model.songActions.unmatched == nil)
        #expect(aurral.asked.contains { $0.hasPrefix("GET /api/discover/editorial/links") }, "the MBIDs come through the server")
        #expect(!aurral.asked.contains { $0.hasPrefix("POST /api/library") }, "never the server's own downloader (Decision 1)")
    }

    @Test func aSongThatCantBeMatchedSaysSoWithSearchInstead() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        catalog(model, length: 240)   // the same title, another length: not this recording
        await model.listenToFullSong(harbour)
        #expect(model.songActions.trying == nil && model.songActions.unmatched == harbour)
        #expect(SongActionsCopy.unmatchedTitle == "Couldn\u{2019}t match this song")
    }

    // MARK: - Save to playlist (Decisions 4 and 5)

    @Test func justThisSongNeedsTubifarry() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        catalog(model, length: 196)
        model.askToSave(harbour)
        #expect(model.songActions.choosing == harbour)
        model.choose(.justThisSong, for: harbour)
        #expect(model.songActions.picking == nil, "without Tubifarry only Whole artist is offered")
        let playlist = try #require(try await model.editablePlaylists().first { $0.id == "pl-road" })
        #expect(await model.save(harbour, choice: .justThisSong, to: playlist) == SongActionsCopy.noJustThisSong)
        #expect(model.songActions.pending.isEmpty && model.requests.isEmpty)
        model.choose(.wholeArtist, for: harbour)
        #expect(model.songActions.picking?.choice == .wholeArtist)
    }

    @Test func wholeArtistAsksTheUsualAddAndWaitsOnlyOnceItWentThrough() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        model.outsideCatalogStore = OutsideCatalog(releaseGroups: { _ in [] }, releases: { _ in
            Issue.record("Whole artist never reads MusicBrainz")
            return []
        })
        lidarrNames("Stub Arrows")
        let playlist = try #require(try await model.editablePlaylists().first { $0.id == "pl-road" })
        #expect(await model.save(harbour, choice: .wholeArtist, to: playlist) == nil)
        // Fix round 1: the Add waits for the picker to finish closing (the presenter's onDismiss hands it over).
        #expect(model.songActions.wholeArtistAdd == nil)
        model.songActions.presentQueuedAdd()
        let add = try #require(model.songActions.wholeArtistAdd)
        #expect(add.artist == "Stub Arrows" && add.candidates.map(\.mbid) == [stubArtist])
        #expect(model.songActions.pending.isEmpty, "nothing waits before the Add is confirmed")
        // Magpie isn't set up in this Lidarr: the Add fails, so nothing waits.
        let outcome = await add.commit(model.newMusic.whenYouAdd, add.candidates.first, nil, false)
        #expect(!outcome.succeeded && model.songActions.pending.isEmpty)
    }

    // MARK: - S14 M2 (D116): the server's linked artist is checked against Lidarr's name for it

    @Test func wholeArtistRefusesALinkedArtistLidarrNamesOtherwise() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        lidarrNames("Somebody Else")
        let playlist = try #require(try await model.editablePlaylists().first { $0.id == "pl-road" })
        #expect(await model.save(harbour, choice: .wholeArtist, to: playlist) == SongActionsCopy.unmatchedArtist)
        model.songActions.presentQueuedAdd()
        #expect(model.songActions.wholeArtistAdd == nil && model.songActions.pending.isEmpty)
        let lookups = transport.navidrome.requests.filter { $0.url?.path.hasSuffix("/api/v1/artist/lookup") == true }
        #expect(lookups.contains { queryValue($0, "term") == "lidarr:" + stubArtist.rawValue })
    }

    @Test func wholeArtistRefusesALinkedArtistLidarrDoesntKnow() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        transport.navidrome.stub(pathSuffix: "/api/v1/artist/lookup", body: Data("[]".utf8))
        let playlist = try #require(try await model.editablePlaylists().first { $0.id == "pl-road" })
        #expect(await model.save(harbour, choice: .wholeArtist, to: playlist) == SongActionsCopy.unmatchedArtist)
    }

    @Test func addArtistDropsALinkedArtistLidarrNamesOtherwise() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        lidarrNames("Somebody Else")
        await model.addArtist(of: harbour)
        let ids = Set(model.songActions.adder.lines.keys)
        #expect(!ids.contains(stubArtist.rawValue), "the unchecked MBID is never used")
        #expect(ids == [DiscoverArtist(name: "Stub Arrows", mbid: nil).id], "Lidarr's search by the exact name instead")
    }

    @Test func listenKeepsTheLinkedArtistOnlyWhenItChecksOut() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        catalog(model, length: 197)
        lidarrNames("Somebody Else")
        await model.listenToFullSong(harbour)
        let target = try #require(model.songActions.trying)
        #expect(target.recording.recordingMBID == harbourRecording && target.recording.artistMBID == nil,
                "the request takes MusicBrainz's own artist for the recording")
    }

    // MARK: - Pending adds (Decision 5)

    private func pending(request: RequestID?, mbid: MBID? = harbourRecording, duration: TimeInterval = 196) -> PendingPlaylistAdd {
        PendingPlaylistAdd(playlistId: "pl-road", playlistName: "Road trip",
                           recording: ExternalRecording(recordingMBID: mbid, artistMBID: stubArtist, title: "Harbour Lights",
                                                        artist: "Stub Arrows", duration: duration, source: .lidarr),
                           requestId: request, createdAt: Date())
    }

    private func readyRequest(find: Bool = false, state: RequestState = .ready, songId: String = "m-harbour") -> MagpieRequest {
        var r = MagpieRequest(recording: ExternalRecording(recordingMBID: harbourRecording, title: "Harbour Lights",
                                                           artist: "Stub Arrows", duration: 196, source: .lidarr),
                              tier: .standard, createdAt: Date())
        r.state = state
        r.songId = songId
        if find {
            r.plan = Plan(recordingMBID: harbourRecording, releaseGroupMBID: harbourRecording, artistMBID: stubArtist,
                          lidarrArtistId: nil, mode: .finds)
        }
        return r
    }

    private func addSong(_ id: String, duration: Int, mbid: String? = nil) {
        nav.songs[id] = .init(id: id, title: "Harbour Lights", artist: "Stub Arrows", duration: duration, mbid: mbid, library: 1)
    }

    @Test func anArrivedSongIsAddedToThePlaylistOnce() async throws {
        let model = try await model()
        defer { model.signOut() }
        addSong("m-harbour", duration: 196)
        let request = readyRequest()
        model.requests = [request]
        model.songActions.requestsLoaded = true   // the list stands in for a runner's published one
        model.songActions.pending = [pending(request: request.id)]
        #expect(model.pendingAdds(for: "pl-road").first?.step == .add(songId: "m-harbour"))
        await model.evaluatePendingAdds()
        #expect(playlistWrites.count == 1 && queryValue(playlistWrites[0], "songIdToAdd") == "m-harbour")
        #expect(nav.lists["pl-road"]?.songs.last == "m-harbour" && model.songActions.pending.isEmpty)
        await model.evaluatePendingAdds()
        #expect(playlistWrites.count == 1, "never twice")
    }

    @Test func aFindIsKeptBeforeItJoinsThePlaylist() async throws {
        let model = try await model()
        defer { model.signOut() }
        let find = readyRequest(find: true)
        model.requests = [find]
        model.songActions.requestsLoaded = true
        model.songActions.pending = [pending(request: find.id)]
        await model.evaluatePendingAdds()
        #expect(model.songActions.keepAttempts.first == find.id, "Just this song: kept on arrival (Decision 4)")
        #expect(playlistWrites.isEmpty, "not added while it's still a find")
        var kept = find
        kept.state = .kept
        kept.relinkPending = false
        kept.songId = "m-harbour"
        addSong("m-harbour", duration: 196)
        model.requests = [kept]
        await model.evaluatePendingAdds()
        #expect(playlistWrites.count == 1 && model.songActions.pending.isEmpty)
    }

    @Test func aStoppedRequestOffersRetryAndRemove() async throws {
        let model = try await model()
        defer { model.signOut() }
        let failed = readyRequest(state: .failed(reason: .noRelease))
        model.requests = [failed]
        model.songActions.requestsLoaded = true
        let add = pending(request: failed.id)
        model.songActions.pending = [add]
        await model.evaluatePendingAdds()
        let row = try #require(model.pendingAdds(for: "pl-road").first)
        #expect(row.step == .failed && row.add.failedAt != nil)
        #expect(SongActionsCopy.status(row.step, playlistGone: false) == "Couldn\u{2019}t bring it in")
        await model.removePending(add.id)
        #expect(model.pendingAdds(for: "pl-road").isEmpty && playlistWrites.isEmpty)
    }

    @Test func wholeArtistIsNeverMatchedByNameAlone() async throws {
        let model = try await model()
        defer { model.signOut() }
        addSong("m-live", duration: 230)   // same title and artist, a longer (live) take
        let add = pending(request: nil, mbid: nil)
        model.songActions.requestsLoaded = true
        model.songActions.pending = [add]
        await model.evaluatePendingAdds(force: true)
        #expect(playlistWrites.isEmpty && model.songActions.pending.count == 1)
        #expect(model.pendingAdds(for: "pl-road").first?.step == .lookUp)
        addSong("m-harbour", duration: 197)
        await model.evaluatePendingAdds(force: true)
        #expect(playlistWrites.count == 1 && queryValue(playlistWrites[0], "songIdToAdd") == "m-harbour")
    }

    @Test func aWriteSentBeforeARelaunchIsReadFirst() async throws {
        let model = try await model()
        defer { model.signOut() }
        addSong("m-harbour", duration: 196)
        nav.lists["pl-road"]?.songs.append("m-harbour")   // the add landed; its answer was lost
        let request = readyRequest()
        model.requests = [request]
        model.songActions.requestsLoaded = true   // the list stands in for a runner's published one
        var add = pending(request: request.id)
        add.sendingSongId = "m-harbour"
        model.songActions.pending = [add]
        await model.evaluatePendingAdds()
        #expect(playlistWrites.isEmpty && model.songActions.pending.isEmpty)
    }

    @Test func aPlaylistThatWentOffersRemoveOnly() async throws {
        let model = try await model()
        defer { model.signOut() }
        addSong("m-harbour", duration: 196)
        let request = readyRequest()
        model.requests = [request]
        model.songActions.requestsLoaded = true   // the list stands in for a runner's published one
        var add = pending(request: request.id)
        add.playlistId = "pl-gone"
        model.songActions.pending = [add]
        await model.evaluatePendingAdds()
        let row = try #require(model.pendingAdds(for: "pl-gone").first)
        #expect(row.add.playlistGone == true && row.step == .failed && playlistWrites.isEmpty)
    }

    @Test func pendingAddsAreKeptPerLidarrAndSurviveARelaunch() async throws {
        let url = PlaylistAddStore.defaultURL(in: tmp, instance: "lidarr-a")
        let add = pending(request: nil)
        try await PlaylistAddStore(fileURL: url).save([add])
        let model = try await model()
        defer { model.signOut() }
        model.followPendingAdds(instance: "lidarr-a")
        #expect(await eventually { model.songActions.pending.map(\.id) == [add.id] })
        model.followPendingAdds(instance: "lidarr-b")
        #expect(model.songActions.pending.isEmpty, "another Lidarr's adds never show")
    }

    // MARK: - Previews for songs the server didn't list (owner answer 7)

    @Test func aListenBrainzSongGetsAPreviewOnlyWhenItIsTheSameSong() async throws {
        let model = try await model()
        defer { model.signOut() }
        let same = ExternalRecording(recordingMBID: harbourRecording, artistMBID: stubArtist, title: "Harbour Lights",
                                     artist: "Stub Arrows", duration: 198, source: .listenBrainz)
        #expect(await model.previewSong(for: same)?.preview?.trackId == "3135556")
        var longer = same
        longer.duration = 260
        #expect(await model.previewSong(for: longer) == nil, "no preview available; nothing guessed")
        var unknown = same
        unknown.title = "Harbour"
        #expect(await model.previewSong(for: unknown) == nil)
        #expect(aurral.asked.filter { $0.contains("/preview") && $0.contains("/api/artists/") }.count == 1,
                "the artist's previews are read once per session")
    }

    @Test func withoutAurralThereAreNoPreviewControls() async throws {
        let model = try await model(aurralSetUp: false, lidarr: true)
        defer { model.signOut() }
        let r = ExternalRecording(recordingMBID: harbourRecording, artistMBID: stubArtist, title: "Harbour Lights",
                                  artist: "Stub Arrows", duration: 196, source: .lidarr)
        #expect(await model.previewSong(for: r) == nil && aurral.requests.isEmpty)
    }

    // MARK: - Artist top songs (owner answer 6)

    private func stubTopSongs() {
        transport.navidrome.stub(pathSuffix: "/rest/getTopSongs", body: okBody(#""topSongs":{"song":[{"id":"m-x","title":"X","artist":"Stub Arrows","album":"A","duration":100}]}"#))
        transport.navidrome.stub(pathSuffix: "/1/popularity/top-recordings-for-artist/\(stubArtist.rawValue)",
                                 body: Data(#"[{"artist_mbids":["\#(stubArtist.rawValue)"],"artist_name":"Stub Arrows","recording_mbid":"\#(harbourRecording.rawValue)","recording_name":"Harbour Lights","release_name":"Harbour Lights","length":197000}]"#.utf8))
    }

    @Test func topSongsInTheFourSetups() async throws {
        let navidromeOnly = try await model(aurralSetUp: false)
        #expect(navidromeOnly.topSongsProviders(mbid: stubArtist) == [.library])
        navidromeOnly.signOut()
        let withToken = try await model(aurralSetUp: false, lidarr: true, listenBrainzToken: "tok")
        #expect(withToken.topSongsProviders(mbid: stubArtist) == [.listenBrainz, .library])
        #expect(withToken.topSongsProviders(mbid: nil) == [.library], "no MBID: only the library")
        withToken.signOut()
        let all = try await model(lidarr: true, listenBrainzToken: "tok")
        defer { all.signOut() }
        #expect(all.topSongsProviders(mbid: stubArtist) == [.aurral, .listenBrainz, .library])
    }

    @Test func topSongsFollowTheSettingAndFallBackWithANote() async throws {
        let model = try await model(listenBrainzToken: "tok")
        defer { model.signOut() }
        stubTopSongs()
        let auto = try #require(await model.artistTopSongs(name: "Stub Arrows", mbid: stubArtist))
        #expect(auto.provider == .aurral && !auto.fellBack && auto.rows.first?.preview?.preview?.trackId == "3135556")

        model.updatePreferences { $0.layout.artistTopSongs = .listenBrainz }
        let lb = try #require(await model.artistTopSongs(name: "Stub Arrows", mbid: stubArtist))
        #expect(lb.provider == .listenBrainz && lb.rows.first?.song.recordingMBID == harbourRecording)
        #expect(lb.rows.first?.preview?.preview?.trackId == "3135556", "its preview matched among the artist's")

        model.updatePreferences { $0.layout.artistTopSongs = .library }
        let library = try #require(await model.artistTopSongs(name: "Stub Arrows", mbid: stubArtist))
        #expect(library.provider == .library && library.rows.first?.library?.id == "m-x")

        // The server down, Automatic: ListenBrainz, with the note.
        model.updatePreferences { $0.layout.artistTopSongs = .automatic }
        model.songActions.artistPreviews = [:]
        aurral.setDown(true)
        let fell = try #require(await model.artistTopSongs(name: "Stub Arrows", mbid: stubArtist))
        #expect(fell.provider == .listenBrainz && fell.fellBack)
        #expect(SongActionsCopy.topSongsNote(fell.provider) == "from ListenBrainz")
    }

    @Test func thePickerOffersAurralOnlyWithIt() async throws {
        let model = try await model(aurralSetUp: false)
        defer { model.signOut() }
        #expect(!ArtistTopSongsView.hasAurral(model))
        model.updatePreferences { $0.layout.artistTopSongs = .aurral }
        #expect(ArtistTopSongsView.summary(model) == "Automatic", "a saved Aurral reads as what happens")
        #expect(ArtistTopSongsSource.choices(aurral: false).map(SongActionsCopy.sourceTitle) == ["Automatic", "ListenBrainz", "Your library"])
    }

    // MARK: - Fix round 1

    private func scope(_ base: URL) -> String {
        LidarrClient(base: base, apiKey: "dev-key", transport: transport).instanceScope
    }

    /// Saved as a previous run left them: a request and the add linked to it, for the Lidarr at `base`.
    private func saveRun(_ request: MagpieRequest, _ add: PendingPlaylistAdd, base: URL = lidarrBase) async throws {
        try await RequestStore(fileURL: RequestStore.defaultURL(in: tmp, instance: scope(base))).save([request])
        try await PlaylistAddStore(fileURL: PlaylistAddStore.defaultURL(in: tmp, instance: scope(base))).save([add])
    }

    private func savedAdds(base: URL = lidarrBase) async throws -> [PendingPlaylistAdd] {
        try await PlaylistAddStore(fileURL: PlaylistAddStore.defaultURL(in: tmp, instance: scope(base))).load()
    }

    /// I1: after a relaunch the adds file is read before the runner has published its requests. The add waits (never
    /// saved as failed) and is added once the runner's list shows the song Ready. No hand-set `requests`.
    @Test func afterARelaunchALinkedAddWaitsForTheRunnersListThenIsAdded() async throws {
        addSong("m-harbour", duration: 196)
        let request = readyRequest()
        try await saveRun(request, pending(request: request.id))
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        #expect(await eventually(10) { self.playlistWrites.count == 1 }, "added once the runner's list is in")
        #expect(queryValue(try #require(playlistWrites.first), "songIdToAdd") == "m-harbour")
        #expect(model.songActions.pending.isEmpty && model.songActions.requestsLoaded)
    }

    /// I1: a reconnect, and a switch to another Lidarr and back, never mark an add whose request is still on its way.
    @Test func aReconnectOrSwitchNeverMarksAWaitingAddFailed() async throws {
        let other = URL(string: "http://192.168.1.3:8686")!
        transport.navidrome.stub(pathSuffix: "/api/v1/system/status",
                                 body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        let request = readyRequest(state: .downloading(progress: 0.3))
        let add = pending(request: request.id)
        try await saveRun(request, add)
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        #expect(await eventually(10) { model.songActions.requestsLoaded && model.songActions.pending.count == 1 })
        await model.evaluatePendingAdds(force: true)
        #expect(model.pendingAdds(for: "pl-road").first?.step == .waiting(.downloading(progress: 0.3)))
        model.disconnectLidarr()
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "dev-key")
        #expect(await eventually(10) { model.songActions.requestsLoaded && model.songActions.pending.count == 1 })
        _ = try await model.connectLidarr(base: other, apiKey: "dev-key")
        #expect(await eventually(10) { model.songActions.requestsLoaded })
        #expect(model.songActions.pending.isEmpty, "the other Lidarr has none")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "dev-key")
        #expect(await eventually(10) { model.songActions.requestsLoaded && model.songActions.pending.count == 1 })
        await model.evaluatePendingAdds(force: true)
        #expect(model.songActions.pending.first?.failedAt == nil)
        #expect(try await savedAdds().first?.failedAt == nil, "never saved as failed")
        #expect(playlistWrites.isEmpty)
    }

    /// I1: before the runner's list is in, a missing request reads as waiting; after, as stopped (Retry, Remove), and
    /// still nothing is saved as failed.
    @Test func aMissingRequestWaitsUntilTheListIsIn() async throws {
        let model = try await model()
        defer { model.signOut() }
        let add = pending(request: RequestID())
        model.songActions.pending = [add]
        #expect(model.pendingAdds(for: "pl-road").first?.step == .waiting(nil))
        model.songActions.requestsLoaded = true
        await model.evaluatePendingAdds()
        #expect(model.pendingAdds(for: "pl-road").first?.step == .requestGone)
        #expect(model.songActions.pending.first?.failedAt == nil)
    }

    /// M1: when the read-first can't be done, nothing is sent; the next pass reads again.
    @Test func aFailedReadFirstSendsNothing() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        transport.navidrome.stub(pathSuffix: "/rest/getPlaylist") { r in
            let n = reads.withLock { $0 += 1; return $0 }
            if n == 1 { return .init(status: 500) }
            return .init(status: 200, body: okBody(#""playlist":{"id":"pl-road","name":"Road trip","owner":"admin","readonly":false,"entry":[]}"#))
        }
        let model = try await model()
        defer { model.signOut() }
        addSong("m-harbour", duration: 196)
        let request = readyRequest()
        model.requests = [request]
        model.songActions.requestsLoaded = true
        var add = pending(request: request.id)
        add.sendingSongId = "m-harbour"
        model.songActions.pending = [add]
        await model.evaluatePendingAdds()
        #expect(playlistWrites.isEmpty && model.songActions.pending.count == 1)
    }

    /// M2: New playlist… uses the id the new playlist got, never a playlist of the same name.
    @Test func aNewPlaylistIsKnownByItsIdNotItsName() async throws {
        transport.navidrome.stub(pathSuffix: "/rest/createPlaylist") { r in
            let name = queryValue(r, "name") ?? ""
            self.nav.lists["pl-new"] = (name, [])
            return .init(status: 200, body: okBody(#""playlist":{"id":"pl-new","name":"\#(name)","owner":"admin","songCount":0}"#))
        }
        let model = try await model()
        defer { model.signOut() }
        let id = try await model.createPlaylist(named: "Road trip", songIds: [])
        #expect(id == "pl-new", "not the older Road trip (pl-road)")
    }

    /// M3: a Whole artist add is checked on a timer too, not only when requests move or the page opens.
    @Test func wholeArtistAddsAreCheckedOnATimer() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        #expect(await eventually(10) { model.songActions.requestsLoaded })
        model.songActions.checkEvery = .milliseconds(200)
        model.songActions.lookUpEvery = 0
        model.followPendingAdds(instance: "timer", restart: true)
        try await Task.sleep(for: .milliseconds(500))   // the file's read (and its one check) are done: only the timer is left
        addSong("m-harbour", duration: 196)
        model.songActions.pending = [pending(request: nil, mbid: nil)]
        #expect(await eventually(10) { self.playlistWrites.count == 1 })
    }

    /// M4: a check asked for while one runs is run next, not dropped.
    @Test func aCheckAskedForDuringOneRunsNext() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.songActions.requestsLoaded = true
        model.songActions.evaluating = true
        addSong("m-harbour", duration: 196)
        model.songActions.pending = [pending(request: nil, mbid: nil)]
        await model.evaluatePendingAdds()
        #expect(model.songActions.evaluateAgain && playlistWrites.isEmpty)
        model.songActions.evaluating = false
        await model.evaluatePendingAdds()
        #expect(!model.songActions.evaluateAgain && playlistWrites.count == 1)
    }

    /// M5: saving the same song to the same playlist again does nothing: already coming, or already there.
    @Test func savingTheSameSongTwiceIsANoOp() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        let playlist = try #require(try await model.editablePlaylists().first { $0.id == "pl-road" })
        model.songActions.pending = [pending(request: nil, mbid: nil)]
        #expect(await model.save(harbour, choice: .wholeArtist, to: playlist) == SongActionsCopy.alreadyComing("Road trip"))
        #expect(model.songActions.queuedAdd == nil && model.songActions.pending.count == 1)
        model.songActions.pending = []
        addSong("m-harbour", duration: 196)
        nav.lists["pl-road"]?.songs.append("m-harbour")
        #expect(await model.save(harbour, choice: .wholeArtist, to: playlist) == SongActionsCopy.alreadyIn("Road trip"))
        #expect(model.songActions.queuedAdd == nil && playlistWrites.isEmpty)
    }

    /// M5: a song the library already has goes straight onto the playlist (no Find, no Add).
    @Test func aSongTheLibraryHasIsAddedAtOnce() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        let playlist = try #require(try await model.editablePlaylists().first { $0.id == "pl-road" })
        addSong("m-harbour", duration: 197)
        #expect(await model.save(harbour, choice: .wholeArtist, to: playlist) == nil)
        #expect(playlistWrites.count == 1 && model.songActions.queuedAdd == nil && model.songActions.pending.isEmpty)
    }

    // MARK: - Words

    @Test func theMenuAndRowsNeverNameAService() {
        let words = [SongActionsCopy.listen, SongActionsCopy.listenSubtitle, SongActionsCopy.addArtist,
                     SongActionsCopy.saveToPlaylist, SongActionsCopy.justThisSong, SongActionsCopy.wholeArtist,
                     SongActionsCopy.choiceMessage, SongActionsCopy.noJustThisSong, SongActionsCopy.unmatchedMessage,
                     SongActionsCopy.coming, SongActionsCopy.savedComing("Road trip"), SongActionsCopy.topSongsNote(.aurral),
                     SongActionsCopy.status(.lookUp, playlistGone: false), SongActionsCopy.status(.failed, playlistGone: true)]
        for text in words {
            for name in ["Aurral", "Lidarr", "Navidrome", "Tubifarry", "Deezer", "MusicBrainz"] { #expect(!text.contains(name), "\(text)") }
        }
        #expect(SongActionsCopy.listenSubtitle == "Goes into your Finds")
    }
}
