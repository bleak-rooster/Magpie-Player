import AurralKit
import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Requests
import Testing
@testable import Magpie

private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let firstTrack = MBID("5e0c3c2a-1111-4a6e-9d2c-7b1a2f3e4d51")!

private func ok(_ body: String = "") -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(body.isEmpty ? "" : "," + body)}}"#.utf8)
}
private func items(_ r: URLRequest) -> [URLQueryItem] {
    r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
}
private func value(_ r: URLRequest, _ name: String) -> String? { items(r).first { $0.name == name }?.value }
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)

/// A Navidrome with playlists of several owners, whose `songCount` can disagree with the listing (entries it hides).
final class PlaylistsNavidrome: @unchecked Sendable {
    struct List { var name: String; var owner: String; var songs: [String]; var hidden = 0 }
    private let lock = NSLock()
    var lists: [String: List] = [
        "pl-road": List(name: "Road Trip", owner: "admin", songs: ["m-x", "f1", "m-y", "f1", "f2"]),
        "pl-chill": List(name: "Chill", owner: "admin", songs: ["f2", "m-z"]),
        "pl-theirs": List(name: "Their Mix", owner: "someone", songs: ["f1", "m-q"]),
        "pl-clean": List(name: "Clean", owner: "admin", songs: ["m-x"]),
    ]
    private(set) var updates: [URLRequest] = []
    /// Playlists whose read fails (a clean-up of them stays unfinished).
    var broken: Set<String> = []
    private(set) var reads = 0

    func list(_ id: String) -> [String] { lock.withLock { lists[id]?.songs ?? [] } }
    func set(_ id: String, _ change: (inout List) -> Void) { lock.withLock { if var l = lists[id] { change(&l); lists[id] = l } } }
    func updates(of id: String) -> [URLRequest] { lock.withLock { updates.filter { value($0, "playlistId") == id } } }

    private func entry(_ id: String) -> String {
        #"{"id":"\#(id)","title":"Song \#(id)","artist":"A","album":"B","albumId":"al-\#(id)","duration":100}"#
    }

