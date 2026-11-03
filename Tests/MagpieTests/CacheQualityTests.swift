import Foundation
import MagpieCore
import Playback
import Testing
@testable import Magpie

private let cell = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)

/// Round 13 item 7: a song played from the cache at a quality other than the current network's target is fetched
/// again at the target in the background and swapped in on its next play, never mid-song. Downloads keep their
/// quality; nothing is fetched on mobile data when mobile downloads are off; one replacement at a time; the old file
/// goes only once the new one is verified and stored.
@MainActor @Suite(.serialized) final class CacheQualityTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "CacheQualityTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    func makeManager(_ prefs: DownloadPreferences = .defaultValue, network: NetworkStatus = .wifi,
                     offline: Bool = false) async -> (DownloadManager, FakeFetcher, FakeNetwork) {
        let fetcher = FakeFetcher(directory: tmp.appending(path: "fetched"))
        let net = FakeNetwork(network)
        let store = AudioStore(root: tmp, scope: "abc")
        let manager = DownloadManager(
            store: store, fetcher: fetcher, network: net, preferences: { prefs },
            url: { song, q in
                URL(string: "http://192.168.1.2:4533/rest/stream?id=\(song.id)&format=\(q.format)"
                    + (q.maxBitRate.map { "&maxBitRate=\($0)" } ?? ""))!
            },
            coverURL: { URL(string: "http://192.168.1.2:4533/rest/getCoverArt?id=\($0)&size=600")! },
            isOffline: { offline }, notifications: NotificationCenter())
        manager.loadPlayableForCheck = { _ in true }
        await manager.start()
        return (manager, fetcher, net)
    }

    func songs(_ ids: String...) -> [Song] {
        ids.map { Song(id: $0, title: "T\($0)", artist: "A", album: "Album", albumId: "a1", duration: 200, suffix: "flac") }
    }

    /// Caches `ids` at `quality` (a pre-download) and forgets the fetches it took.
    func cache(_ m: DownloadManager, _ ids: String..., quality: StreamQuality = .opusMedium) async {
        m.preDownload(ids.flatMap { songs($0) }, quality: quality)
        await m.settled()
        for id in ids { #expect(await m.store.entry(songId: id)?.quality == quality) }
    }

    func fetches(_ f: FakeFetcher) -> [URL] { f.urls.filter { $0.path.hasSuffix("/rest/stream") } }

    @Test func mismatchFetchesAndReplacesTheCachedCopy() async throws {
        let (m, f, _) = await makeManager()
        await cache(m, "s1")
        let old = try #require(m.localFiles["s1"])
        let before = fetches(f).count
        m.refreshCacheQuality(songId: "s1", target: .original)
        await m.settled()
        #expect(fetches(f).count == before + 1)
        #expect(fetches(f).last?.query?.contains("format=raw") == true)
        let entry = try #require(await m.store.entry(songId: "s1"))
        #expect(entry.kind == .cache && entry.quality == .original)
        #expect(m.localQualities["s1"] == .original)
        #expect(m.localFiles["s1"] != old)
        #expect(!FileManager.default.fileExists(atPath: old.path), "the old copy goes once the new one is stored")
    }

    @Test func matchFetchesNothing() async {
        let (m, f, _) = await makeManager()
        await cache(m, "s1")
        let before = f.urls.count
        m.refreshCacheQuality(songId: "s1", target: .opusMedium)
        await m.settled()
        #expect(f.urls.count == before)
        #expect(m.cacheRefreshSongId == nil && m.pendingCacheSwapSongId == nil)
    }

    @Test func aDownloadIsNeverReplaced() async {
        var prefs = DownloadPreferences.defaultValue; prefs.quality = .opusMedium
        let (m, f, _) = await makeManager(prefs)
        m.download(songs("s1"), reason: .song)
        await m.settled()
        #expect(await m.store.entry(songId: "s1")?.kind == .download)
        let before = f.urls.count
        m.refreshCacheQuality(songId: "s1", target: .original)
        await m.settled()
        #expect(f.urls.count == before)
        #expect(await m.store.entry(songId: "s1")?.quality == .opusMedium)
    }

    /// Saved on purpose while its replacement was fetching: the download keeps its file.
    @Test func aCachedSongDownloadedMeanwhileIsKept() async throws {
        let (m, f, _) = await makeManager()
        await cache(m, "s1")
        f.hold(after: fetches(f).count)
        m.refreshCacheQuality(songId: "s1", target: .original)
        #expect(await eventually { f.inFlight == 1 })
        try await m.store.promote(songId: "s1", reason: .song, downloadsLimit: nil)
        f.release()
        await m.settled()
        let entry = try #require(await m.store.entry(songId: "s1"))
        #expect(entry.kind == .download && entry.quality == .opusMedium)
    }

    @Test func mobileDataOffFetchesNothingOnCellular() async {
        var prefs = DownloadPreferences.defaultValue; prefs.overMobileData = false
        let (m, f, net) = await makeManager(prefs)
        await cache(m, "s1")
        net.status = cell
        let before = f.urls.count
        m.refreshCacheQuality(songId: "s1", target: .original)
        await m.settled()
        #expect(f.urls.count == before)
        #expect(await m.store.entry(songId: "s1")?.quality == .opusMedium)
    }

    @Test func mobileDataOnFetchesOnCellular() async {
        var prefs = DownloadPreferences.defaultValue; prefs.overMobileData = true
        let (m, _, net) = await makeManager(prefs)
        await cache(m, "s1")
        net.status = cell
        m.refreshCacheQuality(songId: "s1", target: .aacHigh)
        await m.settled()
        #expect(await m.store.entry(songId: "s1")?.quality == .aacHigh)
    }

    @Test func offlineFetchesNothing() async {
        let (m, f, _) = await makeManager(offline: true)
        let store = m.store
        _ = try? await store.add({ () -> URL in
            let url = tmp.appending(path: "seed.tmp")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try? Data(count: 100).write(to: url)
            return url
        }(), metadata: AudioMetadata(songs("s1")[0]), quality: .opusMedium, kind: .cache, reason: nil,
             fileExtension: "ogg", downloadsLimit: nil)
        await m.refresh()
        m.refreshCacheQuality(songId: "s1", target: .original)
        await m.settled()
        #expect(f.urls.isEmpty)
    }

    /// The network turns to mobile data (mobile downloads off) while the replacement fetches: it stops, and the
    /// cached copy stays as it was.
    @Test func networkChangeToCellularStopsTheFetch() async {
        var prefs = DownloadPreferences.defaultValue; prefs.overMobileData = false
        let (m, f, net) = await makeManager(prefs)
        await cache(m, "s1")
        f.hold(after: fetches(f).count)
        m.refreshCacheQuality(songId: "s1", target: .original)
        #expect(await eventually { f.inFlight == 1 })
        net.status = cell
        m.networkChanged()
        await m.settled()
        f.release()
        #expect(await m.store.entry(songId: "s1")?.quality == .opusMedium)
        #expect(m.cacheRefreshSongId == nil)
    }

    /// The target changes (Wi-Fi to mobile quality) while the replacement fetches: it stops; the copy already at the
    /// new target needs nothing.
    @Test func targetChangeStopsAFetchForTheOldTarget() async {
        let (m, f, _) = await makeManager()
        await cache(m, "s1")
        f.hold(after: fetches(f).count)
        m.refreshCacheQuality(songId: "s1", target: .original)
        #expect(await eventually { f.inFlight == 1 })
        m.cacheTargetChanged(.opusMedium)
        await m.settled()
        f.release()
        #expect(await m.store.entry(songId: "s1")?.quality == .opusMedium)
        #expect(m.cacheRefreshSongId == nil && m.pendingCacheSwapSongId == nil)
    }

    /// Never mid-song: while the song plays (or waits in the engine) the new copy is held, and swapped in after.
    @Test func swapWaitsUntilTheSongIsNoLongerPlaying() async throws {
        let (m, _, _) = await makeManager()
        await cache(m, "s1")
        var playing: Set<String> = ["s1"]
        m.isSongInUse = { playing.contains($0) }
        let old = try #require(m.localFiles["s1"])
        m.refreshCacheQuality(songId: "s1", target: .original)
        await m.settled()
        #expect(m.pendingCacheSwapSongId == "s1")
        #expect(await m.store.entry(songId: "s1")?.quality == .opusMedium)
        #expect(m.localFiles["s1"] == old && FileManager.default.fileExists(atPath: old.path))
        m.applyCacheSwap(target: .original)   // still playing: nothing yet
        await m.settled()
        #expect(await m.store.entry(songId: "s1")?.quality == .opusMedium)
        playing = []
        m.applyCacheSwap(target: .original)
        await m.settled()
        #expect(await m.store.entry(songId: "s1")?.quality == .original)
        #expect(m.pendingCacheSwapSongId == nil)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    /// A held copy for a target that is no longer current is dropped, not swapped in.
    @Test func aHeldCopyForAnOldTargetIsDropped() async {
        let (m, _, _) = await makeManager()
        await cache(m, "s1")
        m.isSongInUse = { _ in true }
        m.refreshCacheQuality(songId: "s1", target: .original)
        await m.settled()
        #expect(m.pendingCacheSwapSongId == "s1")
        m.isSongInUse = { _ in false }
        m.applyCacheSwap(target: .opusMedium)
        await m.settled()
        #expect(m.pendingCacheSwapSongId == nil)
        #expect(await m.store.entry(songId: "s1")?.quality == .opusMedium)
    }

    @Test func oneReplacementAtATime() async {
        let (m, f, _) = await makeManager()
        await cache(m, "s1", "s2")
        let before = fetches(f).count
        f.hold(after: before)
        m.refreshCacheQuality(songId: "s1", target: .original)
        #expect(await eventually { f.inFlight == 1 })
        m.refreshCacheQuality(songId: "s2", target: .original)
        for _ in 0..<20 { await Task.yield() }
        #expect(fetches(f).count == before + 1)
        #expect(m.cacheRefreshSongId == "s1")
        f.release()
        await m.settled()
        #expect(f.maxInFlight == 1 || fetches(f).count == before + 1)
        #expect(await m.store.entry(songId: "s1")?.quality == .original)
        #expect(await m.store.entry(songId: "s2")?.quality == .opusMedium, "s2 waits for its own next play")
        // Once the first is done, the next play of s2 fetches it.
        m.refreshCacheQuality(songId: "s2", target: .original)
        await m.settled()
        #expect(await m.store.entry(songId: "s2")?.quality == .original)
    }

    /// The old copy stays unless the new one is verified: a file AVFoundation can't play, or a body that isn't audio.
    @Test func anUnverifiedCopyNeverReplacesTheOldOne() async throws {
        let (m, f, _) = await makeManager()
        await cache(m, "s1", "s2")
        m.loadPlayableForCheck = { _ in false }
        m.refreshCacheQuality(songId: "s1", target: .original)
        await m.settled()
        #expect(await m.store.entry(songId: "s1")?.quality == .opusMedium)
        let file = try #require(m.localFiles["s1"])
        #expect(FileManager.default.fileExists(atPath: file.path))

        m.loadPlayableForCheck = { _ in true }
        f.mimeType { $0.path.hasSuffix("/rest/stream") ? "application/json" : "image/jpeg" }
        m.refreshCacheQuality(songId: "s2", target: .original)
        await m.settled()
        #expect(await m.store.entry(songId: "s2")?.quality == .opusMedium)
        #expect(m.cacheRefreshSongId == nil && m.pendingCacheSwapSongId == nil)
    }

    /// A failure isn't tried again for the same song and target this session (no loop on a song the server can't
    /// convert).
    @Test func aFailedReplacementIsNotRetriedThisSession() async {
        let (m, f, _) = await makeManager()
        await cache(m, "s1")
        f.failWith(URLError(.badServerResponse))
        m.refreshCacheQuality(songId: "s1", target: .original)
        await m.settled()
        let after = fetches(f).count
        f.failWith(nil)
        m.refreshCacheQuality(songId: "s1", target: .original)
        await m.settled()
        #expect(fetches(f).count == after)
    }

    @Test func clearCacheDropsAHeldCopy() async {
        let (m, _, _) = await makeManager()
        await cache(m, "s1")
        m.isSongInUse = { _ in true }
        m.refreshCacheQuality(songId: "s1", target: .original)
        await m.settled()
        #expect(m.pendingCacheSwapSongId == "s1")
        await m.clearCache()
        #expect(m.pendingCacheSwapSongId == nil)
        #expect(await m.store.entry(songId: "s1") == nil)
    }
}
