import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Synchronization
import Testing
import UIKit
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

extension AppModel {
    /// Tests: answers `path` with a Subsonic `ok` body holding `fragment` (the fixture's `HostSwitchTransport`).
    func transport(stub path: String, _ fragment: String) {
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","# + fragment + "}}"
        (transport as? HostSwitchTransport)?.inner.stub(pathSuffix: path, body: Data(body.utf8))
    }
}

@MainActor @Suite(.serialized) final class DownloadsAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "DownloadsAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "DownloadsAppTests.\(UUID().uuidString)")!

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedInModel(fetcher: FakeFetcher, user: String = "admin") async throws -> AppModel {
        let transport = HostSwitchTransport()
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: fetcher)
        try await model.signIn(urls: [home], username: user, password: "pw")
        return model
    }

    func song(_ id: String) -> Song { PlayerTests.song(id) }

    // MARK: - The brief's tests

    @Test func signOutRemovesScopeAudio() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let dir = try #require(model.downloads?.storeDirectory)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        model.signOut()
        #expect(model.downloads == nil)
        #expect(await eventually { !FileManager.default.fileExists(atPath: dir.path) })
    }

    @Test func lateCompletionAfterSignOutIsDiscarded() async throws {           // Review Focus 3
        let f = FakeFetcher(); f.hold(after: 0)
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1")], reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        let oldDir = try #require(model.downloads?.storeDirectory)
        model.signOut()
        try await model.signIn(urls: [home], username: "other", password: "pw")
        let newDir = try #require(model.downloads?.storeDirectory)
        #expect(newDir != oldDir)
        f.release(); try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
        #expect(await model.downloads!.store.entry(songId: "s1") == nil)
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func fetchThatIgnoresCancellationStillLandsNowhere() async throws {
        let f = FakeFetcher(); f.hold(after: 0); f.ignoresCancellation = true
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1")], reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        let oldDir = try #require(model.downloads?.storeDirectory)
        model.signOut()
        try await model.signIn(urls: [home], username: "other", password: "pw")
        model.download([song("s2")], reason: .song)
        f.release()
        await model.downloads!.settled()
        #expect(await eventually { !FileManager.default.fileExists(atPath: oldDir.path) })
        #expect(await model.downloads!.store.entry(songId: "s1") == nil)
        #expect(Set(model.downloads!.localFiles.keys) == ["s2"])
        #expect(!f.written.contains { FileManager.default.fileExists(atPath: $0.path) }, "no temporary file left")
    }

    @Test func albumDownloadSavesItsCover() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1"), song("s2")], reason: .album("a1"), coverArtId: "al-1"); await model.downloads!.settled()
        let cover = try #require(f.urls.first { $0.path.hasSuffix("/rest/getCoverArt") })
        #expect(URLComponents(url: cover, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "size" }?.value == "600")
        #expect(await model.downloads!.store.coverURL(coverArtId: "al-1") != nil)
    }

    @Test func playlistRefreshOnOpen() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let p = Playlist(id: "p1", name: "Mix", songCount: 2, duration: 400, coverArtId: "pl-1")
        model.download([song("s1"), song("s2")], reason: .playlist("p1"),
                       playlist: DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: "pl-1", songIds: ["s1", "s2"], savedAt: .now),
                       coverArtId: "pl-1")
        await model.downloads!.settled()
        await model.refreshDownloadedPlaylist(p, songs: [song("s2"), song("s3")])
        await model.downloads!.settled()
        #expect(Set(model.downloads!.localFiles.keys) == ["s2", "s3"])
        #expect(await model.downloads!.store.playlists().first?.songIds == ["s2", "s3"])
    }

    @Test func favouritesToggle() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.transport(stub: "/rest/getStarred2", #""starred2":{"song":[{"id":"s7","title":"Seven"},{"id":"s8","title":"Eight"}]}"#)
        await model.setKeepFavourites(true); await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s7")?.reasons == [.favourites])
        #expect(Set(model.downloads!.localFiles.keys) == ["s7", "s8"])
        await model.setKeepFavourites(false)
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func reDownloadAtNewQuality() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        model.updatePreferences { $0.downloads.quality = .mp3_320 }
        await model.redownloadAtCurrentQuality(); await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s1")?.quality == .mp3_320)
        let audio = try FileManager.default.contentsOfDirectory(atPath: model.downloads!.storeDirectory.path)
            .filter { $0.hasSuffix(".mp3") || $0.hasSuffix(".flac") }
        #expect(audio.count == 1)
    }

    // MARK: - More

    @Test func playlistNotDownloadedIsNotRefreshed() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        await model.downloads!.settled()
        let p = Playlist(id: "p9", name: "Other", songCount: 1, duration: 200)
        await model.refreshDownloadedPlaylist(p, songs: [song("s1")])
        await model.downloads!.settled()
        #expect(f.urls.isEmpty)
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func signInAgainToTheSameAccountKeepsNewDownloads() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let dir = try #require(model.downloads?.storeDirectory)
        model.signOut()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        #expect(model.downloads?.storeDirectory == dir, "the same account's scope")
        model.download([song("s2")], reason: .song); await model.downloads!.settled()
        #expect(Set(model.downloads!.localFiles.keys) == ["s2"], "the old audio was erased, the new kept")
        #expect(await model.downloads!.store.entry(songId: "s2") != nil)
    }

    @Test func songDownloadAndRemove() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1"), song("s2")], reason: .album("a1")); await model.downloads!.settled()
        #expect(model.downloadStatus(["s1", "s2"]) == .downloaded)
        #expect(model.songRemovalNote("s1") == "It's part of a downloaded album; removing it here takes it off this phone.")
        await model.removeSongDownload("s1")
        #expect(Set(model.downloads!.localFiles.keys) == ["s2"])
        #expect(model.downloadStatus(["s1"]) == .none)
        let header = model.downloadStatus(["s1", "s2"], reason: .album("a1"))
        #expect(header == .partial(done: 1, total: 2))
        #expect(header.text == "1 of 2 downloaded" && header.symbol == "arrow.down.circle")
        #expect(model.alreadyOnPhoneNote(["s1", "s2"], reason: .album("a1")) == nil, "s2 is the album's own")
        await model.removeDownload(.album("a1"))
        #expect(model.downloads!.localFiles.isEmpty)
        #expect(model.downloadStatus(["s1", "s2"]) == .none)
    }

    @Test func removeAllAndClearCache() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1")], reason: .song)
        // c1 is pre-downloaded as the next song (the plan is the queue's, so it can't be asked for on its own).
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("p1"), song("c1")], startAt: 0)
        #expect(await eventually { await model.downloads!.store.entry(songId: "c1") != nil })
        await model.downloads!.settled()
        var usage = await model.storageUsage
        #expect(usage == AudioUsage(downloadBytes: 1000, cacheBytes: 1000))
        model.updatePreferences { $0.downloads.keepFavourites = true }
        await model.removeAllDownloads()
        #expect(!model.preferences.downloads.keepFavourites, "or the favourites would come straight back")
        usage = await model.storageUsage
        #expect(usage == AudioUsage(downloadBytes: 0, cacheBytes: 1000))
        #expect(Set(model.downloads!.localFiles.keys) == ["c1"])
        await model.clearCache()
        usage = await model.storageUsage
        #expect(usage == AudioUsage(downloadBytes: 0, cacheBytes: 0))
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func keepFavouritesPreferenceDownloadsThem() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.transport(stub: "/rest/getStarred2", #""starred2":{"song":[{"id":"s7","title":"Seven"}]}"#)
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.keepFavourites = true }
        #expect(await eventually { model.downloads!.localFiles.keys.contains("s7") })
        model.updatePreferences { $0.downloads.keepFavourites = false }
        #expect(await eventually { model.downloads!.localFiles.isEmpty })
    }

    @Test func storageSummaryAndUsageText() {
        #expect(DownloadsSettingsView.summary(.defaultValue) == "Original · 2 GB cache · 3 ahead")
        var prefs = DownloadPreferences.defaultValue
        prefs.cacheLimit = .mb500; prefs.preDownload = 0; prefs.quality = .aac256
        #expect(DownloadsSettingsView.summary(prefs) == "AAC 256 kbps · 500 MB cache · none ahead")
        prefs.quality = .mp3_320
        #expect(DownloadsSettingsView.summary(prefs).hasPrefix("MP3 320 kbps · "))
        let text = DownloadsSettingsView.usageText(AudioUsage(downloadBytes: 1_200_000_000, cacheBytes: 340_000_000))
        #expect(text == "Downloads 1.2 GB · Cache 340 MB")
    }

    @Test func notSignedInHasNoDownloads() async {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: HostSwitchTransport(),
                             probeTransport: HostSwitchTransport(), engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        #expect(model.downloads == nil)
        #expect(model.downloadStatus(["s1"]) == .none)
        #expect(await model.storageUsage == AudioUsage(downloadBytes: 0, cacheBytes: 0))
    }

    // MARK: - Fix round 1

    @Test func albumAndFavouritesOverlap() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .favourites); await model.downloads!.settled()
        let album = ["s1", "s2"]
        #expect(model.downloadStatus(album, reason: .album("a1")) == .none)
        #expect(model.alreadyOnPhoneNote(album, reason: .album("a1")) == "1 of 2 songs are already on this phone")
        model.download([song("s1"), song("s2")], reason: .album("a1")); await model.downloads!.settled()
        #expect(model.downloadStatus(album, reason: .album("a1")) == .downloaded)
        #expect(model.alreadyOnPhoneNote(album, reason: .album("a1")) == nil)
        await model.removeDownload(.album("a1"))
        #expect(model.downloadStatus(album, reason: .album("a1")) == .none, "the header's remove is never a no-op")
        #expect(Set(model.downloads!.localFiles.keys) == ["s1"], "the favourite stays")
        model.updatePreferences { $0.downloads.keepFavourites = true }
        #expect(model.songRemovalNote("s1") == "It's a favourite, so it'll come back while Keep favourites downloaded is on.")
    }

    @Test func headerReadsCancelWhileDownloading() {
        #expect(DownloadButton.removeTitle(.downloading(done: 1, total: 3)) == "Cancel download")
        #expect(DownloadButton.removeTitle(.waitingForWiFi) == "Cancel download")
        #expect(DownloadButton.removeTitle(.downloaded) == "Remove download")
        #expect(DownloadButton.removeTitle(.full) == "Remove download")
    }

    @Test func starringSyncsFavouritesAfterAPause() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.favouritesDebounce = .milliseconds(50)
        let starred = Mutex("[]")
        let transport = try #require(model.transport as? HostSwitchTransport)
        transport.inner.stub(pathSuffix: "/rest/getStarred2") { _ in
            let songs = starred.withLock { $0 }
            let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","starred2":{"song":"# + songs + "}}}"
            return MockTransport.Response(status: 200, body: Data(body.utf8))
        }
        transport.inner.stub(pathSuffix: "/rest/star", body: ok)
        transport.inner.stub(pathSuffix: "/rest/unstar", body: ok)
        model.updatePreferences { $0.downloads.keepFavourites = true }
        await model.favouritesSync?.value; await model.downloads!.settled()
        #expect(model.downloads!.localFiles.isEmpty)
        starred.withLock { $0 = #"[{"id":"s7","title":"Seven"}]"# }
        await model.toggleStar(song("s7"))
        #expect(await eventually { model.downloads!.localFiles.keys.contains("s7") })
        starred.withLock { $0 = "[]" }
        await model.toggleStar(song("s7"))
        #expect(await eventually { model.downloads!.localFiles.isEmpty })
    }

    @Test func signInSweepsOtherScopesOnly() async throws {
        let fm = FileManager.default
        let audio = tmp.appending(path: "Magpie/Audio")
        let stale = audio.appending(path: "0123456789abcdef01234567")
        let oddName = audio.appending(path: "not a scope")
        let outside = tmp.appending(path: "outside")
        for dir in [stale, oddName, outside] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: stale.appending(path: "a.mp3"))
        try Data("keep".utf8).write(to: outside.appending(path: "keep.txt"))
        try fm.createSymbolicLink(at: audio.appending(path: "linkscope"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: stale.appending(path: "inner"), withDestinationURL: outside)

        let model = try await signedInModel(fetcher: FakeFetcher())
        await model.downloads!.settled()
        #expect(!fm.fileExists(atPath: stale.path), "an earlier account's audio is gone")
        #expect(fm.fileExists(atPath: oddName.path), "only scope-shaped names are touched")
        #expect((try? fm.destinationOfSymbolicLink(atPath: audio.appending(path: "linkscope").path)) != nil, "links are left")
        #expect(fm.fileExists(atPath: outside.appending(path: "keep.txt").path), "nothing behind a link is removed")
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        #expect(fm.fileExists(atPath: model.downloads!.storeDirectory.path), "the signed-in scope stays")
    }

    @Test func protectedDataSnapshotFollowsNotifications() {
        let center = NotificationCenter()
        let snapshot = ProtectedDataSnapshot(notifications: center, initial: false)
        let read = snapshot.isAvailable
        #expect(read() == false)
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(read() == true)
        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        #expect(read() == false)
    }

    @Test func onlyDownloadSettingsThatCanUnblockRetry() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        f.failWith(URLError(.timedOut))
        model.download([song("s1")], reason: .song)
        // The server answers each probe, so each time-out is an attempt; the third is "Couldn't download" (T14).
        #expect(await eventually { model.downloadStatus(["s1"]) == .failed })
        #expect(model.downloadStatus(["s1"]).text == "Couldn't download")
        f.failWith(nil)
        model.updatePreferences { $0.downloads.keepRecentlyPlayed = false }
        await model.downloads!.settled()
        #expect(model.downloadStatus(["s1"]) == .failed, "a cache setting doesn't retry")
        model.updatePreferences { $0.downloads.concurrent = 3 }
        await model.downloads!.settled()
        #expect(model.downloadStatus(["s1"]) == .downloaded)
    }

    @Test func downloadFormatCopy() {
        #expect(DownloadsSettingsView.originalTitle == "Original file (no conversion)")
        #expect(DownloadsSettingsView.formatFooter
            == "Original saves each song exactly as it is on your server. The other choices convert it on your server first, which uses less space.")
        #expect(StreamQualityOptions(originalTitle: DownloadsSettingsView.originalTitle).originalTitle == "Original file (no conversion)")
        #expect(StreamQualityOptions().originalTitle == "Original", "Playback's pickers are unchanged")
    }

    // MARK: - Fix round 2: partly downloaded

    @Test func albumPartlyDownloadedOffersTheRest() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1"), song("s2"), song("s3")], reason: .album("a1"))
        model.download([song("s1")], reason: .song)
        model.download([song("s9")], reason: .favourites); await model.downloads!.settled()
        #expect(model.songRemovalNote("s1") == "It's also part of a downloaded album; removing it here takes it off this phone.")
        await model.removeSongDownload("s1")
        let ids = ["s1", "s2", "s3", "s9"]   // s9: on the phone as a favourite only
        #expect(model.downloadStatus(ids, reason: .album("a1")) == .partial(done: 2, total: 4))
        #expect(model.alreadyOnPhoneNote(ids, reason: .album("a1")) == "1 of 4 songs are already on this phone",
                "only the favourite counts, not the album's own songs")
        model.download([song("s1"), song("s2"), song("s3"), song("s9")], reason: .album("a1"))   // Download the rest
        await model.downloads!.settled()
        #expect(model.downloadStatus(ids, reason: .album("a1")) == .downloaded)
        #expect(model.alreadyOnPhoneNote(ids, reason: .album("a1")) == nil)
    }

    @Test func playlistPartlyDownloaded() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1"), song("s2")], reason: .playlist("p1"),
                       playlist: DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: nil, songIds: ["s1", "s2"], savedAt: .now))
        await model.downloads!.settled()
        #expect(model.songRemovalNote("s2") == "It's part of a downloaded playlist; removing it here takes it off this phone.")
        await model.removeSongDownload("s2")
        #expect(model.downloadStatus(["s1", "s2"], reason: .playlist("p1")) == .partial(done: 1, total: 2))
        await model.removeDownload(.playlist("p1"))
        #expect(model.downloadStatus(["s1", "s2"], reason: .playlist("p1")) == .none)
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func songOnItsWayCanBeCancelled() async throws {
        let f = FakeFetcher(); f.hold(after: 0)
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1")], reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        #expect(model.downloadStatus(["s1"]) == .downloading(done: 0, total: 1), "the menu reads Cancel download")
        await model.removeSongDownload("s1")
        f.release(); await model.downloads!.settled()
        #expect(model.downloadStatus(["s1"]) == .none)
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func sweepLeavesSymlinkedFoldersAlone() throws {
        let fm = FileManager.default
        let outside = tmp.appending(path: "outside")
        let stale = outside.appending(path: "Audio/0123456789abcdef01234567")
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        // Magpie itself a link
        let rootA = tmp.appending(path: "rootA")
        try fm.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: rootA.appending(path: "Magpie"), withDestinationURL: outside)
        AppModel.sweepAudioScopes(root: rootA, keeping: "abc")
        #expect(fm.fileExists(atPath: stale.path))
        // Audio a link
        let rootB = tmp.appending(path: "rootB")
        try fm.createDirectory(at: rootB.appending(path: "Magpie"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: rootB.appending(path: "Magpie/Audio"), withDestinationURL: outside.appending(path: "Audio"))
        AppModel.sweepAudioScopes(root: rootB, keeping: "abc")
        #expect(fm.fileExists(atPath: stale.path), "nothing behind a linked Magpie or Audio is deleted")
    }
}
