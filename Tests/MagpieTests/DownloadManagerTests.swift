import Foundation
import MagpieCore
import Playback
import Testing
@testable import Magpie

/// A fetcher that writes `bytes` zero bytes per fetch. `hold(after:)` makes every fetch past the first `n` wait
/// for `release()`; a held fetch that is cancelled throws without leaving a file.
final class FakeFetcher: AudioFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _bytes = 1000
    private var holdAfter: Int?
    private var released = false
    private var calls = 0
    private var error: Error?

    var urls: [URL] { lock.withLock { _urls } }
    var inFlight: Int { lock.withLock { _inFlight } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var bytes: Int {
        get { lock.withLock { _bytes } }
        set { lock.withLock { _bytes = newValue } }
    }

    func hold(after n: Int) { lock.withLock { holdAfter = n; released = false } }
    func release() { lock.withLock { released = true } }
    func failWith(_ error: Error) { lock.withLock { self.error = error } }

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
            while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(5)) }
        }
        try Task.checkCancellation()
        if let error = lock.withLock({ error }) { throw error }
        let file = FileManager.default.temporaryDirectory.appending(path: "fake-\(UUID().uuidString).tmp")
        try Data(count: bytes).write(to: file)
        return (file, "audio/mpeg")
    }
}

/// Polls `condition` until it holds or the deadline passes (no fixed sleeps).
@MainActor
private func eventually(_ seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private let cell = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)

@MainActor @Suite(.serialized) struct DownloadManagerTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "DownloadManagerTests-\(UUID().uuidString)")

    func makeManager(_ prefs: DownloadPreferences = .defaultValue, network: NetworkStatus = .wifi,
                     limit: Int64? = nil) async -> (DownloadManager, FakeFetcher, FakeNetwork) {
        let fetcher = FakeFetcher()
        let net = FakeNetwork(network)
        let store = AudioStore(root: tmp, scope: "abc")
        let url: @MainActor (Song, StreamQuality) -> URL? = { song, q in
            URL(string: "http://192.168.1.2:4533/rest/stream?id=\(song.id)&format=\(q.format)"
                + (q.maxBitRate.map { "&maxBitRate=\($0)" } ?? ""))!
        }
        let cover: @MainActor (String) -> URL? = { URL(string: "http://192.168.1.2:4533/rest/getCoverArt?id=\($0)&size=600")! }
        let manager = if let limit {
            DownloadManager(store: store, fetcher: fetcher, network: net, preferences: { prefs }, url: url,
                            coverURL: cover, limitBytes: { _ in limit })
        } else {
            DownloadManager(store: store, fetcher: fetcher, network: net, preferences: { prefs }, url: url, coverURL: cover)
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
}
