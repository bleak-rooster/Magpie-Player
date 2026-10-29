import Foundation
import MagpieCore
import Testing
@testable import Magpie

@Suite struct LyricsTimelineTests {
    let synced = Lyrics(synced: true, lines: [
        LyricLine(start: 1, text: "a"), LyricLine(start: 5, text: "b"), LyricLine(start: 9.5, text: "c"),
    ])

    @Test func highlightsLastStartedLine() {
        #expect(LyricsTimeline.activeIndex(in: synced, at: 0) == nil, "before the first line")
        #expect(LyricsTimeline.activeIndex(in: synced, at: 1) == 0)
        #expect(LyricsTimeline.activeIndex(in: synced, at: 7) == 1)
        #expect(LyricsTimeline.activeIndex(in: synced, at: 9.5) == 2)
        #expect(LyricsTimeline.activeIndex(in: synced, at: 600) == 2)
    }

    @Test func unsyncedHasNoActiveLine() {
        let plain = Lyrics(synced: false, lines: [LyricLine(text: "a"), LyricLine(text: "b")])
        #expect(LyricsTimeline.activeIndex(in: plain, at: 30) == nil)
    }
}

/// T10b fix 1: skipping with lyrics on never flashes an error. A cancelled load's late failure, or a stale song's
/// late answer, doesn't overwrite the new song's lyrics.
@MainActor @Suite struct LyricsLoaderTests {
    /// Holds stale fetches until the test opens it, so their answers land after the new song's.
    @MainActor final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
    }

    /// The song now playing.
    @MainActor final class Now { var id = "s1" }

    static func lyrics(_ id: String) -> Lyrics { Lyrics(synced: false, lines: [LyricLine(text: "words of \(id)")]) }

    static func failures(_ history: [Loadable<Lyrics?>]) -> Int {
        history.filter { if case .failed = $0 { return true } else { return false } }.count
    }

    @Test func quickSkipsEndOnTheNewSongsLyrics() async {
        let loader = LyricsLoader()
        let gate = Gate()
        let now = Now()
        // Stale songs answer late with the error URLSession gives a cancelled request.
        let fetch: (String) async throws -> Lyrics? = { id in
            if id != "s4" { await gate.wait(); throw URLError(.cancelled) }
            return Self.lyrics(id)
        }
        // What `.task(id: song.id)` does on each skip: cancel the old task, start a new one.
        var tasks: [Task<Void, Never>] = []
        for id in ["s1", "s2", "s3", "s4"] {
            tasks.last?.cancel()
            now.id = id
            tasks.append(Task { await loader.load(id, current: { now.id }, fetch: fetch) })
            await Task.yield()
        }
        await tasks.last?.value
        gate.release()
        for task in tasks { await task.value }

        guard case .loaded(let lyrics) = loader.state else {
            Issue.record("expected s4's lyrics, got \(loader.state)"); return
        }
        #expect(lyrics == Self.lyrics("s4"))
        #expect(Self.failures(loader.history) == 0, "a stale failure landed: \(loader.history)")
    }

    @Test func staleAnswerWithoutCancellationIsDropped() async {
        let loader = LyricsLoader()
        let gate = Gate()
        let now = Now()
        let slow = Task { await loader.load("s1", current: { now.id }) { id in await gate.wait(); return Self.lyrics(id) } }
        await Task.yield()
        now.id = "s2"
        await loader.load("s2", current: { now.id }) { _ in nil }   // s2 has no lyrics
        gate.release()
        await slow.value
        guard case .loaded(let lyrics) = loader.state else {
            Issue.record("expected s2's empty state, got \(loader.state)"); return
        }
        #expect(lyrics == nil, "s1's late lyrics replaced s2's")
    }

    @Test func realFailureForTheCurrentSongStillShows() async {
        let loader = LyricsLoader()
        await loader.load("s1", current: { "s1" }) { _ in throw URLError(.timedOut) }
        guard case .failed = loader.state else { Issue.record("expected failed, got \(loader.state)"); return }
    }
}