    func install(on t: MockTransport) {
        t.stub(pathSuffix: "/rest/ping", body: ok())
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/rest/getMusicFolders", body: ok(#""musicFolders":{"musicFolder":[{"id":1,"name":"Music"}]}"#))
        t.stub(pathSuffix: "/rest/getPlaylists") { _ in
            let rows = self.lock.withLock { self.lists.sorted { $0.key < $1.key }.map { id, l in
                #"{"id":"\#(id)","name":"\#(l.name)","owner":"\#(l.owner)","readonly":\#(l.owner == "admin" ? "false" : "true"),"songCount":\#(l.songs.count + l.hidden)}"#
            } }
            return .init(status: 200, body: ok(#""playlists":{"playlist":[\#(rows.joined(separator: ","))]}"#))
        }
        t.stub(pathSuffix: "/rest/getPlaylist") { r in
            let id = value(r, "id") ?? ""
            let failing = self.lock.withLock { () -> Bool in self.reads += 1; return self.broken.contains(id) }
            if failing { return .init(status: 500) }
            guard let l = self.lock.withLock({ self.lists[id] }) else { return .init(status: 404) }
            let entries = l.songs.map(self.entry).joined(separator: ",")
            return .init(status: 200, body: ok(#""playlist":{"id":"\#(id)","name":"\#(l.name)","owner":"\#(l.owner)","readonly":\#(l.owner == "admin" ? "false" : "true"),"songCount":\#(l.songs.count + l.hidden),"entry":[\#(entries)]}"#))
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

/// Round 15 C3 (owner item 7, D137, D138): a rejected find's clean exit from the owner's playlists, in the app against
/// a mock Navidrome (and StubAurral 2.13, as the owner's setup has it).
@MainActor @Suite(.serialized) final class FindCleanupAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "FindCleanupAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "FindCleanupAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = Round14Routing()
    let nav = PlaylistsNavidrome()
    let aurralStore = MemoryAurralStore()

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    func model(lidarr: Bool = true, aurral: Bool = true, notifications: Bool = false) async throws -> AppModel {
        transport.aurral.useAurral213()
        nav.install(on: transport.navidrome)
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: lidarrBase, apiKey: "dev-key")) }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), previewTransport: transport, defaults: defaults,
                             systemNowPlaying: false, notifications: notifications, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        model.aurralFeeds.phoneRegion = { nil }
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        if aurral {
            _ = try await model.connectAurral(base: transport.aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return model
    }
    // MARK: - A rejected find leaves the owner's playlists (D137, D138)

    @Test func aRejectedFindLeavesEveryOwnPlaylistWithDuplicatesAndNothingElse() async throws {
        let model = try await model()
        defer { model.signOut() }
        let message = await model.cleanUpAfterLetGo(requestId: RequestID(), title: "Harbour Lights", songIds: ["f1", "f2"])
        #expect(nav.list("pl-road") == ["m-x", "m-y"], "both copies of f1 and f2 gone, the others in order")
        #expect(nav.list("pl-chill") == ["m-z"])
        #expect(nav.list("pl-clean") == ["m-x"] && nav.updates(of: "pl-clean").isEmpty, "nothing sent where it isn't")
        #expect(message == "Removed \u{201C}Harbour Lights\u{201D} from 2 playlists: Chill, Road Trip")
        // Highest index first, in one write per playlist.
        let road = nav.updates(of: "pl-road")
        #expect(road.count == 1)
        #expect(items(road[0]).filter { $0.name == "songIndexToRemove" }.compactMap(\.value) == ["4", "3", "1"])
        #expect(items(road[0]).allSatisfy { $0.name != "songIdToAdd" })
        // The short history.
        let done = try #require(model.letGo.history.first)
        #expect(done.title == "Harbour Lights" && done.playlists == ["Chill", "Road Trip"] && done.finishedAt != nil)
        #expect(model.libraryEdits.notice?.text == message, "the in-app message")
    }

    @Test func aPlaylistTheUserDoesntOwnIsNeverTouched() async throws {
        let model = try await model()
        defer { model.signOut() }
        _ = await model.cleanUpAfterLetGo(requestId: RequestID(), title: "Harbour Lights", songIds: ["f1"])
        #expect(nav.list("pl-theirs") == ["f1", "m-q"] && nav.updates(of: "pl-theirs").isEmpty)
    }

    @Test func aPlaylistWithEntriesTheServerHidesIsLeftAndSaidSo() async throws {
        let model = try await model()
        defer { model.signOut() }
        nav.set("pl-chill") { $0.hidden = 1 }   // its count says one more than it lists
        let message = await model.cleanUpAfterLetGo(requestId: RequestID(), title: "Harbour Lights", songIds: ["f2"])
        #expect(nav.list("pl-chill") == ["f2", "m-z"] && nav.updates(of: "pl-chill").isEmpty)
        #expect(nav.list("pl-road") == ["m-x", "f1", "m-y", "f1"])
        #expect(message == "Removed \u{201C}Harbour Lights\u{201D} from Road Trip. Chill couldn\u{2019}t be checked, so it was left as it is.")
    }

    @Test func aPendingPlaylistAddForTheFindIsCleared() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.followPendingAdds(instance: "lidarr-a")
        let rejected = RequestID(), other = RequestID()
        let recording = ExternalRecording(recordingMBID: firstTrack, title: "Harbour Lights", artist: "Stub Arrows",
                                          duration: 196, source: .lidarr)
        let mine = PendingPlaylistAdd(playlistId: "pl-road", playlistName: "Road Trip", recording: recording,
                                      requestId: rejected, createdAt: Date())
        let theirs = PendingPlaylistAdd(playlistId: "pl-road", playlistName: "Road Trip", recording: recording,
                                        requestId: other, createdAt: Date())
        model.songActions.pending = [mine, theirs]
        _ = await model.cleanUpAfterLetGo(requestId: rejected, title: "Harbour Lights", songIds: ["f1"])
        #expect(model.songActions.pending.map(\.id) == [theirs.id])
        let saved = try await PlaylistAddStore(fileURL: PlaylistAddStore.defaultURL(in: tmp, instance: "lidarr-a")).load()
        #expect(saved.map(\.id) == [theirs.id], "saved without it")
    }

    /// Interrupted (the app went away mid-way): the saved clean-up is finished on the next start, removing only what is
    /// still there; a second pass sends nothing.
    @Test func anInterruptedCleanupIsFinishedLaterAndIsSafeToRepeat() async throws {
        let url = FindCleanupStore.defaultURL(in: tmp, instance: "lidarr-a")
        var job = FindCleanup(requestId: RequestID(), title: "Harbour Lights", songIds: ["f1", "f2"], createdAt: Date())
        job.playlists = ["Chill"]
        nav.set("pl-chill") { $0.songs = ["m-z"] }   // that one was done before the interruption
        try await FindCleanupStore(fileURL: url).save([job])
        let model = try await model(lidarr: false)   // no runner rebuild following another Lidarr meanwhile
        defer { model.signOut() }
        model.followFindCleanups(instance: "lidarr-a")
        #expect(await eventually { model.letGo.history.first?.finishedAt != nil })
        #expect(nav.list("pl-road") == ["m-x", "m-y"])
        #expect(model.letGo.history.first?.playlists == ["Chill", "Road Trip"])
        let sent = nav.updates.count
        await model.resumeLetGoCleanups()
        #expect(nav.updates.count == sent, "finished: nothing more is sent")
        #expect(await eventually { (try? await FindCleanupStore(fileURL: url).load().first?.finishedAt) != nil }, "saved finished")
    }

    @Test func finishingInTheBackgroundPostsALocalNotification() async throws {
        let model = try await model(notifications: true)
        defer { model.signOut() }
        model.isForeground = false
        let message = await model.cleanUpAfterLetGo(requestId: RequestID(), title: "Harbour Lights", songIds: ["f2"])
        #expect(model.letGo.posted.count == 1)
        #expect(model.letGo.posted.first?.title == "Let go from your Finds")
        #expect(model.letGo.posted.first?.body == message)
        model.isForeground = true
        _ = await model.cleanUpAfterLetGo(requestId: RequestID(), title: "Other", songIds: ["m-z"])
        #expect(model.letGo.posted.count == 1, "in the foreground: the in-app message only")
    }

    @Test func withNotificationsOffItIsInAppOnly() async throws {
        let model = try await model(notifications: false)
        defer { model.signOut() }
        model.isForeground = false
        _ = await model.cleanUpAfterLetGo(requestId: RequestID(), title: "Harbour Lights", songIds: ["f2"])
        #expect(model.letGo.posted.isEmpty && model.letGo.history.count == 1)
    }

    @Test func aFindInNoPlaylistSaysNothingExtra() async throws {
        let model = try await model()
        defer { model.signOut() }
        let message = await model.cleanUpAfterLetGo(requestId: RequestID(), title: "Harbour Lights", songIds: ["f9"])
        #expect(message == nil && nav.updates.isEmpty)
        #expect(model.letGo.history.first?.playlists == [])
    }

    /// Review M4: an unfinished clean-up is retried with a back-off (1, 5, then 15 minutes), not on every poll.
    @Test func anUnfinishedCleanupBacksOff() async throws {
        let model = try await model()
        defer { model.signOut() }
        nav.broken = ["pl-chill"]
        _ = await model.cleanUpAfterLetGo(requestId: RequestID(), title: "Harbour Lights", songIds: ["f2"])
        #expect(model.letGo.jobs.first?.finishedAt == nil, "unfinished: a playlist couldn't be read")
        await model.resumeLetGoCleanups()
        let reads = nav.reads
        await model.resumeLetGoCleanups()
        await model.resumeLetGoCleanups()
        #expect(nav.reads == reads, "not again before its time")
        #expect(AppModel.cleanupBackoff(0) == 60 && AppModel.cleanupBackoff(1) == 300 && AppModel.cleanupBackoff(5) == 900)
    }

    @Test func theWordsNeverNameAService() {
        var job = FindCleanup(requestId: RequestID(), title: "Song", songIds: ["f1"], createdAt: Date())
        job.playlists = ["Road Trip"]
        job.skipped = ["Chill"]
        let words = [FindCleanupCopy.recentlyLetGo, FindCleanupCopy.notificationTitle, FindCleanupCopy.inNoPlaylist,
                     FindCleanupCopy.historyLine(job)]
        for w in words {
            #expect(!w.localizedCaseInsensitiveContains("aurral") && !w.localizedCaseInsensitiveContains("lidarr")
                    && !w.localizedCaseInsensitiveContains("navidrome"), "\(w)")
        }
        #expect(FindCleanupCopy.historyLine(job)
                == "Removed \u{201C}Song\u{201D} from Road Trip. Chill couldn\u{2019}t be checked, so it was left as it is.")
    }
}
