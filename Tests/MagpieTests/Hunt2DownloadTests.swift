import Foundation
import MagpieCore
import MagpieTestSupport
import Playback
import Testing
import UIKit
@testable import Magpie

private let cell = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)

@MainActor private final class OfflineFlag { var value = false }

/// Hunt 2: downloads, storage and offline under chaos. `pending.json` that can't be read yet, seeded storms of
/// downloads, removals, promotions, network flips, offline toggles and sign-outs.
@MainActor @Suite(.serialized) final class Hunt2DownloadTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "Hunt2DownloadTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    func makeManager(_ prefs: DownloadPreferences = .defaultValue, network: NetworkStatus = .wifi, limit: Int64? = nil,
                     offline: @escaping @MainActor () -> Bool = { false }) async -> (DownloadManager, FakeFetcher, FakeNetwork) {
        let fetcher = FakeFetcher(directory: tmp.appending(path: "fetched"))
        let net = FakeNetwork(network)
        let store = AudioStore(root: tmp, scope: "abc")
        let manager = DownloadManager(
            store: store, fetcher: fetcher, network: net, preferences: { prefs },
            url: { song, q in URL(string: "http://192.168.1.2:4533/rest/stream?id=\(song.id)&format=\(q.format)") },
            coverURL: { URL(string: "http://192.168.1.2:4533/rest/getCoverArt?id=\($0)&size=600") },
            limitBytes: { _ in limit }, isOffline: offline, notifications: NotificationCenter())
        await manager.start()
        return (manager, fetcher, net)
    }

    func songs(_ ids: [String], album: String = "a1") -> [Song] {
        ids.map { Song(id: $0, title: "T\($0)", artist: "A", album: "Album", albumId: album, duration: 200) }
    }

    // MARK: - pending.json that can't be read yet

    /// Before first unlock (or on an I/O error) `pending.json` can't be read: it must not be written over, or
    /// removed, until it has been; once it reads, its downloads come back beside the ones asked for meanwhile.
    @Test func unreadablePendingIsNeverWrittenOver() async throws {
        let (first, _, _) = await makeManager(network: cell)
        first.download(songs(["s1", "s2"]), reason: .album("a1")); await first.settled()
        let pending = first.pendingURL
        let original = try Data(contentsOf: pending)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: pending.path)   // unreadable, like before unlock
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pending.path) }

        let (locked, _, _) = await makeManager(network: cell)
        locked.download(songs(["s3"], album: "a3"), reason: .album("a3")); await locked.settled()
        #expect(fm.fileExists(atPath: pending.path), "an unread pending.json was removed or replaced")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pending.path)
        #expect(try Data(contentsOf: pending) == original, "an unread pending.json was written over")

        // Readable again: the next save reads it first and keeps both.
        locked.download(songs(["s4"], album: "a4"), reason: .album("a4")); await locked.settled()
        let (relaunched, _, _) = await makeManager(network: cell)
        for id in ["s1", "s2", "s3", "s4"] {
            #expect(relaunched.status(for: [id]) == .waitingForWiFi, "\(id) lost from the queue")
        }
    }

    // MARK: - Storms

    /// Seeded storms of downloads, pre-downloads, removals, promotions (a cached song downloaded), re-downloads,
    /// retries, network flips, offline toggles, cancelAll and relaunches. Invariants after every settle: no trap; the
    /// store's downloads fit the limit and each has a reason; a song seen downloaded stays downloaded unless the user
    /// removed it; nothing is left running.
    @Test func seededStorms() async throws {
        let ids = (0..<12).map { "s\($0)" }
        let albums = ["a1", "a2", "a3"]
        let reasons: [DownloadReason] = [.song, .album("a1"), .album("a2"), .playlist("p1"), .favourites]
        var totalSeen = 0
        for seed in UInt64(1)...60 {
            var rng = SeededRNG(seed: seed)
            var prefs = DownloadPreferences.defaultValue
            prefs.concurrent = Int.random(in: 1...4, using: &rng)
            let limit: Int64? = [nil, 0, 2500, 6000, .max].randomElement(using: &rng)!
            let offline = OfflineFlag()
            let (first, fetcher, net) = await makeManager(prefs, limit: limit, offline: { offline.value })
            var m = first
            m.loadPlayableForCheck = { _ in true }
            var seenDownloaded = Set<String>()
            var removedByUser = Set<String>()
            for step in 0..<80 {
                let song = ids.randomElement(using: &rng)!
                let some = Array(ids.shuffled(using: &rng).prefix(Int.random(in: 1...4, using: &rng)))
                let reason = reasons.randomElement(using: &rng)!
                fetcher.bytes = Int.random(in: 1...1500, using: &rng)
                switch Int.random(in: 0..<16, using: &rng) {
                case 0, 1, 2:
                    let playlist = reason == .playlist("p1")
                        ? DownloadedPlaylist(id: "p1", name: "P", coverArtId: nil, songIds: some, savedAt: Date()) : nil
                    m.download(songs(some, album: albums.randomElement(using: &rng)!), reason: reason, playlist: playlist,
                               coverArtId: Bool.random(using: &rng) ? "al-1" : nil)
                case 3, 4: m.preDownload(songs(some), quality: [.original, .aac160, .opus128].randomElement(using: &rng)!)
                case 5: removedByUser.formUnion(ids); await m.remove(reason)   // whole reason: any song may go
                case 6: removedByUser.formUnion(some); await m.remove(reason, songIds: some)
                case 7: removedByUser.formUnion(some); await m.remove(songIds: Set(some))
                case 8: if step % 20 == 8 { removedByUser.formUnion(ids); await m.removeAllDownloads() }
                case 9: await m.clearCache()
                case 10: m.retryWaiting()
                case 11: net.status = [.wifi, cell, NetworkStatus(isConnected: false, isCellular: false, isConstrained: false)]
                    .randomElement(using: &rng)!
                case 12: offline.value.toggle(); m.networkChanged()
                case 13: m.redownload(songIds: some, quality: .aac160)
                case 14: if step % 15 == 14 { m.cancelAll() }
                default:
                    if step % 25 == 0 {   // relaunch on the same store
                        await m.settled()
                        let (again, _, _) = await makeManager(prefs, network: net.status, limit: limit, offline: { offline.value })
                        again.loadPlayableForCheck = { _ in true }
                        m.cancelAll(); m = again
                    } else {
                        m.serverAnswered(); m.dropBadFile(songId: song)   // the file opens: kept
                    }
                }
                if Bool.random(using: &rng) { await m.settled() }
                let entries = await m.store.entries()
                for e in entries where e.kind == .download {
                    #expect(!e.reasons.isEmpty, "seed \(seed) step \(step): \(e.songId) kept with no reason")
                    seenDownloaded.insert(e.songId)
                }
                if let limit { #expect(await m.store.usage().downloadBytes <= limit, "seed \(seed) step \(step): over the limit") }
            }
            net.status = .wifi; offline.value = false; m.networkChanged(); m.retryWaiting()
            await m.settled()
            let finalDownloads = Set(await m.store.entries().filter { $0.kind == .download }.map(\.songId))
            let lost = seenDownloaded.subtracting(removedByUser).subtracting(finalDownloads)
            #expect(lost.isEmpty, "seed \(seed): downloads deleted without a removal: \(lost)")
            #expect(m.tasks.isEmpty, "seed \(seed): work left running")
            totalSeen += seenDownloaded.count
            m.cancelAll(); await m.settled()
            try? FileManager.default.removeItem(at: tmp)
        }
        #expect(totalSeen > 100, "the storms downloaded too little to test anything (\(totalSeen))")
    }

    // MARK: - Scrobble queue replays

    /// A play's duration comes from the server or from a queued play's snapshot in `scrobble-queue.json`: one too
    /// big for milliseconds in an `Int`, or not finite, sends no duration instead of trapping.
    @Test func listenDurationNeverTraps() {
        for duration in [0, -1, 200, 1e15, 1e300, .greatestFiniteMagnitude, .infinity, -.infinity, .nan] as [Double] {
            let meta = AudioMetadata(Song(id: "s", title: "T", artist: "A", album: "B", duration: duration))
            let listen = ScrobbleRouter.listen(meta, at: Date(timeIntervalSince1970: 1_700_000_000))
            if duration == 200 { #expect(listen.durationMs == 200_000) }
            if !(duration > 0 && duration < 1e12) { #expect(listen.durationMs == nil, "\(duration)") }
        }
    }

    /// A removal made while `pending.json` couldn't be read holds when the file's downloads come back.
    @Test func removalWhileUnreadHoldsAfterTheMerge() async throws {
        let (first, _, _) = await makeManager(network: cell)
        first.download(songs(["s1"]), reason: .album("a1"))
        first.download(songs(["s2"], album: "a2"), reason: .album("a2")); await first.settled()
        let pending = first.pendingURL
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: pending.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pending.path) }

        let (locked, _, _) = await makeManager(network: cell)
        await locked.remove(.album("a1"))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pending.path)
        locked.download(songs(["s3"], album: "a3"), reason: .album("a3")); await locked.settled()
        #expect(locked.status(for: ["s1"], reason: .album("a1")) == DownloadStatus.none, "a removed album came back")
        #expect(locked.status(for: ["s2"]) == .waitingForWiFi)
        #expect(locked.status(for: ["s3"]) == .waitingForWiFi)
    }
}
