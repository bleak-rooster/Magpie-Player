import Foundation
import Synchronization
import Testing
import MagpieCore
@testable import Playback

/// Round 28 O2 (owner, 2026-11-15; amends D313): lyrics of downloaded songs kept on the phone (D336).
@Suite final class OfflineLyricsTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineLyricsTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    final class Clock: Sendable {
        let current = Mutex(Date(timeIntervalSince1970: 1_000))
        func advance(_ s: TimeInterval) { current.withLock { $0 += s } }
        var now: @Sendable () -> Date { { [self] in current.withLock { $0 } } }
    }

    func store(clock: Clock = Clock()) async -> AudioStore {
        let store = AudioStore(root: tmp, scope: "abc", now: clock.now)
        await store.load()
        return store
    }

    func add(_ store: AudioStore, _ id: String, kind: AudioKind = .download) async throws {
        let incoming = tmp.appending(path: "incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let file = incoming.appending(path: UUID().uuidString)
        try Data(count: 10).write(to: file)
        try await store.add(file, metadata: AudioMetadata(Song(id: id, title: "T", artist: "A", album: "B", duration: 1)),
                            quality: .original, kind: kind, reason: kind == .download ? .song : nil, fileExtension: "mp3",
                            downloadsLimit: nil)
    }

    static let lines = Lyrics(synced: true, lines: [LyricLine(start: 1, text: "one"), LyricLine(start: 2, text: "two")])

    @Test func lyrics_keptForDownloadedSongsOnly() async throws {
        let store = await store()
        try await add(store, "d1")
        try await add(store, "c1", kind: .cache)
        #expect(try await store.saveLyrics(OfflineLyrics(songId: "d1", source: .library, lyrics: Self.lines, savedAt: .now)))
        #expect(try await store.saveLyrics(OfflineLyrics(songId: "c1", source: .library, lyrics: Self.lines, savedAt: .now)) == false)
        #expect(try await store.saveLyrics(OfflineLyrics(songId: "nope", source: .library, lyrics: Self.lines, savedAt: .now)) == false)
        #expect(await store.savedLyrics(songId: "d1")?.lyrics == Self.lines)
        #expect(await store.savedLyrics(songId: "d1")?.source == .library)
        #expect(await store.savedLyrics(songId: "c1") == nil)
        #expect(try await store.saveLyrics(OfflineLyrics(songId: "d1", source: .library, lyrics: Self.lines, savedAt: .distantFuture)) == false,
                "the same lines aren't written again")
        // Empty lines are none; an instrumental is kept as the note.
        #expect(try await store.saveLyrics(OfflineLyrics(songId: "d1", source: .online, lyrics: Lyrics(synced: false, lines: []),
                                                         savedAt: .now)) == false)
        #expect(try await store.saveLyrics(OfflineLyrics(songId: "d1", source: .online, lyrics: nil, savedAt: .now)) == false,
                "the library's lyrics are never replaced by ones found online (D311's order)")
        #expect(await store.savedLyrics(songId: "d1")?.source == .library)
        try await add(store, "d2")
        #expect(try await store.saveLyrics(OfflineLyrics(songId: "d2", source: .online, lyrics: nil, savedAt: .now)))
        let instrumental = await store.savedLyrics(songId: "d2")
        #expect(instrumental?.lyrics == nil && instrumental?.source == .online)
        #expect(try await store.saveLyrics(OfflineLyrics(songId: "d2", source: .library, lyrics: Self.lines, savedAt: .now)),
                "the library's replace ones found online")
    }

    @Test func lyrics_boundsApplied() async throws {
        let clock = Clock()
        let store = await store(clock: clock)
        try await add(store, "d1")
        let long = Lyrics(synced: false, lines: (0..<2_500).map { _ in LyricLine(text: String(repeating: "x", count: 900)) })
        #expect(try await store.saveLyrics(OfflineLyrics(songId: "d1", source: .online, lyrics: long, savedAt: .now)) == false,
                "over 512 KB even once bounded: refused")
        let fits = Lyrics(synced: false, lines: (0..<2_500).map { LyricLine(text: "line \($0) " + String(repeating: "y", count: 600)) }
                          .prefix(700).map { $0 })
        #expect(try await store.saveLyrics(OfflineLyrics(songId: "d1", source: .online, lyrics: fits, savedAt: .now)))
        let saved = try #require(await store.savedLyrics(songId: "d1")?.lyrics)
        #expect(saved.lines.allSatisfy { $0.text.count <= OfflineLyrics.maxLineLength })
        let many = Lyrics(synced: false, lines: (0..<2_500).map { LyricLine(text: "\($0)") })
        #expect(OfflineLyrics(songId: "d1", source: .library, lyrics: many, savedAt: .now).lyrics?.lines.count == OfflineLyrics.maxLines)

        // 20 MB in all: the oldest go first (a smaller total here, the rule the same).
        await store.setLyricsTotalLimitForTesting(3_000)
        for id in ["d2", "d3", "d4"] {
            try await add(store, id)
            clock.advance(10)
            let text = Lyrics(synced: false, lines: [LyricLine(text: String(repeating: id, count: 500))])
            try await store.saveLyrics(OfflineLyrics(songId: id, source: .library, lyrics: text, savedAt: clock.now()))
        }
        #expect(await store.savedLyrics(songId: "d4") != nil, "the newest stays")
        #expect(await store.savedLyrics(songId: "d1") == nil, "the oldest went")
    }

    @Test func lyrics_goWithTheSong() async throws {
        let store = await store()
        try await add(store, "d1")
        try await store.saveLyrics(OfflineLyrics(songId: "d1", source: .library, lyrics: Self.lines, savedAt: .now))
        try await store.removeReason(.song, songIds: ["d1"])
        #expect(await store.savedLyrics(songId: "d1") == nil)
        try await add(store, "d1")
        #expect(await store.savedLyrics(songId: "d1") == nil, "downloaded again: nothing stale comes back")
    }

    @Test func lyrics_readAfterRelaunch() async throws {
        let store = await store()
        try await add(store, "d1")
        try await store.saveLyrics(OfflineLyrics(songId: "d1", source: .online, lyrics: Self.lines, savedAt: .now))
        let again = AudioStore(root: tmp, scope: "abc")
        await again.load()
        #expect(await again.savedLyrics(songId: "d1")?.lyrics == Self.lines)
        // A damaged or foreign file reads as none.
        let dir = store.directory.appending(path: "lyrics")
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: dir.path).first)
        try Data("garbage".utf8).write(to: dir.appending(path: name))
        #expect(await again.savedLyrics(songId: "d1") == nil)
    }
}
