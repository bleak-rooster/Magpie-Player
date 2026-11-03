import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Testing
@testable import Magpie

final class MemoryAurralStore: AurralConnectionStoring, @unchecked Sendable {
    private let saved = OSAllocatedUnfairLock<AurralConnection?>(initialState: nil)
    func save(_ connection: AurralConnection) throws { saved.withLock { $0 = connection } }
    func load() -> AurralConnection? { saved.withLock { $0 } }
    func clear() { saved.withLock { $0 = nil } }
}

/// The stub Aurral on its host; everything else to the Navidrome mock. Never the owner's Aurral.
final class AurralRouting: HTTPTransport, @unchecked Sendable {
    let aurral = StubAurral()
    let navidrome = MockTransport()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == aurral.host { return try await aurral.send(request) }
        return try await navidrome.send(request)
    }
}

private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let server = URL(string: "http://192.168.1.2:4533")!
private let rec = "0383dadf-2a4e-4d10-a46a-e9e041da8eb3"
private let artistMbid = "4ad9b3a4-8a3a-4c7f-8b0f-6b7e6f2c0a11"
private let rec2 = "1b0c5c1e-6f0a-4a37-9c8f-0c2f1e8b2f10"

private func ok(_ body: String = "") -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(body.isEmpty ? "" : "," + body)}}"#.utf8)
}
private func items(_ r: URLRequest) -> [URLQueryItem] {
    r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
}
private func value(_ r: URLRequest, _ name: String) -> String? { items(r).first { $0.name == name }?.value }

/// A small Navidrome: two libraries (1 Music Library, 2 Aurral Playlists), Aurral's "Discover Weekly" (owned by the
/// signed-in user, as Aurral publishes it) and the owner's own "Road trip", which holds one Aurral copy.
final class DiscoverNavidrome: @unchecked Sendable {
    struct Entry { var id, title, artist: String; var duration: Int; var mbid: String?; var library: Int }
    private let lock = NSLock()
    var lists: [String: (name: String, songs: [String])] = [
        "pl-dw": ("Discover Weekly", ["a-lullaby", "a-words", "a-other", "a-nameonly"]),
        "pl-road": ("Road trip", ["m-x", "a-lullaby", "m-y", "a-old"]),
        // Fix I1: the owner's own playlist that happens to share a flow's name, and an empty one.
        "pl-mine": ("Discover Weekly", ["m-x", "m-y"]),
        "pl-empty": ("Trending Mix", []),
    ]
    let songs: [String: Entry] = [
        "a-lullaby": Entry(id: "a-lullaby", title: "Lullaby", artist: "Low", duration: 251, mbid: rec, library: 2),
        "a-words": Entry(id: "a-words", title: "Words", artist: "Low", duration: 200, mbid: nil, library: 2),
        "a-other": Entry(id: "a-other", title: "Unknown Song", artist: "Nobody", duration: 180, mbid: nil, library: 2),
        "a-nameonly": Entry(id: "a-nameonly", title: "Halo", artist: "Low", duration: 0, mbid: nil, library: 2),
        "m-lullaby": Entry(id: "m-lullaby", title: "Lullaby", artist: "Low", duration: 252, mbid: rec, library: 1),
        "m-words": Entry(id: "m-words", title: "Words", artist: "Low", duration: 202, mbid: nil, library: 1),
        "m-halo": Entry(id: "m-halo", title: "Halo", artist: "Low", duration: 0, mbid: nil, library: 1),
        "m-x": Entry(id: "m-x", title: "X", artist: "Q", duration: 100, mbid: nil, library: 1),
        "m-y": Entry(id: "m-y", title: "Y", artist: "Q", duration: 100, mbid: nil, library: 1),
        // Fix I2: an Aurral copy rotated out of every flow, still in Aurral's library (the owner's playlist holds it).
        "a-old": Entry(id: "a-old", title: "Old", artist: "Low", duration: 300, mbid: rec2, library: 2),
        "m-old": Entry(id: "m-old", title: "Old", artist: "Low", duration: 300, mbid: rec2, library: 1),
    ]
    private(set) var updates: [URLRequest] = []
    private(set) var lookups: [URLRequest] = []

