import Foundation
import os
import Testing
import MagpieCore
@testable import Playback

private func item(_ id: String, _ d: ScrobbleDestination, at: Double = 0) -> QueuedScrobble {
    QueuedScrobble(destination: d, song: AudioMetadata(Song(id: id, title: "T", artist: "A", album: "B", duration: 200)),
                   listenedAt: Date(timeIntervalSince1970: at))
}

@Suite struct ScrobbleQueueTests {
    @Test func boundedPerDestination() async {
        let q = ScrobbleQueue(fileURL: nil)
        for i in 0..<501 { await q.enqueue(item("s\(i)", .navidrome)) }
        await q.enqueue(item("lb", .listenBrainz))
        let nd = await q.pending(.navidrome)
        #expect(nd.count == 500 && nd.first?.song.songId == "s1" && nd.last?.song.songId == "s500")
        #expect(await q.pending(.listenBrainz).map(\.song.songId) == ["lb"])
    }

    @Test func persistsAndHasNoCredentials() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID())/scrobble-queue.json")
        let q = ScrobbleQueue(fileURL: url)
        await q.enqueue(item("s1", .listenBrainz, at: 1_700_000_000))
        let again = ScrobbleQueue(fileURL: url)
        #expect(await again.pending(.listenBrainz).first?.listenedAt == Date(timeIntervalSince1970: 1_700_000_000))
        let text = try String(contentsOf: url, encoding: .utf8)
        for needle in ["token", "t=", "s=", "password", "Authorization"] { #expect(!text.contains(needle), "\(needle)") }
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func removeAndClear() async {
        let q = ScrobbleQueue(fileURL: nil)
        let a = item("a", .navidrome), b = item("b", .navidrome)
        await q.enqueue(a); await q.enqueue(b)
        await q.remove(ids: [a.id])
        #expect(await q.pending(.navidrome).map(\.id) == [b.id])
        await q.clear()
        #expect(await q.pending(.navidrome).isEmpty)
    }

    @Test func corruptFileStartsEmpty() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID())/scrobble-queue.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: url)
        let q = ScrobbleQueue(fileURL: url)
        #expect(await q.pending(.navidrome).isEmpty)
        await q.enqueue(item("s1", .navidrome))
        #expect(await ScrobbleQueue(fileURL: url).pending(.navidrome).count == 1)
    }

    /// The song's library id is kept, so the dequeue check (D29) judges it as the send-time check did.
    @Test func keepsLibraryId() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID())/scrobble-queue.json")
        let song = Song(id: "s1", title: "T", artist: "A", album: "B", duration: 200, libraryId: 7)
        await ScrobbleQueue(fileURL: url).enqueue(QueuedScrobble(destination: .navidrome, song: song, listenedAt: .now))
        let back = try #require(await ScrobbleQueue(fileURL: url).pending(.navidrome).first)
        #expect(back.libraryId == 7 && back.playedSong.libraryId == 7 && back.playedSong.id == "s1")
    }

    /// Fix round 1, I1: a launch before first unlock can't read the file. It is never written over: plays queued
    /// meanwhile stay in memory and are merged once a read works.
    @Test func unreadableFileIsNeverOverwritten() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID())/scrobble-queue.json")
        await ScrobbleQueue(fileURL: url).enqueue(item("a", .navidrome))
        let failures = OSAllocatedUnfairLock(initialState: 2)   // the init's read and the enqueue's retry fail
        let flaky: ScrobbleQueue.Reader = { url in
            if failures.withLock({ n in defer { n -= 1 }; return n > 0 }) { throw CocoaError(.fileReadNoPermission) }
            return try ScrobbleQueue.fileReader(url)
        }
        let q = ScrobbleQueue(fileURL: url, reader: flaky)
        await q.enqueue(item("b", .navidrome))
        #expect(await ScrobbleQueue(fileURL: url).pending(.navidrome).map(\.song.songId) == ["a"], "file untouched")
        #expect(await q.pending(.navidrome).map(\.song.songId) == ["a", "b"], "merged once readable")
        #expect(await ScrobbleQueue(fileURL: url).pending(.navidrome).map(\.song.songId) == ["a", "b"], "and saved")
    }

    @Test func reloadMergesAfterUnlock() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID())/scrobble-queue.json")
        await ScrobbleQueue(fileURL: url).enqueue(item("a", .listenBrainz))
        let locked = OSAllocatedUnfairLock(initialState: true)
        let q = ScrobbleQueue(fileURL: url) { url in
            if locked.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            return try ScrobbleQueue.fileReader(url)
        }
        await q.enqueue(item("b", .listenBrainz))
        #expect(await q.pending(.listenBrainz).map(\.song.songId) == ["b"], "locked: only what was queued meanwhile")
        locked.withLock { $0 = false }
        await q.reload()
        #expect(await ScrobbleQueue(fileURL: url).pending(.listenBrainz).map(\.song.songId) == ["a", "b"])
    }
}
