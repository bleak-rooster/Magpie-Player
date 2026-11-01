import AVFoundation
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Synchronization
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

/// Task 13: songs on the phone play from the phone, upcoming songs are pre-downloaded, and the cache is kept tidy.
@MainActor @Suite(.serialized) final class LocalPlaybackTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "LocalPlaybackTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "LocalPlaybackTests.\(UUID().uuidString)")!
    let engine = FakeEngine()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedInModel(fetcher: any AudioFetching, network: NetworkStatus = .wifi,
                       engine: (any PlaybackEngine)? = nil) async throws -> AppModel {
        let transport = HostSwitchTransport()
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: engine ?? self.engine, defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(network),
                             audioFetcher: fetcher)
        model.cacheEvictionDebounce = .milliseconds(10)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        return model
    }

    func song(_ id: String) -> Song { PlayerTests.song(id) }

    /// Waits until the pre-download watcher has acted on the queue as it is now, and its cache upkeep has run.
    func upkeepSettled(_ model: AppModel) async {
        #expect(await eventually { model.preDownloadSnapshot?.current?.id == model.player.queue.current?.id })
        await model.cacheUpkeep?.value
    }

    /// The song ids the fetcher was asked for, in order.
    func fetchedIds(_ f: FakeFetcher) -> [String] {
        f.urls.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value }
    }

    // MARK: - The brief's tests

    @Test func localFileUsedWhenPresent() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 0 }
        model.download([song("s2")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2")], startAt: 0)
        let items = engine.setItemsCalls.last!.items
        #expect(!items[0].1.isFileURL && items[1].1.isFileURL)
        #expect(items[1].1 == model.downloads!.localFiles["s2"])
    }

    @Test func completedPreDownloadSwapsOnlyUpcoming() async throws {
        let f = FakeFetcher(); f.hold(after: 0)
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s1"), song("s2")], startAt: 0)
        let first = engine.setItemsCalls.last!.items
        #expect(!first[1].1.isFileURL)
        #expect(await eventually { f.inFlight == 1 })
        f.release(); await model.downloads!.settled()
        #expect(await eventually { self.engine.setItemsCalls.last!.items[1].1.isFileURL })
        #expect(engine.setItemsCalls.last!.items[0].1 == first[0].1 && engine.seeks.isEmpty)
    }

    @Test func preDownloadsAheadByN() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 2 }
        model.play((1...5).map { song("s\($0)") }, startAt: 0)
        #expect(await eventually { f.urls.count >= 2 })
        await model.downloads!.settled()
        #expect(fetchedIds(f) == ["s2", "s3"])
        #expect(f.urls.allSatisfy { $0.query?.contains("format=raw") == true }, "Wi-Fi quality")
        #expect(await model.downloads!.store.entry(songId: "s2")?.kind == .cache)
    }

    @Test func cacheRemovedAfterPlayWhenKeepOff() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 1; $0.downloads.keepRecentlyPlayed = false }
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") != nil })
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // now on s2
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // now on s3
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") == nil })
        #expect(await eventually { model.downloads!.localFiles["s2"] == nil }, "the mirror follows")
    }

    @Test func currentNeverEvicted() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.cacheLimitOverride = 1
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s0"), song("s1")], startAt: 0)
        #expect(await eventually { await model.downloads!.store.entry(songId: "s1") != nil })
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // s1 (cached) is current
        await upkeepSettled(model)
        #expect(await model.downloads!.store.entry(songId: "s1") != nil)
    }

    // MARK: - Beyond the brief

    /// Keep recently played (the default): a played pre-download stays, and is evicted, least recently played first,
    /// only once the cache is over its limit.
    @Test func playedCacheKeptAndEvictedOverLimit() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s1"), song("s2"), song("s3"), song("s4")], startAt: 0)
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") != nil })
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // s2
        #expect(await eventually { await model.downloads!.store.entry(songId: "s3") != nil })
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // s3
        #expect(await eventually { await model.downloads!.store.entry(songId: "s4") != nil })
        #expect(await model.downloads!.store.entry(songId: "s2") != nil, "kept while under the limit")
        model.cacheLimitOverride = 2000   // two 1000-byte songs
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // s4: s2 played longest ago goes
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") == nil })
        #expect(await model.downloads!.store.entry(songId: "s3") != nil)
        #expect(await model.downloads!.store.entry(songId: "s4") != nil)
    }

    /// Downloads are never removed by cache upkeep, keep recently played or not.
    @Test func downloadsSurviveCacheUpkeep() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.cacheLimitOverride = 1
        model.updatePreferences { $0.downloads.preDownload = 0; $0.downloads.keepRecentlyPlayed = false }
        model.download([song("s1"), song("s2")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))
        await upkeepSettled(model)
        #expect(await model.downloads!.store.entry(songId: "s1")?.kind == .download)
        #expect(await model.downloads!.store.entry(songId: "s2")?.kind == .download)
    }

    /// ReplayGain (T9) levels a song played from the phone just as when streamed.
    @Test func replayGainAppliesToLocalSongs() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 0 }
        var loud = song("s1")
        loud.replayGain = ReplayGain(trackGain: -6)
        model.download([loud], reason: .song); await model.downloads!.settled()
        model.play([loud], startAt: 0)
        let item = try #require(engine.setItemsCalls.last?.items.first)
        #expect(item.1.isFileURL)
        let volume = try #require(engine.setVolumesCalls.last?[item.0])
        #expect(abs(volume - 0.501) < 0.01)
    }

    /// Engine window (QC): K is the pre-download count when that is more than 3, up to 10.
    @Test func engineWindowFollowsPreDownload() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 0 }
        #expect(model.player.lookahead == 3)
        model.updatePreferences { $0.downloads.preDownload = 6 }
        #expect(model.player.lookahead == 6)
        model.updatePreferences { $0.downloads.preDownload = 10 }
        model.play((1...20).map { song("s\($0)") }, startAt: 0)
        #expect(engine.setItemsCalls.last!.items.count == 11)
    }

    /// A downloaded song plays from its file (no network needed); a failure there has no server original to fall back to.
    @Test func localFileFailureHasNoServerFallback() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 0 }
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let file = try #require(model.downloads!.localFiles["s1"])
        model.play([song("s1")], startAt: 0)
        #expect(engine.setItemsCalls.last!.items[0].1 == file)
        model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))
        #expect(model.player.lastFallbackSongId == nil, "no server fallback for a local file")
    }

    /// T7/T8 contract: the Navidrome original check reads the stream's format and cap, not its auth.
    @Test func navidromeOriginalCheckIgnoresAuth() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let box = ClientBox()
        box.set(model.session?.client)
        let urls = NavidromeStreamURLs(box: box, quality: QualityBox(.aacMedium))
        let original = try #require(urls.originalURL(for: song("s1")))
        #expect(urls.isOriginal(original))
        #expect(!urls.isOriginal(urls.streamURL(for: song("s1"))), "a transcode")
        var resigned = try #require(URLComponents(url: original, resolvingAgainstBaseURL: false))
        resigned.queryItems = resigned.queryItems?.map { $0.name == "s" || $0.name == "t" ? URLQueryItem(name: $0.name, value: "new") : $0 }
        #expect(urls.isOriginal(try #require(resigned.url)), "signed again after a re-login")
        #expect(!urls.isOriginal(URL(filePath: "/tmp/song.mp3")))
    }

    // MARK: - Fix round 1

    /// I1: an upkeep that waited its turn spares the song that became current meanwhile (a new queue started).
    @Test func upkeepSparesWhatBecameCurrentMeanwhile() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.cacheLimitOverride = 1
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("a"), song("b")], startAt: 0)
        #expect(await eventually { await model.downloads!.store.entry(songId: "b") != nil })
        await upkeepSettled(model)
        let gate = Gate()
        model.beforeCacheUpkeepForTesting = { while gate.held { try? await Task.sleep(for: .milliseconds(5)) } }
        model.player.remove(id: model.player.queue.upcoming[0].id)   // b leaves the queue: its upkeep would evict it
        #expect(await eventually { model.preDownloadSnapshot?.upcoming.isEmpty == true })
        model.play([song("b")], startAt: 0)                          // ...but b is current again before it runs
        #expect(engine.setItemsCalls.last!.items[0].1.isFileURL)
        await upkeepSettledHeld(model, gate)
        #expect(await model.downloads!.store.entry(songId: "b") != nil)
    }

    /// Releases `gate` once the watcher has seen the queue as it is now, then waits for the upkeeps.
    func upkeepSettledHeld(_ model: AppModel, _ gate: Gate) async {
        #expect(await eventually { model.preDownloadSnapshot?.current?.id == model.player.queue.current?.id })
        gate.held = false
        await model.cacheUpkeep?.value
    }

    /// Ruling (a): a download that fails to decode, online, streams instead; its file fails the check again, so it is
    /// dropped and downloaded again (FakeFetcher's files are zeros, not audio).
    /// One retry: a failure of the stream is final.
    @Test func corruptDownloadStreamsAndIsFetchedAgain() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 0 }
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let file = try #require(model.downloads!.localFiles["s1"])
        model.play([song("s1")], startAt: 0)
        #expect(engine.setItemsCalls.last!.items[0].1 == file)
        let id = model.player.queue.current!.id
        model.player.handle(.failed(id, "cannot decode", undecodable: true))
        let now = engine.setItemsCalls.last!.items[0].1
        #expect(!now.isFileURL && now.query?.contains("id=s1") == true)
        #expect(model.player.isPlaying && model.player.lastError == nil && model.player.lastFallbackSongId == nil)
        #expect(await eventually { self.fetchedIds(f).filter { $0 == "s1" }.count == 2 }, "downloaded again")
        await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s1")?.reasons == [.song])
        #expect(await eventually { model.localFiles.url(for: "s1") != nil }, "the fresh file counts")
        model.player.handle(.failed(id, "still broken"))
        #expect(model.player.lastError == "still broken" && !model.player.isPlaying)
    }

    /// Ruling (a): a damaged cached song, online, streams instead; it is dropped and not fetched again.
    @Test func corruptCacheStreamsAndIsNotFetchedAgain() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s1"), song("s2")], startAt: 0)
        #expect(await eventually { self.engine.setItemsCalls.last!.items.count == 2
            && self.engine.setItemsCalls.last!.items[1].1.isFileURL })
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // s2 plays from its cached file
        model.player.handle(.failed(model.player.queue.current!.id, "cannot decode", undecodable: true))
        #expect(!engine.setItemsCalls.last!.items[0].1.isFileURL && model.player.isPlaying)
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") == nil })
        await model.downloads!.settled()
        await upkeepSettled(model)
        #expect(fetchedIds(f) == ["s2"])
    }

    /// Ruling (b): a pre-download that lands puts the cache over its limit; eviction runs then, not only on the next
    /// song change.
    @Test func landedPreDownloadEvictsOverLimit() async throws {
        let f = FakeFetcher(); f.hold(after: 1)
        let model = try await signedInModel(fetcher: f)
        model.cacheLimitOverride = 1500
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("w"), song("x")], startAt: 0)
        #expect(await eventually { await model.downloads!.store.entry(songId: "x") != nil })
        model.play([song("y"), song("z")], startAt: 0)
        #expect(await eventually { f.inFlight == 1 })
        await upkeepSettled(model)
        #expect(await model.downloads!.store.entry(songId: "x") != nil, "under the limit so far")
        f.release()
        #expect(await eventually { await model.downloads!.store.entry(songId: "x") == nil })
        #expect(await model.downloads!.store.entry(songId: "z") != nil)
    }

    /// Minor 2: a new plan drops the pre-downloads still queued for songs no longer in it.
    @Test func newPlanDropsQueuedPreDownloads() async throws {
        let f = FakeFetcher(); f.hold(after: 0)
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 3; $0.downloads.concurrent = 1 }
        model.play((1...5).map { song("s\($0)") }, startAt: 0)
        #expect(await eventually { f.inFlight == 1 })
        model.download([song("m1")], reason: .song)                 // a manual download queued beside them
        model.play([song("t1"), song("t2")], startAt: 0)
        #expect(await eventually { model.preDownloadSnapshot?.current?.song.id == "t1" })
        f.release(); await model.downloads!.settled()
        #expect(fetchedIds(f) == ["s2", "m1", "t2"], "the manual download survives the new plan")
        #expect(await model.downloads!.store.entry(songId: "m1")?.kind == .download)
    }

    /// Minor 4: on mobile data pre-downloads still run, at the mobile quality.
    @Test func preDownloadRunsOnCellularAtMobileQuality() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f, network: NetworkStatus(isConnected: true, isCellular: true,
                                                                                isConstrained: false))
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s1"), song("s2")], startAt: 0)
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") != nil })
        let url = try #require(f.urls.first)
        #expect(url.query?.contains("format=aac") == true && url.query?.contains("maxBitRate=160") == true)
        #expect(await model.downloads!.store.entry(songId: "s2")?.quality == .aacMedium)
    }

    /// Minor 4: a pre-download the store refused (`invalidFile`) isn't tried again when the queue changes.
    @Test func invalidPreDownloadNotRetriedAcrossSnapshots() async throws {
        let f = FakeFetcher(); f.bytes = 0   // an empty file: the store refuses it
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)
        #expect(await eventually { f.urls.count == 1 })
        await model.downloads!.settled()
        model.player.addToEnd([song("s9")])
        #expect(await eventually { model.preDownloadSnapshot?.upcoming.contains { $0.song.id == "s9" } == true })
        await model.downloads!.settled()
        #expect(fetchedIds(f) == ["s2"])
        #expect(await model.downloads!.store.entry(songId: "s2") == nil)
    }

    /// T8b on the phone: a downloaded Ogg Opus file plays from the phone through the real engine.
    @Test func storedOggOpusPlaysLocallyThroughTheEngine() async throws {
        let avEngine = AVQueueEngine()
        let model = try await signedInModel(fetcher: OggFetcher(), engine: avEngine)
        model.updatePreferences { $0.downloads.preDownload = 0; $0.downloads.quality = .opusMedium }
        let opus = Song(id: "o1", title: "T", artist: "A", album: "B", duration: 1.5)
        model.download([opus], reason: .song); await model.downloads!.settled()
        let file = try #require(model.downloads!.localFiles["o1"])
        #expect(file.pathExtension == "ogg")
        model.play([opus], startAt: 0)
        #expect(avEngine.enqueuedItems.first?.url == file)
        #expect(await eventually(10) { avEngine.currentItemStatus == .readyToPlay }, "AVPlayer opens the stored .ogg")
        #expect(model.player.lastError == nil)
        model.player.toggle()
    }

    // MARK: - Fix round 2: which failures drop a file

    /// A failure that may pass (an interruption, a media-services reset) streams the song this session and keeps the file.
    @Test func transientFailureKeepsTheFile() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 0 }
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let file = try #require(model.downloads!.localFiles["s1"])
        model.play([song("s1")], startAt: 0)
        model.player.handle(.failed(model.player.queue.current!.id, "media services were reset"))
        #expect(!engine.setItemsCalls.last!.items[0].1.isFileURL && model.player.isPlaying)
        await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s1")?.kind == .download)
        #expect(FileManager.default.fileExists(atPath: file.path) && model.downloads!.localFiles["s1"] == file)
        #expect(model.localFiles.url(for: "s1") == nil, "streamed for the rest of the session")
        #expect(fetchedIds(f) == ["s1"])
    }

    /// A decode failure whose file opens fine when checked again keeps the file (the song streams this session).
    @Test func decodeFailureThatRevalidatesKeepsTheFile() async throws {
        let fetcher = OggFetcher()
        let model = try await signedInModel(fetcher: fetcher)
        model.updatePreferences { $0.downloads.preDownload = 0; $0.downloads.quality = .opusMedium }
        let opus = Song(id: "o1", title: "T", artist: "A", album: "B", duration: 1.5)
        model.download([opus], reason: .song); await model.downloads!.settled()
        let file = try #require(model.downloads!.localFiles["o1"])
        let stored = try Data(contentsOf: file)
        model.play([opus], startAt: 0)
        model.player.handle(.failed(model.player.queue.current!.id, "cannot decode", undecodable: true))
        #expect(!engine.setItemsCalls.last!.items[0].1.isFileURL)
        await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "o1") != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(fetcher.count == 1, "kept, not dropped and fetched again")
        #expect(try Data(contentsOf: file) == stored)
    }

    /// T13 review: a re-check whose load throws something that may pass (not a format or decode error) keeps the file.
    @Test func recheckLoadErrorThatMayPassKeepsTheFile() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 0 }
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let file = try #require(model.downloads!.localFiles["s1"])
        model.downloads!.loadPlayableForCheck = { _ in throw URLError(.timedOut) }
        model.play([song("s1")], startAt: 0)
        model.player.handle(.failed(model.player.queue.current!.id, "cannot decode", undecodable: true))
        await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s1")?.kind == .download)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(fetchedIds(f) == ["s1"], "kept, not fetched again")
        let decodeError = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue)
        #expect(await !DownloadManager.isPlayableFile(file, load: { _ in throw decodeError }), "a decode error still fails")
    }

    /// Offline a failed download is never dropped or marked: no stream, so the song is skipped and the file kept.
    @Test func offlineFailureNeverDropsADownload() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 0 }
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let file = try #require(model.downloads!.localFiles["s1"])
        (model.network as? FakeNetwork)?.status = NetworkStatus(isConnected: false, isCellular: false, isConstrained: false)
        model.play([song("s1")], startAt: 0)
        model.player.handle(.failed(model.player.queue.current!.id, "cannot decode", undecodable: true))
        #expect(model.player.lastError == "cannot decode" && !model.player.isPlaying)
        await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s1")?.kind == .download)
        #expect(model.localFiles.url(for: "s1") == file, "still the phone's copy")
        #expect(fetchedIds(f) == ["s1"])
    }

    /// Minor 1: a damaged song of a downloaded playlist is downloaded again for that playlist.
    @Test func reQueuedSongKeepsItsPlaylist() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 0 }
        let list = DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: nil, songIds: ["s1"], savedAt: .now)
        model.download([song("s1")], reason: .playlist("p1"), playlist: list); await model.downloads!.settled()
        model.play([song("s1")], startAt: 0)
        model.player.handle(.failed(model.player.queue.current!.id, "cannot decode", undecodable: true))
        #expect(await eventually { self.fetchedIds(f).filter { $0 == "s1" }.count == 2 })
        await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s1")?.reasons == [.playlist("p1")])
        #expect(model.downloadStatus(["s1"], reason: .playlist("p1")) == .downloaded)
    }
}

/// Holds cache upkeep while `held`.
@MainActor final class Gate {
    var held = true
}

/// Answers every fetch with the Ogg Opus fixture, as Navidrome's `format=opus` stream.
final class OggFetcher: AudioFetching, Sendable {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }

    func fetch(_ url: URL, allowsCellular: Bool) async throws -> (file: URL, mimeType: String?) {
        calls.withLock { $0 += 1 }
        let file = FileManager.default.temporaryDirectory.appending(path: "ogg-\(UUID().uuidString).tmp")
        try OggOpusFixture.data.write(to: file)
        return (file, "audio/ogg")
    }
}