    private func child(_ e: Entry) -> String {
        #"{"id":"\#(e.id)","title":"\#(e.title)","artist":"\#(e.artist)","album":"A","albumId":"al-\#(e.id)","duration":\#(e.duration)\#(e.mbid.map { #","musicBrainzId":"\#($0)""# } ?? "")}"#
    }
    private func native(_ e: Entry) -> String {
        #"{"id":"\#(e.id)","title":"\#(e.title)","artist":"\#(e.artist)","album":"A","duration":\#(e.duration),"libraryId":\#(e.library)\#(e.mbid.map { #","mbzRecordingID":"\#($0)""# } ?? "")}"#
    }

    func install(on t: MockTransport) {
        t.stub(pathSuffix: "/rest/ping", body: ok())
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/rest/getMusicFolders",
               body: ok(#""musicFolders":{"musicFolder":[{"id":1,"name":"Music Library"},{"id":2,"name":"Aurral Playlists"}]}"#))
        t.stub(pathSuffix: "/rest/getPlaylists") { _ in
            let rows = self.lock.withLock { self.lists.sorted { $0.key < $1.key }.map { id, l in
                #"{"id":"\#(id)","name":"\#(l.name)","owner":"admin","readonly":false,"public":true,"songCount":\#(l.songs.count)}"#
            } }
            return .init(status: 200, body: ok(#""playlists":{"playlist":[\#(rows.joined(separator: ","))]}"#))
        }
        t.stub(pathSuffix: "/rest/getPlaylist") { r in
            let id = value(r, "id") ?? ""
            guard let l = self.lock.withLock({ self.lists[id] }) else { return .init(status: 404) }
            let entries = l.songs.compactMap { self.songs[$0] }.map(self.child).joined(separator: ",")
            return .init(status: 200, body: ok(#""playlist":{"id":"\#(id)","name":"\#(l.name)","owner":"admin","readonly":false,"entry":[\#(entries)]}"#))
        }
        t.stub(pathSuffix: "/rest/search3") { r in
            let q = (value(r, "query") ?? "").lowercased()
            let hits = self.songs.values.filter { $0.title.lowercased() == q }.sorted { $0.id < $1.id }.map(self.child)
            return .init(status: 200, body: ok(#""searchResult3":{"song":[\#(hits.joined(separator: ","))]}"#))
        }
        t.stub(pathSuffix: "/api/song") { r in
            let rows: [Entry]
            if let mbid = value(r, "mbz_recording_id") { rows = self.songs.values.filter { $0.mbid == mbid }.sorted { $0.id < $1.id } }
            else if let library = value(r, "library_id").flatMap(Int.init) {
                rows = self.songs.values.filter { $0.library == library }.sorted { $0.id < $1.id }
            } else { rows = [] }
            self.lock.withLock { self.lookups.append(r) }
            return .init(status: 200, body: Data("[\(rows.map(self.native).joined(separator: ","))]".utf8),
                         headers: ["X-Total-Count": "\(rows.count)"])
        }
        t.stub(pathSuffix: "/rest/updatePlaylist") { r in
            self.lock.withLock { self.updates.append(r) }
            guard let id = value(r, "playlistId"), var l = self.lock.withLock({ self.lists[id] }) else { return .init(status: 404) }
            let remove = Set(items(r).filter { $0.name == "songIndexToRemove" }.compactMap { $0.value.flatMap(Int.init) })
            l.songs = l.songs.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
            l.songs += items(r).filter { $0.name == "songIdToAdd" }.compactMap(\.value)
            self.lock.withLock { self.lists[id] = l }
            return .init(status: 200, body: ok())
        }
    }
}

/// Round 12 Y6 (plan item 7): Discover end to end in the app, against the stub Aurral and a mock Navidrome.
@MainActor @Suite(.serialized) final class DiscoverAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "DiscoverAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "DiscoverAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = AurralRouting()
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    var aurral: StubAurral { transport.aurral }

    func signedIn(aurralSetUp: Bool = true) async throws -> AppModel {
        nav.install(on: transport.navidrome)
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly"), .init(id: "flow-tm", name: "Trending Mix")])
        aurral.setJobs([
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", artistMbid: artistMbid, trackMbid: rec,
                  durationMs: 251_000, finalPath: "/data/downloads/aurral/_flows/flow-dw/Low/Single/Lullaby.flac"),
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Words", artistMbid: artistMbid,
                  finalPath: "/data/downloads/aurral/_flows/flow-dw/Low/Single/Words.flac"),
            .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000,
                  finalPath: "/data/downloads/aurral/_flows/flow-dw/Nobody/Single/Unknown Song.mp3"),
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Halo",
                  finalPath: "/data/downloads/aurral/_flows/flow-dw/Low/Single/Halo.mp3"),
        ])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        try await model.signIn(urls: [server], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if aurralSetUp { _ = try await model.connectAurral(base: aurral.base, apiKey: aurral.apiKey) }
        return model
    }

    private var navidromeAsked: [String] { transport.navidrome.requests.compactMap { $0.url?.path } }

    // MARK: - Settings

    /// Off until set up: no Discover anywhere, nothing asked of Aurral.
    @Test func offUntilSetUp() async throws {
        let model = try await signedIn(aurralSetUp: false)
        defer { model.signOut() }
        #expect(!model.aurralSetUp)
        #expect(!model.homeSections.contains(.discover) && !model.libraryRows.contains(.discover))
        #expect(try await model.discoverPlaylists().isEmpty)
        #expect(aurral.requests.isEmpty)
        #expect(AurralCopy.summary(model) == "Off")
    }

    /// The key goes to the Keychain store only (never the app's settings), and checks the address and key first.
    @Test func connectSavesToTheKeychainOnly() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(aurralStore.load() == AurralConnection(base: aurral.base, apiKey: aurral.apiKey))
        #expect(model.aurralSetUp)
        #expect(model.homeSections.contains(.discover) && model.libraryRows.contains(.discover))
        #expect(model.libraryRows(carPlay: true).contains(.discover), "the car's Library too")
        for (key, value) in defaults.dictionaryRepresentation() {
            #expect(!"\(key)\(value)".contains(aurral.apiKey), "the key is never in the app's settings: \(key)")
        }
        #expect(model.discover.health?.compatibility == .supported("2.10.0"))
        #expect(AurralCopy.summary(model) == "On \u{00B7} 2.10.0")
        // A wrong key: nothing saved.
        model.disconnectAurral()
        await #expect(throws: AurralError.unauthorized) {
            _ = try await model.connectAurral(base: self.aurral.base, apiKey: "wrong")
        }
        #expect(aurralStore.load() == nil && !model.aurralSetUp)
    }

    /// Plain http to a public address waits for the owner's OK (nothing sent); a Tailscale or home address doesn't.
    @Test func plainHTTPConsentAsForLidarr() async throws {
        let model = try await signedIn(aurralSetUp: false)
        defer { model.signOut() }
        let before = aurral.requests.count
        await #expect(throws: PlainHTTPConsentRequired.self) {
            _ = try await model.connectAurral(base: URL(string: "http://aurral.example.com:3001")!, apiKey: "k")
        }
        #expect(aurral.requests.count == before)
        #expect(model.plainHTTPConsent.allows(URL(string: "http://homeserver:3001")!), "a Tailscale name needs no OK")
        #expect(model.plainHTTPConsent.allows(URL(string: "http://100.101.2.3:3001")!))
    }

