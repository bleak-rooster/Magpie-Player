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

/// Round 22 R22P (owner, 2026-11-06): Library › Playlists shows All or only Yours (D179–D180).
@MainActor @Suite(.serialized) final class PlaylistsShowAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "PlaylistsShowAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "PlaylistsShowAppTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedInModel(as username: String = "admin") async throws -> AppModel {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok())
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)   // the session takes `username`
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        try await model.signIn(urls: [home], username: username, password: "pw")
        return model
    }

    private func playlist(_ id: String, owner: String?, readOnly: Bool? = false) -> Playlist {
        Playlist(id: id, name: id, songCount: 0, duration: 0, owner: owner, readOnly: readOnly)
    }

    /// "Yours" is Save to playlist's rule (D101, `isOwn`): the owner named and matching the signed-in user, compared
    /// case-insensitively and as given (no trimming), not read-only; an unnamed owner is never yours.
    @Test func yoursUsesTheSameOwnerRuleAsSaveToPlaylist() {
        let lists = [
            playlist("mine", owner: "admin"),
            playlist("shouting", owner: "ADMIN"),
            playlist("padded", owner: " admin "),
            playlist("theirs", owner: "listener"),
            playlist("nobody", owner: nil),
            playlist("blank", owner: ""),
            playlist("locked", owner: "admin", readOnly: true),
        ]
        #expect(AppModel.shown(lists, .all, user: "admin").map(\.id) == lists.map(\.id), "All: every playlist")
        let yours = AppModel.shown(lists, .yours, user: "admin")
        #expect(yours.map(\.id) == ["mine", "shouting"])
        #expect(yours.map(\.id) == lists.filter { AppModel.isOwn($0, by: "admin") }.map(\.id), "the one owner rule")
        #expect(AppModel.shown(lists, .yours, user: "").isEmpty, "no user: nothing is yours")
    }

    @Test func theChoiceDefaultsToAllAndIsRememberedPerAccount() async throws {
        let model = try await signedInModel()
        #expect(model.playlistShow == .all, "All by default")
        model.playlistShow = .yours
        #expect(model.playlistShow == .yours)
        let scope = try #require(model.navidromeScope)
        #expect(defaults.string(forKey: AppModel.playlistShowKey(scope)) == "yours")

        // Another launch: the same account finds its choice.
        let relaunched = try await signedInModel()
        #expect(relaunched.playlistShow == .yours)

        // Another account on the same server starts at All, and changing it leaves the first account's alone.
        let other = try await signedInModel(as: "jordan")
        #expect(other.navidromeScope != scope)
        #expect(other.playlistShow == .all)
        other.playlistShow = .all
        #expect(defaults.string(forKey: AppModel.playlistShowKey(scope)) == "yours")

        // A bad saved value reads as All; signing out forgets the choice with the rest of the account.
        defaults.set("bogus", forKey: AppModel.playlistShowKey(try #require(other.navidromeScope)))
        #expect(other.playlistShow == .all)
        let mine = try await signedInModel()
        #expect(mine.playlistShow == .yours)
        mine.signOut()
        #expect(defaults.string(forKey: AppModel.playlistShowKey(scope)) == nil)
    }

    @Test func playlistsListFollowsTheChoiceAndSaysWhenYoursIsEmpty() async throws {
        let model = try await signedInModel()
        let server = FakePlaylistServer()
        server.put("p1", .init(name: "Road Trip", owner: "listener", readonly: true, songs: []))
        server.put("p2", .init(name: "Chill", owner: "listener", readonly: true, songs: []))
        server.install(on: transport.inner)

        let all = try await model.libraryPlaylists()
        #expect(all.map(\.name) == ["Chill", "Road Trip"], "A–Z")
        #expect(AppModel.shown(all, .all, user: "admin").count == 2)
        #expect(AppModel.shown(all, .yours, user: "admin").isEmpty)
        #expect(PlaylistShow.yours.emptyTitle == "You haven\u{2019}t made any playlists yet.")
        #expect(PlaylistShow.all.emptyTitle == "No playlists yet")
        #expect(PlaylistShow.allCases.map(\.title) == ["All", "Yours"])

        server.put("p3", .init(name: "Mine", owner: "admin", readonly: false, songs: []))
        let again = try await model.libraryPlaylists()
        #expect(AppModel.shown(again, .yours, user: "admin").map(\.name) == ["Mine"])
    }

    /// The car's Playlists list follows the phone's choice (it reads the same playlists).
    @Test func theCarsPlaylistsFollowTheChoice() async throws {
        let model = try await signedInModel()
        let server = FakePlaylistServer()
        server.put("p1", .init(name: "Theirs", owner: "listener", readonly: true, songs: []))
        server.put("p2", .init(name: "Mine", owner: "admin", readonly: false, songs: []))
        server.install(on: transport.inner)
        let car = CarPlayLibraryAdapter(model: model)
        #expect(try await car.playlists().map(\.id) == ["p1", "p2"])
        model.playlistShow = .yours
        #expect(try await car.playlists().map(\.id) == ["p2"])
    }
}
