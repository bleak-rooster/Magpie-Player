import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Testing
@testable import Magpie

private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

private func ok(_ body: String = "") -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(body.isEmpty ? "" : "," + body)}}"#.utf8)
}
private let refused = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"no"}}}"#.utf8)

private func query(_ request: URLRequest) -> [URLQueryItem] {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
}
private func value(_ request: URLRequest, _ name: String) -> String? { query(request).first { $0.name == name }?.value }

/// A Navidrome's playlists in memory, answering the Subsonic playlist calls as the dev Navidrome 0.64.2 does.
final class FakePlaylistServer: @unchecked Sendable {
    struct List { var name: String; var owner: String; var readonly: Bool; var songs: [String] }
    private let lock = NSLock()
    private var lists: [String: List] = [:]
    private var made = 0
    /// Calls (by method name) whose next reply is lost after the change is made (`timedOut`): the change happened.
    private var losing: Set<String> = []
    /// Calls (by method name) whose next request never arrives (`timedOut`): nothing changes.
    private var dropping: Set<String> = []

    func loseNextReply(to method: String) { lock.withLock { _ = losing.insert(method) } }
    func dropNext(_ method: String) { lock.withLock { _ = dropping.insert(method) } }
    private func take(_ set: ReferenceWritableKeyPath<FakePlaylistServer, Set<String>>, _ method: String) -> Bool {
        lock.withLock { self[keyPath: set].remove(method) != nil }
    }
    /// Wraps a write: a dropped request changes nothing; a lost reply changes it, then times out.
    private func write(_ method: String, _ change: @escaping @Sendable (URLRequest) -> MockTransport.Response)
        -> @Sendable (URLRequest) throws -> MockTransport.Response {
        { r in
            if self.take(\.dropping, method) { throw URLError(.timedOut) }
            let response = change(r)
            if self.take(\.losing, method) { throw URLError(.timedOut) }
            return response
        }
    }

