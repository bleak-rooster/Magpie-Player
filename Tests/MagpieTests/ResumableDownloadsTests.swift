import Foundation
import MagpieCore
import Playback
import Testing
@testable import Magpie

/// R1 (background downloads, resume) and R4 (an artist's "Download all songs") in the download manager.
@MainActor @Suite(.serialized) final class ResumableDownloadsTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "ResumableDownloadsTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    func makeManager(_ prefs: DownloadPreferences = .defaultValue, network: NetworkStatus = .wifi,
                     background: BackgroundAudioFetcher? = nil) async -> (DownloadManager, FakeFetcher) {
        let fetcher = FakeFetcher(directory: tmp.appending(path: "fetched"))
        let manager = DownloadManager(
            store: AudioStore(root: tmp.appending(path: "Magpie-root"), scope: "r1"), fetcher: fetcher,
            network: FakeNetwork(network), preferences: { prefs },
            url: { song, q in URL(string: "http://192.168.1.2:4533/rest/stream?id=\(song.id)&format=\(q.format)")! },
            coverURL: { URL(string: "http://192.168.1.2:4533/rest/getCoverArt?id=\($0)&size=600")! },
            backgroundFetcher: background)
        await manager.start()
        return (manager, fetcher)
    }

    /// A background fetcher on a stub session, rooted where the manager's store keeps its scopes.
    func makeBackground(_ session: StubSession) -> BackgroundAudioFetcher {
        BackgroundAudioFetcher(audioRoot: tmp.appending(path: "Magpie-root/Magpie/Audio")) { _ in session }
    }

    func songs(_ ids: String..., album: String = "a1", artist: String = "ar1") -> [Song] {
        ids.map { Song(id: $0, title: "T\($0)", artist: "A", artistId: artist, album: "Album \(album)", albumId: album,
                       duration: 200, bitRate: 320) }
    }

    func key(_ id: String, _ quality: StreamQuality = .original) -> String { PartialDownloads.key(songId: id, quality: quality) }

    func prefs(background: Bool, concurrent: Int = 2) -> DownloadPreferences {
        var p = DownloadPreferences.defaultValue
        p.downloadInBackground = background
        p.concurrent = concurrent
        return p
    }

    func info(received: Int64, expected: Int64?) -> PartialDownloads.Info {
        PartialDownloads.Info(received: received, expected: expected, isOriginal: true, allowsCellular: false,
                              validator: nil, acceptsRanges: false, mimeType: nil)
    }

    // MARK: - Background

    @Test func withTheSettingOnDownloadsGoOnInTheBackground() async {
        let (m, f) = await makeManager(prefs(background: true, concurrent: 1))
        f.hold(after: 0)
        m.download(songs("s1", "s2", "s3"), reason: .song)
        #expect(await eventually { f.inFlight == 1 }, "P1's cap while Magpie is open")
        m.setPresence(active: false, background: true)
        #expect(await eventually { f.inFlight == 3 }, "in the background every queued download is handed to the session")
        #expect(!m.isHeld && !m.showsKeepOpen, "nothing paused, and no Keep Magpie open")
        #expect(m.activity.allSatisfy { $0.phase == .running })
        f.release()
        await m.settled()
        #expect(m.status(for: ["s1", "s2", "s3"]) == .downloaded)
    }

    @Test func theSettingOffRestoresForegroundOnly() async {
        let (m, f) = await makeManager(prefs(background: false))
        f.hold(after: 0)
        m.download(songs("s1"), reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        #expect(m.showsKeepOpen, "Keep Magpie open to finish downloading")
        m.setPresence(active: false, background: true)
        #expect(await eventually { f.inFlight == 0 }, "P1: the fetch is held in the background")
        #expect(m.activity.first?.phase == .paused)
        f.release()
        m.setPresence(active: true, background: false)
        await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded)
    }

    @Test func downloadsUseTheBackgroundSessionWithTheSettingOn() async throws {
        let session = StubSession()
        let bg = makeBackground(session)
        let (m, f) = await makeManager(prefs(background: true), background: bg)
        m.download(songs("s1"), reason: .song)
        #expect(await eventually { session.tasks.first?.isResumed == true })
        let task = try #require(session.tasks.first)
        #expect(task.taskDescription == "r1/\(key("s1"))", "named by scope and key, never a server string")
        #expect(f.urls.isEmpty, "not the foreground fetcher")
        task.response = HTTPURLResponse(url: URL(string: "http://192.168.1.2:4533/rest/stream")!, statusCode: 200,
                                        httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])
        let body = tmp.appending(path: "body.tmp")
        try Data(count: 1000).write(to: body)
        bg.handleFinished(task, location: body)
        bg.handleCompleted(task, error: nil)
        await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded, "moved into the store from the delegate callback")
    }

    @Test func relaunchStoresWhatFinishedWhileClosedAndDropsStrayPartials() async throws {
        // First run: the download is queued (waiting for Wi-Fi), so pending.json keeps it.
        let first = await makeManager(prefs(background: true), network: NetworkStatus(isConnected: true, isCellular: true,
                                                                                      isConstrained: false))
        first.0.download(songs("s1"), reason: .album("a1"))
        #expect(await eventually { first.0.activity.first?.text == "Waiting for Wi-Fi" })
        // Meanwhile the system finished it, and parked it; a pre-download left resume data no job wants.
        let session = StubSession()
        let background = makeBackground(session)
        let partials = background.partials("r1")
        let done = tmp.appending(path: "done.tmp")
        try Data(count: 1000).write(to: done)
        try partials.adopt(done, key: key("s1"), as: "done")
        var parkedInfo = info(received: 1000, expected: 1000)
        parkedInfo.mimeType = "audio/mpeg"
        try partials.saveInfo(parkedInfo, key: key("s1"))
        try partials.saveResumeData(Data(count: 10), key: key("stray"))
        let (m, _) = await makeManager(prefs(background: true), background: background)
        await m.settled()
        #expect(m.status(for: ["s1"], reason: .album("a1")) == .downloaded, "the parked file went into the store")
        #expect(session.tasks.isEmpty, "without the network")
        #expect(await eventually { partials.keys().isEmpty }, "the stray partial is gone")
    }

    // MARK: - Resume

    @Test func downloadingNowShowsPausedWithSizesAndResume() async throws {
        let (m, f) = await makeManager(prefs(background: true))
        f.hold(after: 0)
        m.download(songs("s1"), reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        // What the background fetcher writes as the task stops.
        try PartialDownloads(directory: m.store.partialsDirectory).saveInfo(info(received: 2_100_000, expected: 8_400_000),
                                                                            key: key("s1"))
        m.pauseAll()
        #expect(await eventually { m.activity.first?.text == "Paused \u{00B7} 2.1 of 8.4 MB" })
        #expect(m.activity.first?.symbol == "pause.circle")
        #expect(DownloadActivityCopy.paused(DownloadProgress(received: 2_100_000, expected: nil)) == "Paused \u{00B7} 2.1 MB")
        f.release()
        m.resumeAll()   // the row's Resume
        await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded)
        #expect(m.activity.isEmpty)
    }

    @Test func partialsAreRemovedOnCancelAndOnSignOut() async throws {
        let (m, f) = await makeManager(prefs(background: true, concurrent: 1))
        let partials = PartialDownloads(directory: m.store.partialsDirectory)
        f.hold(after: 0)
        m.download(songs("s1", "s2", "s3"), reason: .song)
        for id in ["s1", "s2", "s3"] { try partials.saveResumeData(Data(count: 10), key: key(id)) }
        #expect(await eventually { f.inFlight == 1 })
        let s2 = try #require(m.activity.first { $0.metadata.songId == "s2" })
        await m.cancel(s2)
        #expect(partials.keys() == [key("s1"), key("s3")], "the cancelled one's partial goes")
        m.cancelAll()   // sign-out
        #expect(partials.keys().isEmpty, "and every partial on sign-out")
        f.release()
    }

    @Test func cancelStopsTheBackgroundTaskToo() async throws {
        let session = StubSession()
        let (m, _) = await makeManager(prefs(background: true), background: makeBackground(session))
        m.download(songs("s1"), reason: .song)
        #expect(await eventually { session.tasks.first?.isResumed == true })
        let item = try #require(m.activity.first)
        await m.cancel(item)
        #expect(session.tasks.first?.isCancelled == true)
        await m.settled()
        #expect(m.activity.isEmpty && m.status(for: ["s1"]) == .none)
    }

    // MARK: - R4: Download all songs

    @Test func artistDownloadAllMarksAndRemovesAsAGroup() async {
        let (m, _) = await makeManager()
        #expect(m.artistStatus("ar1") == .none)
        m.download(songs("s1", "s2", album: "a1"), reason: .artist("ar1"), coverArtId: "al-1")
        m.download(songs("s3", album: "a2"), reason: .artist("ar1"), coverArtId: "al-2")
        await m.settled()
        #expect(m.artistStatus("ar1") == .downloaded, "\"Remove downloads\" now")
        #expect(m.reasons(for: "s1") == [.artist("ar1")])
        let artist = Artist(id: "ar1", name: "A", albumCount: 2)
        #expect(m.index.listMark(artist: artist) == .downloaded, "the artist's mark: both albums whole")
        let albums = [Album(id: "a1", name: "One", artist: "A", songCount: 2, duration: 1),
                      Album(id: "a2", name: "Two", artist: "A", songCount: 1, duration: 1)]
        #expect(m.index.mark(artistId: "ar1", albums: albums) == .downloaded)
        await m.remove(.artist("ar1"))
        #expect(m.artistStatus("ar1") == .none)
        #expect(m.index.mark(artistId: "ar1", albums: albums) == .none, "removed as a group")
    }

    @Test func artistDownloadWaitsForWiFiAndFull() async {
        let (m, _) = await makeManager(network: NetworkStatus(isConnected: true, isCellular: true, isConstrained: false))
        m.download(songs("s1"), reason: .artist("ar1"))
        #expect(await eventually { m.artistStatus("ar1") == .waitingForWiFi }, "the Wi-Fi rules hold")
        await m.remove(.artist("ar1"))
        #expect(m.artistStatus("ar1") == .none)
    }

    @Test func confirmationCopy() {
        // R20 (appraisal R4, glossary): in the artist's ⋯, and it says where the songs go.
        #expect(ArtistDownloadCopy.title(count: 143) == "Download 143 songs to this iPhone?")
        #expect(ArtistDownloadCopy.title(count: 1) == "Download 1 song to this iPhone?")
        #expect(ArtistDownloadCopy.message(bytes: 1_200_000_000) == "About 1.2 GB.")
        #expect(ArtistDownloadCopy.message(bytes: nil) == nil, "no size when it isn't known")
        #expect(ArtistDownloadCopy.action == "Download to this iPhone\u{2026}")
        #expect(ArtistDownloadCopy.confirm == "Download")
        #expect(ArtistDownloadCopy.remove == "Remove download")
        #expect(ArtistDownloadCopy.menuTitle(.none) == ArtistDownloadCopy.action)
        #expect(ArtistDownloadCopy.menuTitle(.downloaded) == "Remove download")
        #expect(ArtistDownloadCopy.menuTitle(.downloading(done: 1, total: 3)) == "Remove download",
                "while on its way, removing stops it too")
        #expect(ArtistDownloadCopy.menuTitle(.failed) == "Remove download")
        // The estimate: bit rate × duration for Original; the format's rate when converting.
        let s = Song(id: "x", title: "T", artist: "A", album: "Al", duration: 100, bitRate: 320)
        #expect(ArtistDownloadCopy.estimate([s, s], quality: .original) == 8_000_000)
        #expect(ArtistDownloadCopy.estimate([s], quality: .mp3_192) == 2_400_000)
        let unknown = Song(id: "y", title: "T", artist: "A", album: "Al", duration: 100)
        #expect(ArtistDownloadCopy.estimate([s, unknown], quality: .original) == nil, "unknown for one: not known")
    }
}
