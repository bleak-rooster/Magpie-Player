import DesignSystem
import Foundation
import MagpieCore
import MagpieTestSupport
import Observation
import Playback
import Synchronization
import Testing
import UIKit
@testable import Magpie

private let cellular = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)

/// The download preferences a manager reads, changeable while it runs.
@MainActor @Observable private final class PrefsBox {
    var value: DownloadPreferences
    init(_ value: DownloadPreferences) { self.value = value }
}

/// P1: Downloaded marks, Downloading now, concurrency 1–6 applied live, foreground only, and Keep screen on.
@MainActor @Suite(.serialized) final class DownloadVisibilityTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "DownloadVisibilityTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    private func makeManager(_ prefs: DownloadPreferences = .defaultValue, network: NetworkStatus = .wifi)
        async -> (DownloadManager, FakeFetcher, PrefsBox) {
        let fetcher = FakeFetcher(directory: tmp.appending(path: "fetched"))
        let box = PrefsBox(prefs)
        let manager = DownloadManager(
            store: AudioStore(root: tmp, scope: "w1"), fetcher: fetcher, network: FakeNetwork(network),
            preferences: { box.value },
            url: { song, _ in URL(string: "http://192.168.1.2:4533/rest/stream?id=\(song.id)")! },
            coverURL: { URL(string: "http://192.168.1.2:4533/rest/getCoverArt?id=\($0)&size=600")! })
        await manager.start()
        return (manager, fetcher, box)
    }

    private func songs(_ ids: String..., album: String = "a1", artist: String = "ar1") -> [Song] {
        ids.map { Song(id: $0, title: "T\($0)", artist: "A", artistId: artist, album: "Album", albumId: album, duration: 200) }
    }

    private func prefs(concurrent: Int) -> DownloadPreferences {
        var p = DownloadPreferences.defaultValue
        p.concurrent = concurrent
        return p
    }

    // MARK: - Marks

    @Test func markCopyAndSymbols() {
        #expect(DownloadMark.downloaded.text == "Downloaded" && DownloadMark.downloaded.symbol == "arrow.down.circle.fill")
        #expect(DownloadMark.partial(done: 3, total: 12).text == "3 of 12 downloaded")
        #expect(DownloadMark.partial(done: 3, total: 12).symbol == "arrow.down.circle.dotted")
        #expect(DownloadMark.some.text == "Some downloaded" && DownloadMark.some.symbol == "arrow.down.circle.dotted")
        #expect(DownloadMark.none.text == nil && DownloadMark.none.symbol == nil)
        #expect(DownloadMark.counting(done: 0, total: 5) == .none)
        #expect(DownloadMark.counting(done: 2, total: 0) == .none)
        #expect(DownloadMark.counting(done: 5, total: 5) == .downloaded)
        #expect(DownloadMark.downloaded.joined(to: "Find, 5 days left") == "Find, 5 days left, Downloaded")
        #expect(DownloadMark.none.joined(to: nil) == "")
    }

    @Test func albumMarkEmptyPartialFullAndLive() async {
        let (m, f, _) = await makeManager(prefs(concurrent: 1))
        let album = Album(id: "a1", name: "Album", artist: "A", artistId: "ar1", songCount: 3, duration: 600)
        #expect(m.index.mark(album: album) == .none, "nothing downloaded: no mark")
        f.hold(after: 1)
        // Live: the index changes (and with it every mark) when a download lands.
        let changed = Mutex(false)
        withObservationTracking { _ = m.index } onChange: { changed.withLock { $0 = true } }
        m.download(songs("s1", "s2", "s3"), reason: .album("a1"))
        #expect(await eventually { m.index.mark(album: album) == .partial(done: 1, total: 3) })
        #expect(changed.withLock { $0 }, "observers hear the download land")
        #expect(m.index.mark(album: album).text == "1 of 3 downloaded")
        #expect(m.index.isDownloaded("s1") && !m.index.isDownloaded("s2"))
        f.release()
        await m.settled()
        #expect(m.index.mark(album: album) == .downloaded)
        var listed = album
        listed.songs = songs("s1", "s2", "s3", "s4")
        #expect(m.index.mark(album: listed) == .partial(done: 3, total: 4), "a page's songs count when listed")
        // Removed again: the mark goes.
        await m.remove(.album("a1"))
        #expect(m.index.mark(album: album) == .none)
    }

    @Test func playlistMarkUsesItsSnapshotOrItsSongs() async {
        let (m, f, _) = await makeManager(prefs(concurrent: 1))
        #expect(m.index.mark(playlistId: "p1") == .none, "never downloaded: no snapshot, no mark")
        m.download(songs("s1"), reason: .song)
        await m.settled()
        #expect(m.index.mark(playlistId: "p1", songIds: ["s1", "s2"]) == .partial(done: 1, total: 2), "its page")
        #expect(m.index.mark(playlistId: "p1", songIds: []) == .none, "an empty playlist")
        f.hold(after: 1)
        let snapshot = DownloadedPlaylist(id: "p1", name: "P", coverArtId: nil, songIds: ["s1", "s2"], savedAt: .now)
        m.download(songs("s1", "s2"), reason: .playlist("p1"), playlist: snapshot)
        #expect(await eventually { m.index.mark(playlistId: "p1") == .partial(done: 1, total: 2) })
        f.release()
        await m.settled()
        #expect(m.index.mark(playlistId: "p1") == .downloaded)
    }

    @Test func cachedSongsNeverCount() async {
        let (m, _, _) = await makeManager()
        m.preDownload(songs("c1"), quality: .original)
        await m.settled()
        #expect(m.localFiles["c1"] != nil, "it is on the phone, as cache")
        #expect(!m.index.isDownloaded("c1"))
        #expect(m.index.mark(songIds: ["c1"]) == .none)
    }

    @Test func artistMarks() async {
        let (m, _, _) = await makeManager()
        let artist = Artist(id: "ar1", name: "A", albumCount: 2)
        #expect(m.index.listMark(artist: artist) == .none)
        m.download(songs("s1", "s2"), reason: .album("a1"))
        await m.settled()
        #expect(m.index.listMark(artist: artist) == .some, "one of two albums: Some downloaded")
        let albums = [Album(id: "a1", name: "One", artist: "A", songCount: 2, duration: 1),
                      Album(id: "a2", name: "Two", artist: "A", songCount: 3, duration: 1)]
        #expect(m.index.mark(artistId: "ar1", albums: albums) == .partial(done: 2, total: 5))
        m.download(songs("s3", "s4", "s5", album: "a2"), reason: .album("a2"))
        await m.settled()
        #expect(m.index.listMark(artist: artist) == .downloaded)
        #expect(m.index.mark(artistId: "ar1", albums: albums) == .downloaded)
    }

    /// Review I2: one album partly on the phone (the rest cancelled) is "Some downloaded" on the artist list, never
    /// "Downloaded"; an album finished through a song already on the phone counts as whole.
    @Test func artistListPartlyDownloadedAlbumIsSome() async {
        let (m, f, _) = await makeManager(prefs(concurrent: 1))
        let artist = Artist(id: "ar1", name: "A", albumCount: 1)
        f.hold(after: 1)
        m.download(songs("s1", "s2", "s3"), reason: .album("a1"))
        #expect(await eventually { m.index.isDownloaded("s1") })
        #expect(m.index.listMark(artist: artist) == .some, "1 of 3 landed, the rest still coming")
        await m.cancelAllActive()
        f.release()
        await m.settled()
        #expect(m.index.isDownloaded("s1") && !m.index.isDownloaded("s2"))
        #expect(m.index.listMark(artist: artist) == .some, "cancelled partway: it stays Some downloaded")
        // "Download the rest", with s1 already there (it only gains the reason): now whole.
        m.download(songs("s1", "s2", "s3"), reason: .album("a1"))
        await m.settled()
        #expect(m.index.listMark(artist: artist) == .downloaded)
        // One song removed on its own: no longer whole.
        await m.remove(songIds: ["s2"])
        #expect(m.index.listMark(artist: artist) == .some)
    }

    /// Re-review N1: an artist with no albums listed never reads "Downloaded", only "Some downloaded".
    @Test func artistListZeroAlbums() async {
        let (m, _, _) = await makeManager()
        let artist = Artist(id: "ar1", name: "A", albumCount: 0)
        #expect(m.index.listMark(artist: artist) == .none, "nothing on the phone")
        m.download(songs("s1"), reason: .album("a1"))
        await m.settled()
        #expect(m.index.listMark(artist: artist) == .some)
    }

    /// Round 2: albums downloaded before the count was kept (builds 8 and 9). With no count, an album whose indexed
    /// songs are all downloads reads whole; one with a cached song of it doesn't. The first time the album's songs are
    /// known the count is saved with its songs (and kept across a relaunch), and the mark follows it.
    @Test func albumsSavedWithoutACountBackfillIt() async throws {
        let store = AudioStore(root: tmp, scope: "w1")
        await store.load()
        for id in ["s1", "s2"] {   // as builds 8 and 9 saved them: album reason, no count
            let file = tmp.appending(path: "old-\(id).tmp")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try Data(count: 1000).write(to: file)
            var meta = AudioMetadata(songs(id)[0])
            meta.albumCoverArtId = "al-a1"
            _ = try await store.add(file, metadata: meta, quality: .original, kind: .download, reason: .album("a1"),
                                    fileExtension: "mp3", downloadsLimit: nil)
        }
        let artist = Artist(id: "ar1", name: "A", albumCount: 1)
        let (m, _, _) = await makeManager()
        #expect(await m.store.entry(songId: "s1")?.metadata.albumSongCount == nil)
        #expect(m.index.listMark(artist: artist) == .downloaded, "count unknown, every indexed song downloaded")
        m.preDownload(songs("s3"), quality: .original)
        await m.settled()
        #expect(m.index.listMark(artist: artist) == .some, "a song of it is only cached: not whole")
        await m.clearCache()
        #expect(m.index.listMark(artist: artist) == .downloaded)
        // The album's page loads: 3 songs. Saved, so the mark is now exact.
        await m.noteAlbumSongCounts(["a1": 3, "a9": 5])
        #expect(await m.store.entry(songId: "s1")?.metadata.albumSongCount == 3)
        #expect(await m.store.entry(songId: "s2")?.metadata.albumSongCount == 3)
        #expect(m.index.listMark(artist: artist) == .some, "2 of 3")
        // Kept across a relaunch.
        let (again, _, _) = await makeManager()
        #expect(again.index.listMark(artist: artist) == .some)
        // A count already saved isn't changed by a later look.
        await again.noteAlbumSongCounts(["a1": 2])
        #expect(await again.store.entry(songId: "s1")?.metadata.albumSongCount == 3)
    }

    // MARK: - Concurrency

    @Test func concurrencyOneToSixAppliedLive() async {
        let (m, f, box) = await makeManager(prefs(concurrent: 1))
        f.hold(after: 0)
        m.download(songs("s1", "s2", "s3", "s4", "s5", "s6", "s7"), reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        box.value.concurrent = 6
        m.retryWaiting()   // what AppModel's preferences fan-out does on a change of concurrency
        #expect(await eventually { f.inFlight == 6 }, "raised: more start at once, without waiting for the first")
        #expect(f.maxInFlight == 6)
        box.value.concurrent = 9
        #expect(m.preferencesNow.concurrent == 6, "clamped to 1–6")
        f.release()
        await m.settled()
        #expect(m.status(for: ["s1", "s2", "s3", "s4", "s5", "s6", "s7"]) == .downloaded)
    }

    @Test func settingsOffersOneToSix() {
        #expect(Array(DownloadPreferences.concurrentRange) == [1, 2, 3, 4, 5, 6])
    }

    // MARK: - Foreground only

    @Test func backgroundPausesWithoutAnAttemptAndResumesOnReturn() async {
        let (m, f, _) = await makeManager(prefs(concurrent: 2))
        f.hold(after: 0)
        m.download(songs("s1"), reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        m.setPresence(active: false, background: true)
        #expect(await eventually { f.inFlight == 0 }, "the fetch in flight is cancelled")
        let job = try? #require(m.jobs.first { $0.songId == "s1" })
        #expect(job?.state == .queued, "back in the queue")
        #expect(job?.connectionAttempts == 0, "no attempt counted")
        #expect(m.failed.isEmpty)
        #expect(m.activity.first?.phase == .paused)
        // Nothing starts in the background, pre-downloads included.
        m.download(songs("s2"), reason: .song)
        m.preDownload(songs("c1"), quality: .original)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(f.inFlight == 0 && f.urls.count == 1)
        f.release()
        m.setPresence(active: true, background: false)
        await m.settled()
        #expect(m.status(for: ["s1", "s2"]) == .downloaded)
        #expect(m.localFiles["c1"] != nil, "the pre-download went too")
    }

    @Test func pauseAllAndResumeAll() async {
        let (m, f, _) = await makeManager()
        f.hold(after: 0)
        m.download(songs("s1"), reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        m.pauseAll()
        #expect(await eventually { f.inFlight == 0 })
        #expect(m.activity.map(\.text) == ["Paused"])
        f.release()
        m.resumeAll()
        await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded)
        #expect(m.jobs.isEmpty && m.failed.isEmpty)
    }

    /// Review M1: an album's cover waits while paused or in the background, and comes on resume.
    @Test func coversWaitWhileHeld() async {
        let (m, f, _) = await makeManager()
        func coverFetches() -> Int { f.urls.filter { $0.path.hasSuffix("/rest/getCoverArt") }.count }
        m.pauseAll()
        m.download(songs("s1"), reason: .album("a1"), coverArtId: "al-c")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(coverFetches() == 0, "paused: no cover either")
        m.resumeAll()
        await m.settled()
        #expect(coverFetches() == 1)
        m.setPresence(active: false, background: true)
        m.download(songs("s2"), reason: .album("a2"), coverArtId: "al-d")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(coverFetches() == 1, "in the background: no cover")
        m.setPresence(active: true, background: false)
        await m.settled()
        #expect(coverFetches() == 2)
    }

    @Test func idleTimerHeldOnlyWhileRunningAndActive() async {
        let (m, f, box) = await makeManager()
        var timer = false
        var writes: [Bool] = []
        m.idleTimer = IdleTimerHold(read: { timer }, write: { timer = $0; writes.append($0) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(writes.isEmpty, "idle: never touched")
        f.hold(after: 0)
        m.download(songs("s1"), reason: .song)
        #expect(await eventually { timer == true }, "running and active: held on")
        m.setPresence(active: false, background: false)   // inactive (Control Centre over the app)
        #expect(await eventually { timer == false }, "not active: put back")
        m.setPresence(active: true, background: false)
        #expect(await eventually { timer == true })
        box.value.keepScreenOn = false
        #expect(await eventually { timer == false }, "the setting off: put back")
        box.value.keepScreenOn = true
        #expect(await eventually { timer == true })
        f.release()
        await m.settled()
        #expect(await eventually { timer == false }, "done: put back")
        #expect(writes == [true, false, true, false, true, false])
    }

    @Test func idleTimerHoldRestoresWhatWasThere() {
        var timer = true
        let hold = IdleTimerHold(read: { timer }, write: { timer = $0 })
        hold.update(hold: true)
        #expect(timer && hold.isHolding)
        hold.update(hold: false)
        #expect(timer, "it was already off before: stays off")
        #expect(!hold.isHolding)
    }

    // MARK: - Downloading now

    @Test func downloadingNowListsRunningWaitingFailedWithCancelAndRetry() async {
        let (m, f, _) = await makeManager(prefs(concurrent: 1))
        f.failWith(URLSessionAudioFetcher.FetchError.status(404))
        m.download(songs("s1"), reason: .song)
        await m.settled()
        f.failWith(nil)
        f.hold(after: 1)
        m.download(songs("s2", "s3"), reason: .album("a1"))
        #expect(await eventually { m.activity.first?.isRunning == true })
        let items = m.activity
        #expect(items.map(\.metadata.songId) == ["s2", "s3", "s1"], "running, then waiting, then failed")
        #expect(items.map(\.text) == ["Downloading", "Waiting to start", "Couldn't download"])
        #expect(items[2].isFailed && items[2].reason == .song)
        // Progress from the fetcher shows on the running row; a stale run's is ignored.
        guard case let .running(run)? = m.jobs.first(where: { $0.songId == "s2" })?.state else {
            Issue.record("s2 isn't running"); return
        }
        #expect(m.activityCount == 3)
        // Review M4: a progress tick re-renders the row alone, not the list or the Settings count.
        let listChanged = Mutex(false)
        withObservationTracking { _ = m.activity; _ = m.activityCount } onChange: { listChanged.withLock { $0 = true } }
        m.noteProgress(items[0].id, run, received: 1_000_000, expected: 8_000_000)
        m.noteProgress(items[0].id, UUID(), received: 5, expected: 10)
        #expect(!listChanged.withLock { $0 }, "progress doesn't invalidate the list")
        #expect(m.activity[0].phase == .running)
        #expect(m.progress[items[0].id] == DownloadProgress(received: 1_000_000, expected: 8_000_000))
        #expect(DownloadActivityCopy.progress(DownloadProgress(received: 1_000_000, expected: 8_000_000)) == "1.0 of 8.0 MB")
        #expect(DownloadActivityCopy.row(3) == "Downloading now \u{00B7} 3")
        // Cancel the waiting one; Try again the failed one.
        await m.cancel(items[1])
        #expect(m.activity.map(\.metadata.songId) == ["s2", "s1"])
        m.retry(items[2])
        #expect(m.activity.map(\.metadata.songId) == ["s2", "s1"] && !m.activity[1].isFailed)
        f.release()
        await m.settled()
        #expect(m.activity.isEmpty)
        #expect(m.status(for: ["s1", "s2"]) == .downloaded && m.status(for: ["s3"]) == .none)
    }

    @Test func downloadingNowWaitsForWiFiAndCancelAll() async {
        let (m, _, _) = await makeManager(network: cellular)
        m.download(songs("s1", "s2"), reason: .album("a1"))
        #expect(await eventually { m.activity.count == 2 })
        #expect(m.activity.allSatisfy { $0.text == "Waiting for Wi-Fi" && $0.symbol == "wifi" })
        #expect(m.hasActiveDownloads, "Keep Magpie open shows")
        #expect(DownloadActivityCopy.keepOpen == "Keep Magpie open to finish downloading")
        await m.cancelAllActive()
        #expect(m.activity.isEmpty && !m.hasActiveDownloads)
        #expect(m.status(for: ["s1", "s2"], reason: .album("a1")) == .none)
    }

    @Test func fetcherPublishesProgressAtMostFourTimesASecond() {
        #expect(URLSessionAudioFetcher.progressInterval == .milliseconds(250))
    }
}