    /// An empty owner is left out, as a server that doesn't say.
    static func ownerField(_ l: List) -> String { l.owner.isEmpty ? "" : #""owner":"\#(l.owner)","# }

    func put(_ id: String, _ list: List) { lock.withLock { lists[id] = list } }
    func list(_ id: String) -> List? { lock.withLock { lists[id] } }
    var ids: [String] { lock.withLock { lists.keys.sorted() } }

    func install(on t: MockTransport) {
        t.stub(pathSuffix: "/rest/getPlaylists") { _ in
            let rows = self.lock.withLock { self.lists.sorted { $0.key < $1.key }.map { id, l in
                #"{"id":"\#(id)","name":"\#(l.name)",\#(Self.ownerField(l))"readonly":\#(l.readonly),"songCount":\#(l.songs.count)}"#
            } }
            return .init(status: 200, body: ok(#""playlists":{"playlist":[\#(rows.joined(separator: ","))]}"#))
        }
        t.stub(pathSuffix: "/rest/getPlaylist") { r in
            guard let id = value(r, "id"), let l = self.list(id) else { return .init(status: 200, body: refused) }
            let entries = l.songs.map { #"{"id":"\#($0)","title":"\#($0)"}"# }.joined(separator: ",")
            return .init(status: 200, body: ok(#""playlist":{"id":"\#(id)","name":"\#(l.name)",\#(Self.ownerField(l))"readonly":\#(l.readonly),"entry":[\#(entries)]}"#))
        }
        t.stub(pathSuffix: "/rest/createPlaylist", handler: write("createPlaylist") { r in
            let id = self.lock.withLock { self.made += 1; return "new\(self.made)" }
            let name = value(r, "name") ?? ""
            self.put(id, List(name: name, owner: "admin", readonly: false,
                              songs: query(r).filter { $0.name == "songId" }.compactMap(\.value)))
            return .init(status: 200, body: ok(#""playlist":{"id":"\#(id)","name":"\#(name)","owner":"admin","readonly":false}"#))
        })
        t.stub(pathSuffix: "/rest/updatePlaylist", handler: write("updatePlaylist") { r in
            guard let id = value(r, "playlistId"), var l = self.list(id), !l.readonly else { return .init(status: 200, body: refused) }
            if let name = value(r, "name") { l.name = name }
            let remove = Set(query(r).filter { $0.name == "songIndexToRemove" }.compactMap { $0.value.flatMap(Int.init) })
            l.songs = l.songs.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
            l.songs += query(r).filter { $0.name == "songIdToAdd" }.compactMap(\.value)
            self.put(id, l)
            return .init(status: 200, body: ok())
        })
        t.stub(pathSuffix: "/rest/deletePlaylist", handler: write("deletePlaylist") { r in
            guard let id = value(r, "id") else { return .init(status: 200, body: refused) }
            self.lock.withLock { _ = self.lists.removeValue(forKey: id) }
            return .init(status: 200, body: ok())
        })
    }
}

/// Round 11 R3, R7, R8, R11 (and R2's bubble): favourites with rollback, playlist edits and the duplicate warning,
/// read-only playlists, Popular from the cache, and "Album artists only" on the phone and in the car.
@MainActor @Suite(.serialized) final class LibraryEditsAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "LibraryEditsAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "LibraryEditsAppTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedInModel() async throws -> AppModel {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok())
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        return model
    }

    private func requests(_ suffix: String) -> [URLRequest] {
        transport.inner.requests.filter { $0.url?.path.hasSuffix(suffix) == true }
    }

    // MARK: - R7 Favourites

    @Test func starAndUnstarSongsAlbumsAndArtists() async throws {
        let model = try await signedInModel()
        transport.inner.stub(pathSuffix: "/rest/star", body: ok())
        transport.inner.stub(pathSuffix: "/rest/unstar", body: ok())

        await model.setFavourite(.song("s1"), true)
        await model.setFavourite(.album("al1"), true)
        await model.setFavourite(.artist("ar1"), true)
        #expect(model.isFavourite(.song("s1")) && model.isFavourite(.album("al1")) && model.isFavourite(.artist("ar1")))
        let stars = requests("/rest/star")
        #expect(stars.map { value($0, "id") } == ["s1", nil, nil])
        #expect(stars.map { value($0, "albumId") } == [nil, "al1", nil])
        #expect(stars.map { value($0, "artistId") } == [nil, nil, "ar1"])

        await model.setFavourite(.album("al1"), false)
        await model.setFavourite(.artist("ar1"), false)
        #expect(!model.isFavourite(.album("al1")) && !model.isFavourite(.artist("ar1")))
        #expect(requests("/rest/unstar").map { value($0, "albumId") ?? value($0, "artistId") } == ["al1", "ar1"])
        #expect(model.libraryEdits.notice == nil)
    }

    @Test func aRefusedStarRollsBackWithANotice() async throws {
        let model = try await signedInModel()
        transport.inner.stub(pathSuffix: "/rest/star", body: refused)
        transport.inner.stub(pathSuffix: "/rest/unstar", body: refused)

        for target in [FavouriteTarget.song("s1"), .album("al1"), .artist("ar1")] {
            model.libraryEdits.notice = nil
            await model.setFavourite(target, true)
            #expect(!model.isFavourite(target), "rolled back: \(target)")
            #expect(model.libraryEdits.notice?.text == FavouriteCopy.addFailed)
        }
        // A starred album the server won't unstar stays starred.
        model.noteFavourite(.album("al2"), true)
        await model.setFavourite(.album("al2"), false)
        #expect(model.isFavourite(.album("al2")))
        #expect(model.libraryEdits.notice?.text == FavouriteCopy.removeFailed)
    }

    /// I3: a row's menu (a Home tile, the Artists list) knows the item only from the row: a refused unfavourite
    /// rolls back to the row's starred state, with nothing noted beforehand.
    @Test func aRefusedUnfavouriteFromARowRollsBackToTheRowsState() async throws {
        let model = try await signedInModel()
        transport.inner.stub(pathSuffix: "/rest/unstar", body: refused)
        for target in [FavouriteTarget.song("s3"), .album("al3"), .artist("ar3")] {
            #expect(model.isFavourite(target, given: true))
            await model.setFavourite(target, false, given: true)
            #expect(model.isFavourite(target, given: true), "rolled back to starred: \(target)")
            #expect(model.isFavourite(target), "rolled back to starred: \(target)")
            #expect(model.libraryEdits.notice?.text == FavouriteCopy.removeFailed)
        }
        let song = Song(id: "s3", title: "T", artist: "A", album: "B", duration: 100, starred: true)
        #expect(model.isStarred(song))
    }

    @Test func nowPlayingsStarStillWorksAndReadsTheQueue() async throws {
        let model = try await signedInModel()
        transport.inner.stub(pathSuffix: "/rest/star", body: ok())
        let song = Song(id: "s5", title: "T", artist: "A", album: "B", duration: 100, starred: true)
        model.play([song], startAt: 0)
        #expect(model.isFavourite(.song("s5")), "the queue's copy says starred")
        let other = Song(id: "s6", title: "T", artist: "A", album: "B", duration: 100)
        await model.toggleStar(other)
        #expect(model.isStarred(other) && model.isFavourite(.song("s6")))
    }

    @Test func offlineAFavouriteSaysSoAndChangesNothing() async throws {
        let model = try await signedInModel()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        await model.setFavourite(.album("al1"), true)
        #expect(!model.isFavourite(.album("al1")))
        #expect(model.libraryEdits.notice?.text == "You're offline")
        #expect(requests("/rest/star").isEmpty)
    }

    @Test func favouritesListsArtistsToo() async throws {
        let model = try await signedInModel()
        transport.inner.stub(pathSuffix: "/rest/getStarred2", body: ok(#""starred2":{"artist":[{"id":"ar1","name":"Aurora Field","starred":"2026-10-30T14:13:34Z"}],"album":[{"id":"al1","name":"A","starred":"2026-10-30T14:13:34Z"}]}"#))
        let starred = try await model.favourites()
        #expect(starred.artists.map(\.name) == ["Aurora Field"])
        #expect(model.isFavourite(.artist("ar1")) && model.isFavourite(.album("al1")), "a Favourites read is noted")
    }

    // MARK: - R8 Playlists

    @Test func onlyTheUsersOwnPlaylistsAreOfferedAndEditable() async throws {
        let model = try await signedInModel()
        let server = FakePlaylistServer()
        server.put("p1", .init(name: "Mine", owner: "admin", readonly: false, songs: []))
        server.put("p2", .init(name: "Theirs", owner: "listener", readonly: true, songs: []))
        server.install(on: transport.inner)
        #expect(try await model.editablePlaylists().map(\.id) == ["p1"])
        let all = try await model.request { try await $0.playlists() }
        #expect(all.map { model.canEdit($0) } == [true, false])
        #expect(PlaylistMenuItem.items(editable: true).contains(.rename))
        #expect(PlaylistMenuItem.items(editable: true).contains(.delete))
        #expect(PlaylistMenuItem.items(editable: false) == [.addToQueue, .addToPlaylist, .reloadArtwork],
                "read-only: only the items that don't change it")
        #expect(PlaylistCopy.madeBy("listener") == "Made by listener. You can play it but not change it.")
    }

    @Test func createRenameAddRemoveAndDeleteAPlaylist() async throws {
        let model = try await signedInModel()
        let server = FakePlaylistServer()
        server.install(on: transport.inner)
        let revision = model.libraryEdits.playlistsRevision

        try await model.createPlaylist(named: "  Road trip ", songIds: ["s1"])
        let made = try #require(try await model.editablePlaylists().first)
        #expect(made.name == "Road trip" && server.list(made.id)?.songs == ["s1"])
        try await model.renamePlaylist(made, to: "Long drive")
        #expect(server.list(made.id)?.name == "Long drive")
        try await model.add(["s2", "s3"], to: made)
        #expect(server.list(made.id)?.songs == ["s1", "s2", "s3"])
        #expect(model.libraryEdits.notice?.text == "Added to Long drive", "the playlist's name now")
        try await model.removeSong(at: 1, songId: "s2", from: made)
        #expect(server.list(made.id)?.songs == ["s1", "s3"])
        #expect(model.libraryEdits.notice?.text == "Removed from Long drive")
        try await model.deletePlaylist(made)
        #expect(server.ids.isEmpty)
        #expect(model.libraryEdits.playlistsRevision == revision + 5, "every change refreshes the lists")
        #expect(PlaylistCopy.deleteTitle("Road trip") == "Delete \u{201C}Road trip\u{201D}?")
        #expect(PlaylistCopy.deleteMessage == "It\u{2019}s deleted from your music server for everyone who uses it.")
    }

    @Test func addingASongAlreadyThereWarnsFirst() async throws {
        let model = try await signedInModel()
        let server = FakePlaylistServer()
        server.put("p1", .init(name: "Road trip", owner: "admin", readonly: false, songs: ["s1"]))
        server.install(on: transport.inner)
        let playlist = try #require(try await model.editablePlaylists().first)

        let flow = AddToPlaylistFlow(songIds: ["s1"])
        await flow.load(model)
        await flow.choose(playlist, model)
        let duplicate = try #require(flow.duplicate)
        #expect(duplicate.playlist.id == "p1" && duplicate.title == "s1" && !flow.done)
        #expect(PlaylistCopy.alreadyIn(playlist.name) == "Already in Road trip")
        #expect(PlaylistCopy.addAgain("Seven") == "Add Seven again?")
        #expect(server.list("p1")?.songs == ["s1"], "nothing added before the answer")
        await flow.addAll(duplicate, model)
        #expect(flow.done && flow.duplicate == nil)
        #expect(server.list("p1")?.songs == ["s1", "s1"], "duplicates are allowed")

        // Several songs: only the ones already there are asked about; Skip those adds the rest.
        let several = AddToPlaylistFlow(songIds: ["s1", "s7", "s8"])
        await several.choose(playlist, model)
        let some = try #require(several.duplicate)
        #expect(some.count(in: several.songIds) == 1)
        #expect(PlaylistCopy.someAlreadyIn(3, "Road trip") == "3 of these are already in Road trip.")
        await several.skipThose(some, model)
        #expect(several.done && server.list("p1")?.songs == ["s1", "s1", "s7", "s8"])

        let fresh = AddToPlaylistFlow(songIds: ["s9"])
        await fresh.choose(playlist, model)
        #expect(fresh.done && fresh.duplicate == nil, "a new song goes straight in")
        #expect(server.list("p1")?.songs == ["s1", "s1", "s7", "s8", "s9"])

        let named = AddToPlaylistFlow(songIds: ["s4", "s5"])
        await named.create(named: "Fresh", model)
        #expect(named.done)
        #expect(try await model.editablePlaylists().first { $0.name == "Fresh" }.flatMap { server.list($0.id)?.songs } == ["s4", "s5"])
    }

    @Test func menusAskForTheSheetAndOfflineSaysSo() async throws {
        let model = try await signedInModel()
        model.askToAddToPlaylist(["s1", "s2"])
        #expect(model.libraryEdits.addToPlaylist?.songIds == ["s1", "s2"])
        model.libraryEdits.addToPlaylist = nil
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.askToAddToPlaylist(["s1"])
        #expect(model.libraryEdits.addToPlaylist == nil && model.libraryEdits.notice?.text == "You're offline")
    }

    // MARK: - R8 review fixes (I1, I2, I4)

    /// I1: a playlist write is sent once, never again after a timeout; the playlist is read back to say what happened.
    @Test func aTimedOutPlaylistWriteIsSentOnceAndReadBack() async throws {
        let model = try await signedInModel()
        let server = FakePlaylistServer()
        server.put("p1", .init(name: "Road trip", owner: "admin", readonly: false, songs: ["s1", "s2", "s3"]))
        server.install(on: transport.inner)
        let playlist = try #require(try await model.editablePlaylists().first)

        // The change landed and only the reply was lost: one request, and it counts as done.
        server.loseNextReply(to: "updatePlaylist")
        try await model.add(["s4"], to: playlist)
        #expect(requests("/rest/updatePlaylist").count == 1)
        #expect(server.list("p1")?.songs == ["s1", "s2", "s3", "s4"])
        #expect(model.libraryEdits.notice?.text == "Added to Road trip")

        server.loseNextReply(to: "updatePlaylist")
        try await model.removeSong(at: 0, songId: "s1", from: playlist)
        #expect(requests("/rest/updatePlaylist").count == 2, "a lost reply is never followed by a second remove")
        #expect(server.list("p1")?.songs == ["s2", "s3", "s4"])

        // The request never arrived: one request, nothing changed, and the error says so.
        server.dropNext("updatePlaylist")
        await #expect(throws: PlaylistEditError.notChanged) {
            try await model.removeSong(at: 0, songId: "s2", from: playlist)
        }
        #expect(requests("/rest/updatePlaylist").count == 3)
        #expect(server.list("p1")?.songs == ["s2", "s3", "s4"])

        server.loseNextReply(to: "updatePlaylist")
        try await model.renamePlaylist(playlist, to: "Long drive")
        #expect(requests("/rest/updatePlaylist").count == 4 && server.list("p1")?.name == "Long drive")

        server.loseNextReply(to: "createPlaylist")
        try await model.createPlaylist(named: "Fresh", songIds: ["s9"])
        #expect(requests("/rest/createPlaylist").count == 1)
        #expect(server.ids.count == 2, "exactly one new playlist")

        server.loseNextReply(to: "deletePlaylist")
        try await model.deletePlaylist(playlist)
        #expect(requests("/rest/deletePlaylist").count == 1 && server.list("p1") == nil)
    }

    /// I2: a remove checks the song is still at that position, and edits to one playlist go one at a time.
    @Test func aRemoveChecksTheSongAndEditsGoOneAtATime() async throws {
        let model = try await signedInModel()
        let server = FakePlaylistServer()
        server.put("p1", .init(name: "Road trip", owner: "admin", readonly: false, songs: ["s1", "s2", "s3", "s4"]))
        server.install(on: transport.inner)
        let playlist = try #require(try await model.editablePlaylists().first)

        // Two quick swipes, each with the position the page showed when it was swiped (the row left at once). The
        // second is swiped once the first is under way (it has read the playlist inside the lock), so it waits for the
        // first's write: the order the user made them, not whichever task the scheduler starts first (deflaked).
        let reads = requests("/rest/getPlaylist").count
        let first = Task { try await model.removeSong(at: 1, songId: "s2", from: playlist) }
        #expect(await eventually(10) { requests("/rest/getPlaylist").count > reads }, "the first remove is under way")
        let second = Task { try await model.removeSong(at: 1, songId: "s3", from: playlist) }
        try await first.value
        try await second.value
        #expect(server.list("p1")?.songs == ["s1", "s4"])

        // A stale position (the playlist changed elsewhere): nothing is removed, the page reads again and says why.
        server.put("p1", .init(name: "Road trip", owner: "admin", readonly: false, songs: ["s4", "s1"]))
        let sent = requests("/rest/updatePlaylist").count
        let revision = model.libraryEdits.playlistsRevision
        try await model.removeSong(at: 0, songId: "s1", from: playlist)
        #expect(server.list("p1")?.songs == ["s4", "s1"])
        #expect(requests("/rest/updatePlaylist").count == sent, "nothing sent")
        #expect(model.libraryEdits.playlistsRevision == revision + 1)
        #expect(model.libraryEdits.notice?.text == PlaylistCopy.changedMeanwhile)
    }

    /// I4: the write functions themselves refuse a playlist that isn't the user's, even when an admin's server
    /// would allow it, and send nothing.
    @Test func writesRefuseSomeoneElsesPlaylist() async throws {
        let model = try await signedInModel()
        let server = FakePlaylistServer()
        server.put("p2", .init(name: "Theirs", owner: "listener", readonly: false, songs: ["s1"]))
        server.install(on: transport.inner)
        let theirs = Playlist(id: "p2", name: "Theirs", songCount: 1, duration: 0, owner: "listener", readOnly: false)
        // A stale or forged value that claims to be the user's: the server's current owner decides.
        let claimed = Playlist(id: "p2", name: "Theirs", songCount: 1, duration: 0, owner: "admin", readOnly: false)
        for playlist in [theirs, claimed] {
            await #expect(throws: PlaylistEditError.notYours) { try await model.add(["s2"], to: playlist) }
            await #expect(throws: PlaylistEditError.notYours) { try await model.renamePlaylist(playlist, to: "Mine") }
            await #expect(throws: PlaylistEditError.notYours) {
                try await model.removeSong(at: 0, songId: "s1", from: playlist)
            }
            await #expect(throws: PlaylistEditError.notYours) { try await model.deletePlaylist(playlist) }
        }
        #expect(requests("/rest/updatePlaylist").isEmpty && requests("/rest/deletePlaylist").isEmpty)
        #expect(server.list("p2")?.songs == ["s1"] && server.list("p2")?.name == "Theirs")
    }

    /// N1: a playlist the server gives no owner for is refused, even when it says `readonly: false`.
    @Test func aPlaylistWithNoOwnerIsRefused() async throws {
        let model = try await signedInModel()
        let server = FakePlaylistServer()
        server.put("p3", .init(name: "Nobody's", owner: "", readonly: false, songs: ["s1"]))
        server.install(on: transport.inner)
        let unowned = Playlist(id: "p3", name: "Nobody's", songCount: 1, duration: 0, owner: nil, readOnly: false)
        let claimed = Playlist(id: "p3", name: "Nobody's", songCount: 1, duration: 0, owner: "admin", readOnly: false)
        for playlist in [unowned, claimed] {
            await #expect(throws: PlaylistEditError.notYours) { try await model.add(["s2"], to: playlist) }
            await #expect(throws: PlaylistEditError.notYours) { try await model.deletePlaylist(playlist) }
        }
        #expect(requests("/rest/updatePlaylist").isEmpty && requests("/rest/deletePlaylist").isEmpty)
        #expect(!model.canEdit(unowned))
        #expect(try await model.editablePlaylists().isEmpty)
    }

    /// N4: a double tap on Create makes one playlist.
    @Test func aDoubleTapOnCreateMakesOnePlaylist() async throws {
        let model = try await signedInModel()
        let server = FakePlaylistServer()
        server.install(on: transport.inner)
        async let first = model.createPlaylist(named: "Fresh", songIds: [])
        async let second = model.createPlaylist(named: "Fresh", songIds: [])
        _ = try await (first, second)
        #expect(requests("/rest/createPlaylist").count == 1)
        #expect(server.ids.count == 1)
    }

    // MARK: - R3 Popular

    @Test func popularShowsTheSavedListThenReplacesItOnlyWhenChanged() async throws {
        let cache = PopularSongsCache(root: tmp, scope: "abc123")
        let a = Song(id: "a", title: "A", artist: "X", album: "L", duration: 100, coverArtId: "c1")
        let b = Song(id: "b", title: "B", artist: "X", album: "L", duration: 120)
        let c = Song(id: "c", title: "C", artist: "X", album: "L", duration: 90)
        cache.save([a, b], artistId: "ar1")

        let gate = AsyncGate()
        let popular = PopularSongs(artistId: "ar1", cache: cache)
        #expect(popular.songs.map(\.id) == ["a", "b"], "shown from the cache before any read")
        let refresh = Task { await popular.refresh { await gate.wait(); return [a, b] } }
        await Task.yield()
        #expect(popular.songs.map(\.id) == ["a", "b"], "still shown while the server's list is on its way")
        await gate.open()
        await refresh.value
        #expect(popular.songs.map(\.id) == ["a", "b"] && popular.visibleChanges == 0, "the same list isn't replaced")

        await popular.refresh { throw URLError(.timedOut) }
        #expect(popular.songs.map(\.id) == ["a", "b"], "a failed read keeps what shows")

        await popular.refresh { [b, c] }
        #expect(popular.songs.map(\.id) == ["b", "c"] && popular.visibleChanges == 1)
        #expect(cache.load(artistId: "ar1")?.map(\.id) == ["b", "c"], "saved for next time")
        #expect(PopularSongs(artistId: "ar2", cache: cache).songs.isEmpty, "per artist")
        #expect(PopularSongs(artistId: "ar1", cache: PopularSongsCache(root: tmp, scope: "other")).songs.isEmpty,
                "per account")

        PopularSongsCache.removeAll(root: tmp)
        #expect(cache.load(artistId: "ar1") == nil)
    }

    @Test func popularIsRemovedOnSignOut() async throws {
        let model = try await signedInModel()
        let scope = try #require(model.navidromeScope)
        PopularSongsCache(root: tmp, scope: scope).save([Song(id: "a", title: "A", artist: "X", album: "L", duration: 1)],
                                                         artistId: "ar1")
        let file = PopularSongsCache(root: tmp, scope: scope).url
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        model.signOut()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - R11 Album artists only

    @Test func albumArtistsOnlyChoosesTheArtistsListOnThePhoneAndInTheCar() async throws {
        let model = try await signedInModel()
        transport.inner.stub(pathSuffix: "/rest/getArtists", body: ok(#""artists":{"index":[{"name":"A","artist":[{"id":"a1","name":"Aurora Field","albumCount":2}]}]}"#))
        transport.inner.stub(pathSuffix: "/api/artist", body: Data(#"[{"id":"a1","name":"Aurora Field","albumCount":3},{"id":"a2","name":"Static Choir","albumCount":0}]"#.utf8),
                             headers: ["X-Total-Count": "2"])
        #expect(model.preferences.layout.albumArtistsOnly, "on by default")
        #expect(try await model.libraryArtists().map(\.id) == ["a1"])
        let car = CarPlayLibraryAdapter(model: model)
        #expect(try await car.artists().map(\.id) == ["a1"])

        model.updatePreferences { $0.layout.albumArtistsOnly = false }
        #expect(try await model.libraryArtists().map(\.id) == ["a1", "a2"])
        #expect(try await car.artists().map(\.id) == ["a1", "a2"])
        #expect(requests("/api/artist").allSatisfy { value($0, "role") == nil })
    }

    // MARK: - R2 Letter bubble

    @Test func theBubbleShowsTheLetterWhileDraggingAndHidesAfterRelease() async throws {
        let bubble = LetterBubbleState(hideDelay: .milliseconds(50))
        #expect(bubble.shown == nil)
        bubble.dragged(to: "C")
        #expect(bubble.shown == "C")
        bubble.dragged(to: "D")
        #expect(bubble.shown == "D")
        bubble.released()
        #expect(bubble.shown == "D", "still there just after the finger lifts")
        #expect(await eventually(2) { bubble.shown == nil }, "fades out after the delay")
        bubble.dragged(to: "E")
        bubble.released()
        bubble.dragged(to: "F")   // a new touch before the fade keeps it
        try await Task.sleep(for: .milliseconds(120))
        #expect(bubble.shown == "F")
        #expect(LetterBubbleState().hideDelay == .milliseconds(400))
    }
}

/// Holds a read until opened.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}
