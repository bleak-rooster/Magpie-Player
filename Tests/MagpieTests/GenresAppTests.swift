import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import os
import Search
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

private func subsonic(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

private func query(_ request: URLRequest, _ name: String) -> String? {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems?.first { $0.name == name }?.value
}

/// Task 19: the genre screens' model: groups merged from their genres, group Shuffle capped at 500, a genre's songs in
/// server order, the owner's moves, new groups, names and hidden groups, and offline genres from the phone.
@MainActor @Suite(.serialized) final class GenresAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "GenresAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "GenresAppTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    let engine = FakeEngine()

    init() {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        transport.inner.stub(pathSuffix: "/rest/getGenres", body: subsonic(#"""
        "genres":{"genre":[{"value":"Indie Rock","songCount":10,"albumCount":1},{"value":"Alt Rock","songCount":20,"albumCount":2},
        {"value":"Ambient","songCount":12,"albumCount":2},{"value":"Chanson","songCount":6,"albumCount":1}]}
        """#))
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2") { request in
            let size = Int(query(request, "size") ?? "0") ?? 0, offset = Int(query(request, "offset") ?? "0") ?? 0
            let ids: [String] = switch query(request, "genre") {
            case "Indie Rock": ["a1", "a2"]
            case "Alt Rock": ["a2", "a3"]
            case "Ambient": Array((0..<600).map { "am\($0)" }.dropFirst(offset).prefix(size))   // over the cap
            default: []
            }
            let albums = ids.map { #"{"id":"\#($0)","name":"\#($0)","artist":"A","songCount":1}"# }.joined(separator: ",")
            return MockTransport.Response(status: 200, body: subsonic(#""albumList2":{"album":[\#(albums)]}"#))
        }
        transport.inner.stub(pathSuffix: "/rest/getSongsByGenre") { request in
            let (prefix, total): (String, Int) = switch query(request, "genre") {
            case "Indie Rock": ("ir", 300)
            case "Alt Rock": ("ar", 300)
            case "Ambient": ("am", 20)
            default: ("", 0)
            }
            let offset = Int(query(request, "offset") ?? "0") ?? 0, count = Int(query(request, "count") ?? "0") ?? 0
            let ids = (0..<total).map { "\(prefix)\($0)" }
            let page = ids.dropFirst(offset).prefix(count)
            let songs = page.map { #"{"id":"\#($0)","title":"\#($0)","genre":"\#(query(request, "genre")!)"}"# }
                .joined(separator: ",")
            return MockTransport.Response(status: 200, body: subsonic(#""songsByGenre":{"song":[\#(songs)]}"#))
        }
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A second model over the same defaults (a relaunch).
    func makeModel(fetcher: any AudioFetching) -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                 matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                 engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                 network: FakeNetwork(.wifi), audioFetcher: fetcher)
    }

    func signedInModel(fetcher: any AudioFetching) async throws -> AppModel {
        let model = makeModel(fetcher: fetcher)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        return model
    }

    func song(_ id: String, genre: String?, album: String) -> Song {
        Song(id: id, title: "T\(id)", artist: "A", album: album, albumId: album, track: Int(id.dropFirst()),
             duration: 200, genre: genre)
    }

    // MARK: - The brief's tests

    @Test func groupAlbumsMergedAndDeduped() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(try await model.groupAlbums("rock").map(\.id) == ["a1", "a2", "a3"])
    }

    @Test func groupSongsCappedAt500AndShuffled() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let songs = try await model.groupSongs("rock")
        #expect(songs.count == 500 && Set(songs.map(\.id)).count == 500)
        // Fix round 1: round-robin across the genres (server order: Indie Rock, then Alt Rock), 250 from each, then
        // shuffled: the order differs from the order fetched.
        let fetched = (0..<250).flatMap { ["ir\($0)", "ar\($0)"] }
        let page = try #require(try await model.genreGroup("rock"))
        #expect(try await model.groupSongsInFetchOrder(page.genres).map(\.id) == fetched)
        #expect(Set(songs.map(\.id)) == Set(fetched))
        #expect(songs.map(\.id) != fetched, "shuffled")
    }

    @Test func genreSongsKeepServerOrder() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let songs = try await model.genreSongs("Indie Rock")
        #expect(songs.count == 300 && songs.prefix(3).map(\.id) == ["ir0", "ir1", "ir2"])
    }

    @Test func moveGenreSurvivesRelaunch() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.moveGenre("Ambient", toGroup: "rock")
        let again = try await signedInModel(fetcher: FakeFetcher())   // same defaults
        let rock = try #require(try await again.genreSections().first { $0.group.id == "rock" })
        #expect(rock.genres.map(\.name) == ["Alt Rock", "Ambient", "Indie Rock"])
        #expect(!(try await again.genreSections()).contains { $0.group.id == "electronic" })
    }

    @Test func newGroupNamed() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let id = model.createGroup(named: "Dinner")
        #expect(id.hasPrefix("custom."))
        model.moveGenre("Chanson", toGroup: id)
        let dinner = try #require(try await model.genreSections().first { $0.group.id == id })
        #expect(dinner.group.name == "Dinner" && dinner.genres.map(\.name) == ["Chanson"])
        model.renameGroup(id, to: "Supper")
        #expect(try await model.genreSections().first { $0.group.id == id }?.group.name == "Supper")
    }

    @Test func hiddenGroupLeavesAllGenresIntact() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.setGroupHidden("rock", true)
        #expect(!(try await model.genreSections()).contains { $0.group.id == "rock" })
        #expect(try await model.allGenres().map(\.name) == ["Alt Rock", "Ambient", "Chanson", "Indie Rock"])
        model.setGroupHidden("rock", false)
        #expect(try await model.genreSections().contains { $0.group.id == "rock" })
    }

    // MARK: - Additions

    /// The group page asks each of its genres for albums and the genre page for its own.
    @Test func genreAlbumsAndGroupLookup() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(try await model.genreAlbums("Alt Rock").map(\.id) == ["a2", "a3"])
        let rock = try #require(try await model.genreGroup("rock")?.section)
        #expect(rock.group.name == "Rock" && rock.albumCount == 3 && rock.songCount == 30)
        model.setGroupHidden("rock", true)
        #expect(try await model.genreGroup("rock")?.section != nil, "a hidden group's page still opens")
    }

    /// Moving a genre back to the group its rules give stores nothing; an emptied custom group is let go.
    @Test func moveBackClearsTheOverride() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let id = model.createGroup(named: "  Dinner  ")
        model.moveGenre("Chanson", toGroup: id)
        #expect(model.preferences.genres.groupNames[id] == "Dinner")
        model.moveGenre("Chanson", toGroup: "world")
        #expect(model.preferences.genres.assignments.isEmpty)
        #expect(model.preferences.genres.customGroups.isEmpty && model.preferences.genres.groupNames.isEmpty)
        #expect(try await model.genreSections().first { $0.group.id == "world" }?.genres.map(\.name) == ["Chanson"])
    }

    /// Renaming a built-in group to nothing gives it its own name back; the Move sheet lists the groups not hidden.
    @Test func renameAndChoices() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.renameGroup("rock", to: "Guitars")
        #expect(try await model.genreGroup("rock")?.section.group.name == "Guitars")
        model.renameGroup("rock", to: "   ")
        #expect(try await model.genreGroup("rock")?.section.group.name == "Rock")
        model.setGroupHidden("jazz", true)
        let choices = model.genreGroupChoices
        #expect(choices.count == GenreGroups.builtIn.count - 1 && !choices.contains { $0.id == "jazz" })
        #expect(model.canCreateGroup)
    }

    /// The mode control's preference persists.
    @Test func modePersists() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.genres.mode = .all }
        let again = makeModel(fetcher: FakeFetcher())
        #expect(again.preferences.genres.mode == .all)
    }

    /// Offline: the genres are the downloads' genres, Play and Shuffle use only songs on the phone, and nothing is sent.
    @Test func offlineGenresFromThePhone() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1", genre: "Indie Rock", album: "al1"), song("s2", genre: "Indie Rock", album: "al1"),
                        song("s3", genre: "Alt Rock", album: "al2"), song("s4", genre: "Ambient", album: "al3")],
                       reason: .song)
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let seen = Recorder()
        transport.setHook { seen.add($0) }
        defer { transport.setHook(nil) }
        let sections = try await model.genreSections()
        #expect(sections.map(\.group.id) == ["rock", "electronic"])
        #expect(sections[0].genres.map(\.name) == ["Alt Rock", "Indie Rock"] && sections[0].songCount == 3)
        #expect(try await model.allGenres().map(\.name) == ["Alt Rock", "Ambient", "Indie Rock"])
        #expect(try await model.genreSongs("Indie Rock").map(\.id) == ["s1", "s2"])
        #expect(Set(try await model.groupSongs("rock").map(\.id)) == ["s1", "s2", "s3"])
        #expect(try await model.groupAlbums("rock").map(\.id) == ["al1", "al2"])
        #expect(try await model.genreAlbums("Ambient").map(\.id) == ["al3"])
        #expect(try await model.genreGroup("rock")?.genres.count == 2)
        #expect(seen.urls.isEmpty, "sent: \(seen.urls.map(\.path))")
    }

    // MARK: - Fix round 1

    /// I1: a genre gives at most one page of `genreAlbumCap` albums, on the genre page and the group page alike.
    @Test func genreAlbumsCappedAtOnePage() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let before = transport.inner.requests.count
        #expect(try await model.genreAlbums("Ambient").count == AppModel.genreAlbumCap)
        #expect(try await model.groupAlbums("electronic").count == AppModel.genreAlbumCap)
        let asks = transport.inner.requests.dropFirst(before).filter { $0.url?.path.hasSuffix("/getAlbumList2") == true }
        #expect(asks.count == 2 && asks.allSatisfy { query($0, "size") == "500" && query($0, "offset") == "0" })
    }

    /// I1: the group's genres are asked together, and the merge keeps the genres' order whichever answers first.
    @Test func groupAlbumsMergeOrderUnderConcurrency() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let altAskedMeanwhile = OSAllocatedUnfairLock(initialState: false)
        let altSeen = OSAllocatedUnfairLock(initialState: false)
        transport.setHook { request in
            guard request.url?.path.hasSuffix("/getAlbumList2") == true else { return }
            switch query(request, "genre") {
            case "Indie Rock":   // the first genre answers last
                try? await Task.sleep(for: .milliseconds(300))
                altAskedMeanwhile.withLock { $0 = altSeen.withLock { $0 } }
            case "Alt Rock": altSeen.withLock { $0 = true }
            default: break
            }
        }
        defer { transport.setHook(nil) }
        #expect(try await model.groupAlbums("rock").map(\.id) == ["a1", "a2", "a3"])
        #expect(altAskedMeanwhile.withLock { $0 }, "Alt Rock was asked while Indie Rock was still answering")
    }

    /// Ruling (b): a small genre gives what it has and the big ones share the rest.
    @Test func groupShuffleRoundRobinUneven() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.moveGenre("Ambient", toGroup: "rock")
        let songs = try await model.groupSongs("rock")
        func count(_ prefix: String) -> Int { songs.filter { $0.id.hasPrefix(prefix) }.count }
        #expect(songs.count == 500 && Set(songs.map(\.id)).count == 500)
        #expect(count("am") == 20 && count("ir") == 240 && count("ar") == 240)
    }

    /// Ruling (c): the 65th move and a name too long to keep are refused with a message, and nothing changes.
    @Test func movesThatCantBeKeptAreRefused() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { prefs in
            for i in 0..<GenrePreferences.maxAssignments { prefs.genres.assignments["genre \(i)"] = "rock" }
        }
        let before = model.preferences.genres
        #expect(model.moveGenre("Chanson", toGroup: "rock") == .tooManyMoves)
        #expect(AppModel.GenreMoveRefusal.tooManyMoves.message
                == "You've moved as many genres as Magpie can keep. Move some back first.")
        #expect(model.moveGenre("genre 3", toGroup: "jazz") == nil, "changing a kept move still works")
        #expect(model.moveGenre("Chanson", toGroup: "world") == nil, "back to its own group needs no room")
        let long = String(repeating: "x", count: GenrePreferences.maxTextLength + 1)
        #expect(model.moveGenre(long, toGroup: "rock") == .nameTooLong)
        #expect(AppModel.GenreMoveRefusal.nameTooLong.message == "This genre's name is too long to move.")
        #expect(model.preferences.genres.assignments.count == before.assignments.count)
        #expect(model.preferences.genres.assignments["genre 3"] == "jazz")
    }
}