    /// Version tolerance: a newer Aurral is used, with a note.
    @Test func newerVersionTolerated() async throws {
        aurral.setVersion("2.12.0")
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.discover.health?.compatibility == .newer("2.12.0"))
        #expect(AurralCopy.compatibilityNote(model.discover.health)?.contains("2.12.0") == true)
        #expect(model.discover.playlists.map(\.playlist.id) == ["pl-dw"])
    }

    // MARK: - Discover vs Playlists

    /// Flows ↔ playlists by name; Discover's are kept out of Playlists (Home, Library, the car, Add to playlist).
    @Test func discoverHiddenFromPlaylists() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.discover.playlists.map(\.playlist.id) == ["pl-dw"])
        #expect(model.discover.playlists.first?.flow.id == "flow-dw")
        #expect(model.isDiscoverPlaylist(id: "pl-dw") && !model.isDiscoverPlaylist(id: "pl-road"))
        let shelves = try await model.homeShelves(for: [.playlists, .discover])
        let ids = { (section: HomeSection) in
            shelves.first { $0.section == section }?.items.compactMap { item -> String? in
                if case .playlist(let p) = item { return p.id } else { return nil }
            } ?? []
        }
        #expect(ids(.playlists) == ["pl-mine", "pl-road", "pl-empty"], "fix I1: same-named but not Aurral's")
        #expect(ids(.discover) == ["pl-dw"])
        #expect(try await model.editablePlaylists().map(\.id) == ["pl-mine", "pl-road", "pl-empty"])
        let dw = Playlist(id: "pl-dw", name: "Discover Weekly", songCount: 4, duration: 0, owner: "admin", readOnly: false)
        #expect(!model.canEdit(dw), "Aurral's playlist, though the server names the owner")
        let car = CarPlayLibraryAdapter(model: model)
        #expect(try await car.playlists().map(\.id) == ["pl-empty", "pl-mine", "pl-road"])
        #expect(try await car.discoverPlaylists().map(\.id) == ["pl-dw"])
        // Saved for this account: kept out before Aurral answers again.
        #expect(defaults.stringArray(forKey: AppModel.discoverPlaylistsKey(try #require(model.navidromeScope))) == ["pl-dw"])
    }

    /// No writes to Aurral's playlists: every playlist edit refuses a Discover playlist and sends nothing.
    @Test func noPlaylistWritesToDiscover() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let dw = Playlist(id: "pl-dw", name: "Discover Weekly", songCount: 4, duration: 0, owner: "admin", readOnly: false)
        await #expect(throws: PlaylistEditError.notYours) { try await model.add(["m-x"], to: dw) }
        await #expect(throws: PlaylistEditError.notYours) { try await model.renamePlaylist(dw, to: "Mine") }
        await #expect(throws: PlaylistEditError.notYours) { try await model.removeSong(at: 0, songId: "a-lullaby", from: dw) }
        await #expect(throws: PlaylistEditError.notYours) { try await model.deletePlaylist(dw) }
        await #expect(throws: PlaylistEditError.notYours) { try await model.useLibraryCopies(in: dw) }
        #expect(nav.updates.isEmpty)
        #expect(!navidromeAsked.contains { $0.hasSuffix("deletePlaylist") })
    }

    // MARK: - The swap

    /// By recording id; else artist + title + duration within 3 s; never by name alone. Same position, "In your
    /// library"; every other entry untouched. Nothing is written anywhere.
    @Test func swapInPlace() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let page = try await model.discoverPage(playlistId: "pl-dw")
        #expect(page.flow?.id == "flow-dw")
        #expect(page.entries.map(\.song.id) == ["m-lullaby", "m-words", "a-other", "a-nameonly"])
        #expect(page.entries.map(\.inYourLibrary) == [true, true, false, false])
        #expect(page.entries.map(\.original.id) == ["a-lullaby", "a-words", "a-other", "a-nameonly"])
        #expect(nav.updates.isEmpty, "no write to the flow playlist")
        #expect(aurral.asked.allSatisfy { $0.hasPrefix("GET ") }, "only reads of Aurral")
        // The car plays the same (its adapter's playlist).
        let car = CarPlayLibraryAdapter(model: model)
        #expect(try await car.playlist(id: "pl-dw").1.map(\.id) == ["m-lullaby", "m-words", "a-other", "a-nameonly"])
    }

    /// Aurral's library is learnt from its job paths and left out of Home, Library, Search and the car (Y3's scope).
    @Test func aurralsLibraryLearntFromJobPaths() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        // Fix I2: learnt when Discover is first read (connecting), so Aurral's library is known before any page.
        #expect(model.discoverLibraryIds == [2])
        #expect(model.listedLibraryIds == [1])
        #expect(model.mainLibraryId == 1)
        #expect(model.session?.client.libraryScope == [1])
        model.disconnectAurral()
        #expect(model.discoverLibraryIds.isEmpty && model.listedLibraryIds == nil, "without Aurral, listed as before")
    }

    /// "Use your library's copy" in the owner's own playlist: one checked send, same positions.
    @Test func ownPlaylistSwapUsesTheCheckedWrite() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let road = try #require(try await model.editablePlaylists().first { $0.id == "pl-road" })
        let (_, songs) = try await model.request { try await $0.playlist(id: "pl-road") }
        #expect(await model.aurralCopiesInOwnPlaylist(road, songs: songs).mapValues(\.id) == [1: "m-lullaby", 3: "m-old"])
        #expect(try await model.useLibraryCopies(in: road) == 2)
        #expect(nav.updates.count == 1, "one send")
        let update = try #require(nav.updates.first)
        #expect(value(update, "playlistId") == "pl-road")
        #expect(items(update).filter { $0.name == "songIndexToRemove" }.map(\.value) == ["0", "1", "2", "3"])
        #expect(items(update).filter { $0.name == "songIdToAdd" }.map(\.value) == ["m-x", "m-lullaby", "m-y", "m-old"])
        #expect(nav.lists["pl-road"]?.songs == ["m-x", "m-lullaby", "m-y", "m-old"])
        #expect(try await model.useLibraryCopies(in: road) == 0, "nothing left: nothing sent")
        #expect(nav.updates.count == 1)
        // Someone else's playlist: refused by X3's ownership check, nothing sent.
        let theirs = Playlist(id: "pl-road", name: "Road trip", songCount: 4, duration: 0, owner: "someone", readOnly: false)
        await #expect(throws: PlaylistEditError.notYours) { try await model.useLibraryCopies(in: theirs) }
        #expect(nav.updates.count == 1)
    }

    // MARK: - Refresh Flow

    /// Refused while a run is under way (nothing sent); otherwise one start, then the progress shows.
    @Test func refreshFlowRefusedWhileActive() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        aurral.setRunning("flow-dw", true)
        await #expect(throws: AurralError.runActive) { try await model.refreshFlow("flow-dw") }
        #expect(!aurral.asked.contains { $0.hasPrefix("POST") })
        #expect(DiscoverCopy.message(for: AurralError.runActive) == DiscoverCopy.runActive)
        aurral.finishRun()
        try await model.refreshFlow("flow-dw")
        #expect(aurral.asked.filter { $0.hasPrefix("POST") } == ["POST /api/playlists/start/flow-dw"])
        #expect(model.isFlowRunActive("flow-dw"))
        #expect(model.discover.status?.progress(flowId: "flow-dw") == AurralProgress(done: 8, total: 20))
        await #expect(throws: AurralError.runActive) { try await model.refreshFlow("flow-dw") }
        #expect(aurral.asked.filter { $0.hasPrefix("POST") }.count == 1, "a second tap sends nothing")
        #expect(DiscoverCopy.refreshConfirm == "Replaces this playlist\u{2019}s songs")
    }

    // MARK: - Adding artists

    /// The page's artists come with Aurral's MusicBrainz ids, for Magpie's own Add (never Aurral's add).
    @Test func artistsInPlaylist() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let page = try await model.discoverPage(playlistId: "pl-dw")
        let artists = model.discoverArtists(page)
        #expect(artists.map(\.name) == ["Nobody", "Low"])
        #expect(artists.last?.mbid == MBID(artistMbid))
        #expect(model.discoverArtist(for: page.entries[3].original, flowId: "flow-dw").mbid == MBID(artistMbid))
        #expect(DiscoverCopy.addArtist("Low") == "Add Low to your library")
        #expect(!aurral.asked.contains { $0.contains("library/artists") })
    }

    // MARK: - Offline and sign-out

    @Test func offlineAsksNothing() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let before = aurral.requests.count
        await model.refreshDiscover(force: true)
        await #expect(throws: (any Error).self) { try await model.refreshFlow("flow-dw") }
        #expect(try await model.discoverPlaylists().isEmpty)
        #expect(aurral.requests.count == before, "nothing sent to Aurral offline")
        #expect(!model.homeSections.contains(.discover))
    }

    /// §5: Discover's own words name no service (Settings' Aurral page may, as Lidarr's does); curly quotes only.
    @Test func discoverCopyNamesNoService() {
        let texts = [DiscoverCopy.title, DiscoverCopy.refresh, DiscoverCopy.refreshConfirm, DiscoverCopy.refreshing,
                     DiscoverCopy.runActive, DiscoverCopy.inYourLibrary, DiscoverCopy.artistsInPlaylist, DiscoverCopy.empty,
                     DiscoverCopy.useLibraryCopy, DiscoverCopy.libraryCopies(1), DiscoverCopy.libraryCopies(2),
                     DiscoverCopy.usedLibraryCopies(2), DiscoverCopy.tooLong,
                     DiscoverCopy.progress(AurralProgress(done: 3, total: 20)),
                     DiscoverCopy.message(for: AurralError.unauthorized), DiscoverCopy.message(for: URLError(.timedOut))]
        for text in texts {
            for name in ["Lidarr", "Navidrome", "Aurral", "MusicBrainz"] { #expect(!text.contains(name), "\(text)") }
            #expect(!text.contains("'") && !text.contains("\""), "curly quotes: \(text)")
        }
        #expect(DiscoverCopy.progress(AurralProgress(done: 3, total: 20)) == "Getting songs: 3 of 20")
    }


    // MARK: - Fix round 1

    /// I1: the owner's own "Discover Weekly" (library songs) and an empty "Trending Mix" stay normal playlists: listed,
    /// editable, no Refresh; only Aurral's (its songs are the flow's) is Discover.
    @Test func sameNamedOwnPlaylistStaysNormal() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.discover.playlists.map(\.playlist.id) == ["pl-dw"])
        #expect(!model.isDiscoverPlaylist(id: "pl-mine") && !model.isDiscoverPlaylist(id: "pl-empty"))
        let mine = Playlist(id: "pl-mine", name: "Discover Weekly", songCount: 2, duration: 0, owner: "admin", readOnly: false)
        #expect(model.canEdit(mine))
        #expect(model.discoverFlow(playlistId: "pl-mine") == nil, "no Refresh Flow on it")
        try await model.add(["m-x"], to: mine)
        #expect(nav.lists["pl-mine"]?.songs == ["m-x", "m-y", "m-x"])
        #expect(try await model.discoverPlaylists().map(\.id) == ["pl-dw"])
    }

    /// I2: an Aurral copy that has left every flow is still recognised (by Aurral's library, read and saved), also after
    /// a relaunch with Aurral down.
    @Test func rotatedOutCopyIsStillSwapped() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let scope = try #require(model.navidromeScope)
        #expect(Set(defaults.stringArray(forKey: AppModel.aurralSongsKey(scope)) ?? []).isSuperset(of: ["a-old", "a-lullaby"]))
        let road = try #require(try await model.editablePlaylists().first { $0.id == "pl-road" })
        let (_, songs) = try await model.request { try await $0.playlist(id: "pl-road") }
        #expect(await model.aurralCopiesInOwnPlaylist(road, songs: songs).mapValues(\.id)[3] == "m-old")
        model.discover.forgetReads()   // as after a relaunch
        aurral.setDown(true)
        #expect(await model.aurralCopiesInOwnPlaylist(road, songs: songs).mapValues(\.id) == [1: "m-lullaby", 3: "m-old"])
    }

    /// I3: a start never seen running lets go after 2 minutes; a run that finished between reads lets go at once.
    @Test func refreshLatchExpires() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let start = Date()
        model.discover.now = { start }
        aurral.setStartBehaviour(.neverSeen)
        try await model.refreshFlow("flow-dw")
        #expect(model.isFlowRunActive("flow-dw"), "held while Aurral may not show it yet")
        await #expect(throws: AurralError.runActive) { try await model.refreshFlow("flow-dw") }
        model.discover.now = { start.addingTimeInterval(119) }
        await model.refreshDiscoverStatus()
        #expect(model.isFlowRunActive("flow-dw"))
        model.discover.now = { start.addingTimeInterval(121) }
        await model.refreshDiscoverStatus()
        #expect(!model.isFlowRunActive("flow-dw"), "never seen: let go after 2 minutes")
        aurral.setStartBehaviour(.finishesAtOnce)
        try await model.refreshFlow("flow-dw")
        #expect(aurral.asked.filter { $0.hasPrefix("POST") }.count == 2)
        #expect(!model.isFlowRunActive("flow-dw"), "Aurral's last run moved: finished, Refresh is back")
    }

    /// M1: each song's lookup is kept for the session; pull to refresh looks again.
    @Test func lookupsAreCached() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        _ = try await model.discoverPage(playlistId: "pl-dw")
        // The first page learns Aurral's library, which rescopes the client and reads the match index again in the
        // background (`/api/song`, which `nav.lookups` counts too): wait for it, so it can't land after `before`.
        await model.scopeIndexRefresh?.value
        let before = nav.lookups.count + navidromeAsked.filter { $0.hasSuffix("search3") }.count
        let again = try await model.discoverPage(playlistId: "pl-dw")
        #expect(nav.lookups.count + navidromeAsked.filter { $0.hasSuffix("search3") }.count == before, "nothing asked again")
        #expect(again.entries.map(\.song.id) == ["m-lullaby", "m-words", "a-other", "a-nameonly"])
        _ = try await model.discoverPage(playlistId: "pl-dw", fresh: true)
        #expect(nav.lookups.count + navidromeAsked.filter { $0.hasSuffix("search3") }.count > before)
    }

    /// M6: a connection never prints its key.
    @Test func connectionsHideTheirKeys() {
        let aurralConnection = AurralConnection(base: URL(string: "http://aurral:3001")!, apiKey: "secret-aurral-key")
        let lidarrConnection = LidarrConnection(base: URL(string: "http://lidarr:8686")!, apiKey: "secret-lidarr-key")
        for text in [String(describing: aurralConnection), String(reflecting: aurralConnection), "\(aurralConnection)",
                     String(describing: lidarrConnection), String(reflecting: lidarrConnection)] {
            #expect(!text.contains("secret"), "\(text)")
        }
    }

    @Test func signOutForgetsAurral() async throws {
        let model = try await signedIn()
        model.signOut()
        let keys = defaults.dictionaryRepresentation().keys
        #expect(!keys.contains { $0.hasPrefix(AppModel.discoverPlaylistsKeyPrefix) || $0.hasPrefix(AppModel.discoverLibrariesKeyPrefix)
                                 || $0.hasPrefix(AppModel.aurralSongsKeyPrefix) }, "M7: the account's Discover keys go")
        #expect(aurralStore.load() == nil && !model.aurralSetUp)
        #expect(model.discover.playlists.isEmpty)
    }
}
