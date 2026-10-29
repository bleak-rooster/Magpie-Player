import Foundation
import MagpieCore
import Playback
import Synchronization
import Testing
import UIKit
@testable import Magpie

/// A fetcher that writes `bytes` zero bytes per fetch under `directory`. `hold(after:)` makes every fetch past the
/// first `n` wait for `release()`; a held fetch that is cancelled throws without leaving a file, unless
/// `ignoresCancellation` (a download that completes anyway, after sign-out or a network flip).
final class FakeFetcher: AudioFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private var _urls: [URL] = []
    private var _written: [URL] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _bytes = 1000
    private var _ignoresCancellation = false
    private var _mimeType: (URL) -> String? = { $0.path.hasSuffix("/rest/getCoverArt") ? "image/jpeg" : "audio/mpeg" }
    private var holdAfter: Int?
    private var released = false
    private var calls = 0
    private var error: Error?

    init(directory: URL = FileManager.default.temporaryDirectory.appending(path: "FakeFetcher-\(UUID().uuidString)")) {
        self.directory = directory
    }

    var urls: [URL] { lock.withLock { _urls } }
    /// Every file the fetcher handed out.
    var written: [URL] { lock.withLock { _written } }
    var inFlight: Int { lock.withLock { _inFlight } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var bytes: Int {
        get { lock.withLock { _bytes } }
        set { lock.withLock { _bytes = newValue } }
    }
    var ignoresCancellation: Bool {
        get { lock.withLock { _ignoresCancellation } }
        set { lock.withLock { _ignoresCancellation = newValue } }
    }
    func mimeType(_ answer: @escaping (URL) -> String?) { lock.withLock { _mimeType = answer } }

    func hold(after n: Int) { lock.withLock { holdAfter = n; released = false } }
    func release() { lock.withLock { released = true } }
    func failWith(_ error: Error?) { lock.withLock { self.error = error } }

    func fetch(_ url: URL, allowsCellular: Bool) async throws -> (file: URL, mimeType: String?) {
        let held: Bool = lock.withLock {
            _urls.append(url)
            _inFlight += 1
            _maxInFlight = max(_maxInFlight, _inFlight)
            calls += 1
            return holdAfter.map { calls > $0 } ?? false
        }
        defer { lock.withLock { _inFlight -= 1 } }
        if held {
            while !lock.withLock({ released }) {
                if ignoresCancellation {
                    await Task.yield()   // Task.sleep would throw on cancel
                    usleep(2000)
                } else {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        if !ignoresCancellation { try Task.checkCancellation() }
        if let error = lock.withLock({ error }) { throw error }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "fake-\(UUID().uuidString).tmp")
        try Data(count: bytes).write(to: file)
        let mime = lock.withLock { _written.append(file); return _mimeType(url) }
        return (file, mime)
    }
}

/// Holds chosen songs between "bytes arrived" and "written to the store" (`beforeStoreForTesting`).
@MainActor
final class StoreGate {
    private var held: Set<String>
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    init(_ held: Set<String>) { self.held = held }

    func pass(_ songId: String) async {
        guard held.contains(songId) else { return }
        await withCheckedContinuation { waiting[songId] = $0 }
    }

    func isWaiting(_ songId: String) -> Bool { waiting[songId] != nil }

    func release(_ songId: String) {
        held.remove(songId)
        waiting.removeValue(forKey: songId)?.resume()
    }
}

private let cell = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)

@MainActor @Suite(.serialized) final class DownloadManagerTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "DownloadManagerTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    func makeManager(_ prefs: DownloadPreferences = .defaultValue, network: NetworkStatus = .wifi,
                     limit: Int64? = nil, store: AudioStore? = nil,
                     notifications: NotificationCenter = NotificationCenter()) async -> (DownloadManager, FakeFetcher, FakeNetwork) {
        let fetcher = FakeFetcher(directory: tmp.appending(path: "fetched"))
        let net = FakeNetwork(network)
        let store = store ?? AudioStore(root: tmp, scope: "abc")
        let url: @MainActor (Song, StreamQuality) -> URL? = { song, q in
            URL(string: "http://192.168.1.2:4533/rest/stream?id=\(song.id)&format=\(q.format)"
                + (q.maxBitRate.map { "&maxBitRate=\($0)" } ?? ""))!
        }
        let cover: @MainActor (String) -> URL? = { URL(string: "http://192.168.1.2:4533/rest/getCoverArt?id=\($0)&size=600")! }
        let manager = if let limit {
            DownloadManager(store: store, fetcher: fetcher, network: net, preferences: { prefs }, url: url,
                            coverURL: cover, limitBytes: { _ in limit }, notifications: notifications)
        } else {
            DownloadManager(store: store, fetcher: fetcher, network: net, preferences: { prefs }, url: url,
                            coverURL: cover, notifications: notifications)
        }
        await manager.start()
        return (manager, fetcher, net)
    }

    func songs(_ ids: String...) -> [Song] {
        ids.map { Song(id: $0, title: "T\($0)", artist: "A", album: "Album", albumId: "a1", duration: 200) }
    }

    @Test func albumDownloadStatusCounts() async {
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1
        let (m, f, _) = await makeManager(prefs)
        f.hold(after: 1)
        m.download(songs("s1", "s2", "s3"), reason: .album("a1"))
        #expect(await eventually { m.status(for: ["s1", "s2", "s3"]) == .downloading(done: 1, total: 3) })
        #expect(m.status(for: ["s1", "s2", "s3"]).text == "Downloading 1 of 3")
        #expect(m.status(for: ["s1", "s2", "s3"]).symbol == "arrow.down.circle.dotted")
        f.release(); await m.settled()
        #expect(m.status(for: ["s1", "s2", "s3"]) == .downloaded)
        #expect(m.status(for: ["s1"]).text == "Downloaded" && m.status(for: ["s1"]).symbol == "arrow.down.circle.fill")
        #expect(Set(m.localFiles.keys) == ["s1", "s2", "s3"])
    }

    @Test func manualWaitsForWiFiOnMobileData() async {
        let (m, f, n) = await makeManager(network: cell)
        m.download(songs("s1"), reason: .song); await m.settled()
        #expect(m.status(for: ["s1"]) == .waitingForWiFi && m.status(for: ["s1"]).text == "Waiting for Wi-Fi")
        #expect(m.status(for: ["s1"]).symbol == "wifi" && f.urls.isEmpty)
        n.status = .wifi; m.retryWaiting(); await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded)
    }

    @Test func mobileDataAllowedWhenSettingOn() async {
        var prefs = DownloadPreferences.defaultValue; prefs.overMobileData = true
        let (m, f, _) = await makeManager(prefs, network: cell)
        m.download(songs("s1"), reason: .song); await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded && f.urls.count == 1)
    }

    @Test func preDownloadRunsOnMobileData() async {
        let (m, f, _) = await makeManager(network: cell)
        m.preDownload(songs("s1"), quality: .aac160); await m.settled()
        #expect(f.urls.count == 1 && f.urls[0].query?.contains("format=aac") == true)
        #expect(await m.store.entry(songId: "s1")?.kind == .cache)
    }

    @Test func concurrencyRespectsSetting() async {
        let (m, f, _) = await makeManager()   // concurrent 2
        f.hold(after: 0)
        m.download(songs("s1", "s2", "s3", "s4"), reason: .album("a1"))
        #expect(await eventually { f.inFlight == 2 })
        f.release(); await m.settled()
        #expect(f.maxInFlight == 2 && f.urls.count == 4)
    }

    @Test func downloadsUseDownloadQuality() async {
        var prefs = DownloadPreferences.defaultValue; prefs.quality = .mp3_320
        let (m, f, _) = await makeManager(prefs)
        m.download(songs("s1"), reason: .song); await m.settled()
        let q = URLComponents(url: f.urls[0], resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.first { $0.name == "format" }?.value == "mp3" && q.first { $0.name == "maxBitRate" }?.value == "320")
        #expect(await m.store.entry(songId: "s1")?.quality == .mp3_320)
    }

    /// D45: an Opus download asks for `format=opus` and is stored as `.ogg` from Navidrome's `audio/ogg`.
    @Test func opusDownloadIsStoredAsOgg() async {
        var prefs = DownloadPreferences.defaultValue; prefs.quality = .opus64
        let (m, f, _) = await makeManager(prefs)
        f.mimeType { $0.path.hasSuffix("/rest/getCoverArt") ? "image/jpeg" : "audio/ogg" }
        m.download(songs("s1"), reason: .song); await m.settled()
        let q = URLComponents(url: f.urls[0], resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.first { $0.name == "format" }?.value == "opus" && q.first { $0.name == "maxBitRate" }?.value == "64")
        let entry = await m.store.entry(songId: "s1")
        #expect(entry?.quality == .opus64 && entry?.fileName.hasSuffix(".ogg") == true)
        #expect(m.status(for: ["s1"]) == .downloaded)
    }

    @Test func coverFetchedOnceWhenAlbumDownloadStarts() async {
        let (m, f, _) = await makeManager()
        m.download(songs("s1", "s2"), reason: .album("a1"), coverArtId: "al-1"); await m.settled()
        #expect(f.urls.filter { $0.path.hasSuffix("/rest/getCoverArt") }.count == 1)
        #expect(f.urls.first { $0.path.hasSuffix("/rest/getCoverArt") }?.query?.contains("size=600") == true)
        #expect(await m.store.coverURL(coverArtId: "al-1") != nil)
    }

    @Test func pendingSurvivesRelaunchWithoutURLs() async throws {
        let (m, _, _) = await makeManager(network: cell)
        m.download(songs("s1", "s2"), reason: .album("a1")); await m.settled()
        let text = try String(contentsOf: m.storeDirectory.appending(path: "pending.json"), encoding: .utf8)
        for needle in ["rest/stream", "t=", "s=", "u=", "http"] { #expect(!text.contains(needle), "\(needle)") }
        let (again, _, _) = await makeManager(network: cell)   // same tmp root and scope
        #expect(again.status(for: ["s1", "s2"]) == .waitingForWiFi)
    }

    @Test func networkFlipMidDownloadWaitsAndLeavesNoPartialFile() async throws {   // Review Focus 4
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1
        let (m, f, n) = await makeManager(prefs)
        f.hold(after: 0)
        m.download(songs("s1"), reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        n.status = cell
        #expect(await eventually { m.status(for: ["s1"]) == .waitingForWiFi })
        f.release(); await m.settled()
        #expect(await m.store.entries().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: m.storeDirectory.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") || $0.hasSuffix(".mp3") })
        n.status = .wifi; m.retryWaiting(); await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded)
    }

    @Test func fullMidAlbumKeepsWhatArrived() async {                               // edge test
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1           // deterministic order
        let (m, f, _) = await makeManager(prefs, limit: 1500)
        m.preDownload(songs("c1"), quality: .original); await m.settled()
        m.download(songs("s1", "s2", "s3"), reason: .album("a1")); await m.settled()
        #expect(m.status(for: ["s1", "s2", "s3"]) == .full)
        #expect(m.status(for: ["s1", "s2", "s3"]).text == "Downloads are full")
        #expect(m.status(for: ["s1", "s2", "s3"]).symbol == "externaldrive.badge.exclamationmark")
        #expect(await m.store.entries().map(\.songId).sorted() == ["c1", "s1"], "cache kept, nothing evicted")
        #expect(f.urls.map { $0.query ?? "" }.filter { $0.contains("id=s3") }.isEmpty, "queued songs stop at full")
    }

    @Test func damagedPendingFileIsIgnored() async throws {
        let store = AudioStore(root: tmp, scope: "abc")
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.directory.appending(path: "pending.json"))
        let (m, f, _) = await makeManager()
        await m.settled()
        #expect(m.status(for: ["s1"]) == DownloadStatus.none && f.urls.isEmpty)
    }

    @Test func fetcherKeepsNothingOnDisk() {
        let config = URLSessionAudioFetcher().configuration
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    /// Fix I1: two cached songs race to become downloads; only one fits.
    @Test func concurrentPromotionsRespectTheLimit() async {
        let (m, f, _) = await makeManager(limit: 1500)   // concurrent 2
        m.preDownload(songs("c1", "c2"), quality: .original); await m.settled()
        m.download(songs("c1", "c2"), reason: .album("a1")); await m.settled()
        let kinds = await m.store.entries().map(\.kind)
        #expect(kinds.filter { $0 == .download }.count == 1 && kinds.filter { $0 == .cache }.count == 1)
        #expect(m.status(for: ["c1", "c2"]) == .full)
        #expect(await m.store.usage().downloadBytes == 1000 && f.urls.count == 2, "no refetch for a promotion")
    }

    /// Fix I1: `remove(reason)` racing a promotion never leaves the removed reason behind.
    @Test func removeRacingAPromotionLeavesNoOrphanReason() async {
        let (m, _, _) = await makeManager()
        for k in 0..<20 {
            let id = "c\(k)", reason = DownloadReason.album("a\(k)")
            m.preDownload(songs(id), quality: .original); await m.settled()
            m.download(songs(id), reason: reason)
            for _ in 0..<k { await Task.yield() }
            await m.remove(reason)
            await m.settled()
            #expect(await m.store.entry(songId: id)?.reasons.contains(reason) != true, "\(k)")
            #expect(m.status(for: [id]) != .downloaded, "\(k)")
        }
    }

    /// Fix I2: a Subsonic error arrives as HTTP 200 with a JSON or XML body; it is never stored as audio.
    @Test func errorBodyIsNotStoredAsAudio() async throws {
        var prefs = DownloadPreferences.defaultValue; prefs.quality = .mp3_320   // the extension alone can't tell
        let (m, f, _) = await makeManager(prefs)
        for mime in ["application/json", "text/xml"] {
            f.mimeType { _ in mime }
            m.download(songs("s1"), reason: .song); await m.settled()
            #expect(m.status(for: ["s1"]) == .failed, "\(mime)")
            #expect(await m.store.entries().isEmpty && m.localFiles.isEmpty, "\(mime)")
        }
        #expect(m.status(for: ["s1"]).text == "Couldn't download" && m.status(for: ["s1"]).symbol == "exclamationmark.circle")
        #expect(f.written.count == 2 && !f.written.contains { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// Fix I2: covers must be images.
    @Test func errorBodyIsNotSavedAsACover() async {
        let (m, f, _) = await makeManager()
        f.mimeType { $0.path.hasSuffix("/rest/getCoverArt") ? "application/json" : "audio/mpeg" }
        m.download(songs("s1"), reason: .album("a1"), coverArtId: "al-1"); await m.settled()
        #expect(await m.store.coverURL(coverArtId: "al-1") == nil)
        #expect(m.status(for: ["s1"]) == .downloaded, "a cover failure doesn't fail the download")
        #expect(!f.written.contains { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// Minor 9/10: a failed fetch is visible, and a retry brings it in. (Not a connection error: since Task 14 those
    /// wait for the server instead.)
    @Test func fetchFailureShowsFailedAndRetries() async {
        let (m, f, _) = await makeManager()
        f.failWith(URLError(.badServerResponse))
        m.download(songs("s1"), reason: .song); await m.settled()
        let stored = await m.store.entries()
        #expect(m.status(for: ["s1"]) == .failed && stored.isEmpty)
        f.failWith(nil)
        m.retryWaiting(); await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded)
    }

    /// Minor 6: once `cancelAll` has run and the scope is erased, nothing late (a fetch that ignored the cancel, a
    /// cover) writes the scope back.
    @Test func nothingRecreatesTheScopeAfterSignOut() async {
        let (m, f, _) = await makeManager()
        f.ignoresCancellation = true
        f.hold(after: 0)
        let playlist = DownloadedPlaylist(id: "p1", name: "P", coverArtId: "pl-1", songIds: ["s1", "s2"], savedAt: Date())
        m.download(songs("s1", "s2"), reason: .playlist("p1"), playlist: playlist, coverArtId: "pl-1")
        #expect(await eventually { f.inFlight >= 2 })
        // The hardest order: the scope is erased while the fetches are still out, and they then complete.
        m.cancelAll()
        await m.store.eraseScope()
        f.release()
        await m.cancelAllAndSettle()
        #expect(!FileManager.default.fileExists(atPath: m.storeDirectory.path))
        #expect(!f.written.contains { FileManager.default.fileExists(atPath: $0.path) })
        #expect(m.status(for: ["s1", "s2"]) == DownloadStatus.none)
    }

    /// Minor 7: a cancelled fetch still unwinding holds its slot, so flipping back to Wi-Fi can't run the song twice.
    @Test func flipBackDoesNotDoubleRun() async {
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1
        let (m, f, n) = await makeManager(prefs)
        f.ignoresCancellation = true
        f.hold(after: 0)
        m.download(songs("s1"), reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        n.status = cell
        #expect(await eventually { m.status(for: ["s1"]) == .waitingForWiFi })
        n.status = .wifi
        #expect(await eventually { m.status(for: ["s1"]) == .downloading(done: 0, total: 1) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(f.urls.count == 1 && f.inFlight == 1, "the queued job waits for the old run to unwind")
        f.release(); await m.settled()
        #expect(f.maxInFlight == 1 && f.urls.count == 2)
        let stored = await m.store.entries()
        #expect(m.status(for: ["s1"]) == .downloaded && stored.count == 1)
        #expect(f.written.filter { FileManager.default.fileExists(atPath: $0.path) }.isEmpty)
    }

    // MARK: - Fix round 2: undo only for a removed job, and only for its song

    /// Remove an album while one song is being written, download the album again: the old run finishing must not
    /// take the re-downloaded songs with it.
    @Test func lateWriteAfterRemoveAndRedownloadKeepsTheAlbum() async {
        let (m, f, _) = await makeManager()   // concurrent 2
        let gate = StoreGate(["s1"])
        m.beforeStoreForTesting = { await gate.pass($0) }
        m.download(songs("s1", "s2"), reason: .album("a1"))
        #expect(await eventually { gate.isWaiting("s1") && m.status(for: ["s2"]) == .downloaded })
        await m.remove(.album("a1"))
        m.download(songs("s1", "s2"), reason: .album("a1"))
        #expect(await eventually { m.status(for: ["s2"]) == .downloaded })
        gate.release("s1"); await m.settled()
        #expect(m.status(for: ["s1", "s2"]) == .downloaded)
        let reasons = await m.store.entries().map(\.reasons)
        #expect(reasons.count == 2 && reasons.allSatisfy { $0 == [.album("a1")] })
        #expect(f.urls.filter { $0.query?.contains("id=s1") == true }.count == 1, "the late write is kept, not refetched")
    }

    /// Remove while one song is being written, and nothing asks for it again: no orphan reason, other songs untouched.
    @Test func lateWriteAfterRemoveIsUndoneForThatSongOnly() async throws {
        let (m, _, _) = await makeManager()
        let gate = StoreGate(["s1"])
        m.beforeStoreForTesting = { await gate.pass($0) }
        m.download(songs("t1"), reason: .album("a1"))
        await m.settled()
        try await m.store.addReason(.playlist("p1"), songIds: ["t1"])   // t1 is also held by a playlist
        m.download(songs("s1"), reason: .album("a1"))
        #expect(await eventually { gate.isWaiting("s1") })
        await m.remove(.album("a1"))
        gate.release("s1"); await m.settled()
        #expect(await m.store.entry(songId: "s1") == nil, "undone")
        #expect(await m.store.entry(songId: "t1")?.reasons == [.playlist("p1")])
    }

    /// A network flip while a song is being written is not a removal: nothing is undone.
    @Test func networkFlipDuringWriteUndoesNothing() async {
        let (m, _, n) = await makeManager()
        let gate = StoreGate(["s1"])
        m.beforeStoreForTesting = { await gate.pass($0) }
        m.download(songs("s1"), reason: .album("a1"))
        #expect(await eventually { gate.isWaiting("s1") })
        n.status = cell
        try? await Task.sleep(for: .milliseconds(20))
        gate.release("s1"); await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded)
        #expect(await m.store.entry(songId: "s1")?.reasons == [.album("a1")])
    }

    // MARK: - Fix round 3: a store that can't read its files yet is read-only

    /// Before first unlock the store refuses writes: a download waits (not failed, no bandwidth spent), a removal
    /// is held back, and both happen once protected data becomes available. The stored song is never touched.
    @Test func lockedStoreHoldsWorkUntilUnlock() async throws {
        let (first, _, _) = await makeManager()
        first.download(songs("s1"), reason: .song); await first.settled()
        let s1 = try #require(await first.store.entry(songId: "s1"))
        let dir = first.storeDirectory
        try Data("garbage".utf8).write(to: dir.appending(path: "index.json"))
        let sidecar = dir.appending(path: s1.fileName + ".json")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: sidecar.path)   // unreadable, like before unlock
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path) }
        let unlocked = Mutex(false)
        let store = AudioStore(root: tmp, scope: "abc", isProtectedDataAvailable: { unlocked.withLock { $0 } })
        let center = NotificationCenter()
        let (m, f, _) = await makeManager(store: store, notifications: center)
        #expect(await store.isReady() == false)

        m.download(songs("s2"), reason: .album("a1")); await m.settled()
        #expect(m.status(for: ["s2"]) == .downloading(done: 0, total: 1), "waiting on the store, not failed")
        #expect(f.urls.isEmpty, "no bandwidth spent before the store can take it")
        await m.remove(.song)
        #expect(fm.fileExists(atPath: dir.appending(path: s1.fileName).path), "nothing deleted while locked")

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path)
        unlocked.withLock { $0 = true }
        #expect(await eventually {
            center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            return m.status(for: ["s2"]) == .downloaded
        })
        await m.settled()
        #expect(await eventually { await m.store.entry(songId: "s1") == nil }, "the held-back removal ran")
        #expect(await m.store.entry(songId: "s2")?.reasons == [.album("a1")])
    }

    // MARK: - T12: parked T11 minors

    @Test func removingAPlaylistDropsItsHeldBackSave() async throws {
        let unlocked = Mutex(false)
        let store = AudioStore(root: tmp, scope: "abc", isProtectedDataAvailable: { unlocked.withLock { $0 } })
        let fm = FileManager.default
        try fm.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.directory.appending(path: "index.json"))
        let held = store.directory.appending(path: String(repeating: "a", count: 64) + ".mp3.json")
        try Data("{}".utf8).write(to: held)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: held.path)   // unreadable, like before unlock
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: held.path) }
        let center = NotificationCenter()
        let (m, _, _) = await makeManager(store: store, notifications: center)
        #expect(await store.isReady() == false)
        let playlist = DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: nil, songIds: ["s1"], savedAt: .now)
        m.download(songs("s1"), reason: .playlist("p1"), playlist: playlist); await m.settled()
        await m.remove(.playlist("p1"))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: held.path)
        unlocked.withLock { $0 = true }
        await m.protectedDataBecameAvailable(); await m.settled()
        #expect(await store.isReady())
        #expect(await store.playlists().isEmpty, "the removed playlist is not saved after all")
        #expect(await store.entry(songId: "s1") == nil)
    }

    @Test func heldBackRemovalRunsBeforeTheNextWrite() async throws {
        let (first, _, _) = await makeManager()
        first.download(songs("s1"), reason: .song); await first.settled()
        let s1 = try #require(await first.store.entry(songId: "s1"))
        let dir = first.storeDirectory
        try Data("garbage".utf8).write(to: dir.appending(path: "index.json"))
        let sidecar = dir.appending(path: s1.fileName + ".json")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: sidecar.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path) }
        let unlocked = Mutex(false)
        let clock = Mutex(Date())
        let store = AudioStore(root: tmp, scope: "abc", now: { clock.withLock { $0 } },
                               isProtectedDataAvailable: { unlocked.withLock { $0 } })
        let (m, _, _) = await makeManager(store: store)   // the manager's 30 s retry won't come during the test
        await m.remove(.song)
        #expect(fm.fileExists(atPath: dir.appending(path: s1.fileName).path), "nothing deleted while locked")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path)
        unlocked.withLock { $0 = true }
        clock.withLock { $0 += 60 }   // the store's own read retry is due
        m.download(songs("s2"), reason: .album("a1")); await m.settled()   // no unlock notification
        #expect(await store.entry(songId: "s1") == nil, "the held-back removal ran first")
        #expect(await store.entry(songId: "s2")?.reasons == [.album("a1")])
    }

    @Test func fullStatusSurvivesRelaunch() async {
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1
        let (m, _, _) = await makeManager(prefs, limit: 1500)
        m.download(songs("s1", "s2"), reason: .album("a1")); await m.settled()
        #expect(m.status(for: ["s1", "s2"]) == .full)
        let (again, f, _) = await makeManager(prefs, limit: 1500)   // same tmp root and scope
        await again.settled()
        #expect(again.status(for: ["s1", "s2"]) == .full)
        #expect(f.urls.isEmpty, "stopped jobs stay stopped until retried")
        again.retryWaiting(); await again.settled()
        #expect(again.status(for: ["s1", "s2"]) == .full, "still no room")
    }

    @Test func invalidPreDownloadIsNotTriedAgain() async {
        let (m, f, _) = await makeManager()
        f.mimeType { _ in "text/html" }
        m.preDownload(songs("c1"), quality: .original); await m.settled()
        m.preDownload(songs("c1"), quality: .original); await m.settled()
        #expect(f.urls.count == 1)
        m.preDownload(songs("c1"), quality: .mp3_320); await m.settled()
        #expect(f.urls.count == 2, "another quality may work")
    }

    @Test func removeSongsDropsEveryReason() async {
        let (m, _, _) = await makeManager()
        m.download(songs("s1", "s2"), reason: .album("a1"))
        m.download(songs("s1"), reason: .song); await m.settled()
        await m.remove(songIds: ["s1"])
        #expect(await m.store.entry(songId: "s1") == nil)
        #expect(await m.store.entry(songId: "s2")?.reasons == [.album("a1")])
        #expect(Set(m.localFiles.keys) == ["s2"])
    }

    @Test func nothingIsWrittenBeforeStart() async throws {
        let store = AudioStore(root: tmp, scope: "abc")
        let fetcher = FakeFetcher(directory: tmp.appending(path: "fetched"))
        let m = DownloadManager(store: store, fetcher: fetcher, network: FakeNetwork(.wifi),
                                preferences: { .defaultValue },
                                url: { song, _ in URL(string: "http://192.168.1.2:4533/rest/stream?id=\(song.id)")! },
                                coverURL: { URL(string: "http://192.168.1.2:4533/rest/getCoverArt?id=\($0)&size=600")! })
        let playlist = DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: "pl-1", songIds: ["s1"], savedAt: .now)
        m.download(songs("s1"), reason: .playlist("p1"), playlist: playlist, coverArtId: "pl-1")
        await m.settled()
        #expect(fetcher.urls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path), "e.g. a sign-out's erase may still be running")
        let gate = Task<Void, Never> {}
        m.begin(after: gate); await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded)
        #expect(await store.playlists().map(\.id) == ["p1"])
        #expect(await store.coverURL(coverArtId: "pl-1") != nil)
    }

    // MARK: - Fix round 1: "Downloads are full" and partial removals

    @Test func partialRemovalKeepsOtherFullJobs() async {
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1
        let (m, _, _) = await makeManager(prefs, limit: 1500)
        m.download(songs("f1"), reason: .favourites); await m.settled()
        m.download(songs("s1", "s2"), reason: .album("a1")); await m.settled()
        #expect(m.status(for: ["s1", "s2"], reason: .album("a1")) == .full)
        await m.remove(.favourites, songIds: ["gone"])   // a favourites sync that frees nothing
        #expect(m.status(for: ["s1", "s2"], reason: .album("a1")) == .full)
        let (again, _, _) = await makeManager(prefs, limit: 1500)
        await again.settled()
        #expect(again.status(for: ["s1", "s2"], reason: .album("a1")) == .full, "and after a relaunch")
    }

    @Test func removalThatFreesRoomRequeuesFullJobs() async {
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1
        let (m, _, _) = await makeManager(prefs, limit: 1500)
        m.download(songs("f1"), reason: .favourites); await m.settled()
        m.download(songs("s1", "s2"), reason: .album("a1")); await m.settled()
        await m.remove(.favourites, songIds: ["f1"]); await m.settled()
        #expect(await m.store.entry(songId: "s1") != nil, "the freed room is used")
        #expect(m.status(for: ["s1", "s2"], reason: .album("a1")) == .full, "s2 still doesn't fit")
    }

    @Test func removingTheFullAlbumClearsItsFullJobsOnly() async {
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1
        let (m, _, _) = await makeManager(prefs, limit: 1000)
        m.download(songs("s1"), reason: .song); await m.settled()
        m.download(songs("a"), reason: .album("a1")); await m.settled()
        m.download(songs("b"), reason: .album("b1")); await m.settled()
        await m.remove(.album("a1"))
        #expect(m.status(for: ["a"], reason: .album("a1")) == .none)
        #expect(m.status(for: ["b"], reason: .album("b1")) == .full)
    }
}
