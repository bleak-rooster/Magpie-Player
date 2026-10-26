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

@Suite struct QueueMoveMathTests {
    @Test func dragDownLandsBeforeTheInsertionPoint() {
        #expect(QueueView.finalPosition(from: 0, insertBefore: 3, offset: 0) == 2)
        #expect(QueueView.finalPosition(from: 2, insertBefore: 0, offset: 0) == 0)
        #expect(QueueView.finalPosition(from: 1, insertBefore: 2, offset: 0) == 1, "no-op drop")
        #expect(QueueView.finalPosition(from: 0, insertBefore: 2, offset: 4) == 5, "second section is offset")
    }
}
