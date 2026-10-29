import Foundation
import Testing
import MagpieCore
@testable import Playback

@Suite struct QueueTests {
    static func song(_ id: String) -> Song {
        Song(id: id, title: "T\(id)", artist: "A", album: "B", duration: 200)
    }
    static func songs(_ ids: String...) -> [Song] { ids.map(song) }

    func ids(_ entries: [QueueEntry]) -> [String] { entries.map(\.song.id) }

    /// Task 6.2b: a kept find becomes its library song; every slot holding it is updated in place (same slot ids,
    /// same order, history included). Returns whether a slot changed.
    @Test func replaceSongUpdatesEverySlot() {
        var q = PlayQueue()
        q.replace(with: Self.songs("f", "2", "f"), startAt: 1)
        q.playNext(Self.songs("f"))
        let before = (q.main.map(\.id), q.upNext.map(\.id))
        var kept = Self.song("lib")
        kept.libraryId = 1
        let changed = q.replaceSong(id: "f", with: kept)
        #expect(changed)
        #expect(ids(q.main) == ["lib", "2", "lib"] && ids(q.upNext) == ["lib"])
        #expect(q.main.map(\.id) == before.0 && q.upNext.map(\.id) == before.1)
        #expect(q.current?.song.id == "2")
        let unchanged = q.replaceSong(id: "nope", with: kept)
        #expect(!unchanged)
    }

    /// QC (crash report #1): the count, the next entry and the first few playable ones come without building the
    /// whole upcoming list, and agree with it.
    @Test func upcomingCountAndWindowAgreeWithUpcoming() {
        var q = PlayQueue()
        #expect(q.upcomingCount == 0 && q.nextUp == nil && q.upcoming(limit: 3).isEmpty)
        q.replace(with: Self.songs("1", "2", "3", "4", "5"), startAt: 1)
        q.playNext(Self.songs("x", "y"))
        #expect(q.upcomingCount == 5 && q.upcomingCount == q.upcoming.count)
        #expect(q.nextUp?.song.id == "x")
        #expect(ids(q.upcoming(limit: 3)) == ["x", "y", "3"])
        #expect(ids(q.upcoming(limit: 3, where: { $0.song.id != "y" })) == ["x", "3", "4"])
        #expect(ids(q.upcoming(limit: 10)) == ids(q.upcoming))
        #expect(q.upcoming(limit: 0).isEmpty)
        q.clearUpcoming()
        #expect(q.upcomingCount == 0 && q.nextUp == nil)
    }

    /// QC: the engine gets the current entry plus K: the engine's own enqueue depth or the pre-download count,
    /// whichever is more; 3 by default, never more than 10.
    @Test func engineWindowSize() {
        #expect(EngineWindow.size() == 3)
        #expect(EngineWindow.size(engineMax: 3, preDownload: 6) == 6)
        #expect(EngineWindow.size(engineMax: 3, preDownload: 40) == 10)
        #expect(EngineWindow.size(engineMax: 0, preDownload: 0) == 1)
    }

    @Test func upNextPlaysBeforeMain() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2", "3"), startAt: 0)
        q.playNext(Self.songs("x", "y"))
        #expect(ids(q.upcoming) == ["x", "y", "2", "3"])
        #expect(q.advance()?.song.id == "x")
        #expect(q.advance()?.song.id == "y")
        #expect(q.advance()?.song.id == "2")
        #expect(q.advance()?.song.id == "3")
        #expect(q.advance() == nil)
        #expect(q.current?.song.id == "3")
        #expect(q.upNext.isEmpty)
    }

    @Test func playNextGoesAheadOfEarlierUpNext() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2"), startAt: 0)
        q.playNext(Self.songs("a"))
        q.playNext(Self.songs("b"))
        #expect(ids(q.upcoming) == ["b", "a", "2"])
    }

    @Test func addToEndAppendsAfterMain() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2"), startAt: 0)
        q.playNext(Self.songs("x"))
        q.addToEnd(Self.songs("z"))
        #expect(ids(q.upcoming) == ["x", "2", "z"])
    }

    @Test func addToEmptyQueueStartsIt() {
        var q = PlayQueue()
        q.addToEnd(Self.songs("1", "2"))
        #expect(q.current?.song.id == "1")
        var p = PlayQueue()
        p.playNext(Self.songs("1", "2"))
        #expect(p.current?.song.id == "1")
        #expect(ids(p.upcoming) == ["2"])
    }

    @Test func duplicatesAllowed() {
        var q = PlayQueue()
        let s = Self.song("1")
        q.replace(with: [s, s], startAt: 0)
        q.addToEnd([s])
        q.playNext([s])
        #expect(ids(q.main) == ["1", "1", "1"])
        #expect(ids(q.upcoming) == ["1", "1", "1"])
        let all = q.main + q.upNext
        #expect(Set(all.map(\.id)).count == 4)
    }

    @Test func backReturnsPrevious() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2", "3"), startAt: 1)
        #expect(q.back()?.song.id == "1")
        #expect(q.back() == nil)
        #expect(q.current?.song.id == "1")
        #expect(ids(q.upcoming) == ["2", "3"])
    }

    @Test func backAfterUpNextReturnsToPlayedUpNextEntry() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2"), startAt: 0)
        q.playNext(Self.songs("x"))
        _ = q.advance()   // x
        _ = q.advance()   // 2
        #expect(q.back()?.song.id == "x")
        #expect(q.back()?.song.id == "1")
    }

    @Test func shuffleKeepsCurrentFirst() {
        var q = PlayQueue()
        let all = (1...20).map { Self.song(String($0)) }
        q.replace(with: all, startAt: 7)
        let current = q.current
        q.playNext(Self.songs("x"))
        q.shuffle(seed: 42)
        #expect(q.current == current)
        #expect(q.currentIndex == 0)
        #expect(q.main.first == current)
        #expect(ids(q.upNext) == ["x"])
        #expect(Set(ids(q.main)) == Set(all.map(\.id)))
        #expect(ids(q.main) != all.map(\.id))
        var r = PlayQueue()
        r.replace(with: all, startAt: 7)
        r.shuffle(seed: 42)
        #expect(ids(r.main) == ids(q.main), "same seed, same order")
    }

    /// Task 6.2c: a find let go (Not for me) leaves every slot: history, current, Up Next and the rest. The
    /// current one gives way to what plays next; nothing left means idle.
    @Test func removeSongsTakesEverySlot() {
        var q = PlayQueue()
        q.replace(with: Self.songs("f", "1", "f", "g", "2"), startAt: 2)
        q.playNext(Self.songs("g"))
        let changed = q.removeSongs(["f", "g"])
        #expect(changed)
        #expect(ids(q.main) == ["1", "2"] && q.upNext.isEmpty)
        #expect(q.current?.song.id == "2")
        let none = q.removeSongs(["nope"])
        #expect(!none)

        var only = PlayQueue()
        only.replace(with: Self.songs("f", "f"), startAt: 0)
        let both = only.removeSongs(["f"])
        #expect(both)
        #expect(only.current == nil && only.main.isEmpty)
    }

    @Test func removeCurrentAdvances() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2", "3"), startAt: 1)
        q.remove(id: q.current!.id)
        #expect(q.current?.song.id == "3")
        #expect(ids(q.main) == ["1", "3"])

        q.playNext(Self.songs("x"))
        q.remove(id: q.current!.id)
        #expect(q.current?.song.id == "x", "Up Next comes before the rest of main")
        #expect(q.upNext.isEmpty)

        q.remove(id: q.current!.id)
        #expect(q.current == nil, "nothing left to play")
        #expect(ids(q.main) == ["1"])
    }

    @Test func removeEarlierAndUpcoming() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2", "3"), startAt: 1)
        q.playNext(Self.songs("x"))
        q.remove(id: q.main[0].id)
        #expect(q.current?.song.id == "2")
        #expect(q.currentIndex == 0)
        q.remove(id: q.upNext[0].id)
        #expect(ids(q.upcoming) == ["3"])
    }

    @Test func moveReorders() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2", "3", "4"), startAt: 0)
        let four = q.main[3].id
        q.move(id: four, to: 0)
        #expect(ids(q.upcoming) == ["4", "2", "3"])
        q.move(id: four, to: 2)
        #expect(ids(q.upcoming) == ["2", "3", "4"])

        q.playNext(Self.songs("x"))
        #expect(ids(q.upcoming) == ["x", "2", "3", "4"])
        q.move(id: q.upNext[0].id, to: 3)
        #expect(ids(q.upcoming) == ["2", "3", "4", "x"])
        #expect(q.upNext.isEmpty)
        q.move(id: four, to: 0)
        #expect(ids(q.upcoming) == ["4", "2", "3", "x"])
        #expect(q.current?.song.id == "1")
    }

    @Test func moveIgnoresCurrentAndHistory() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2", "3"), startAt: 1)
        let before = q.main
        q.move(id: q.main[0].id, to: 1)
        q.move(id: q.main[1].id, to: 0)
        #expect(q.main == before)
    }

    @Test func codableRoundTrip() throws {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2"), startAt: 1)
        q.playNext(Self.songs("x"))
        let data = try JSONEncoder().encode(q)
        let back = try JSONDecoder().decode(PlayQueue.self, from: data)
        #expect(back.main == q.main)
        #expect(back.upNext == q.upNext)
        #expect(back.currentIndex == 1)
    }
}

extension QueueTests {
    @Test func clearUpcomingKeepsCurrentAndHistory() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2", "3", "4"), startAt: 1)
        q.playNext(Self.songs("x"))
        q.clearUpcoming()
        #expect(ids(q.main) == ["1", "2"])
        #expect(q.upNext.isEmpty)
        #expect(q.current?.song.id == "2")
        #expect(q.upcoming.isEmpty)
    }

    @Test func clearUpcomingOnIdleQueueIsNoOp() {
        var q = PlayQueue()
        q.clearUpcoming()
        #expect(q.main.isEmpty && q.current == nil)
    }

    @Test func wrapToStartMakesFirstEntryCurrent() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2", "3"), startAt: 2)
        #expect(q.wrapToStart()?.song.id == "1")
        #expect(q.current?.song.id == "1")
        #expect(ids(q.upcoming) == ["2", "3"])
        var empty = PlayQueue()
        #expect(empty.wrapToStart() == nil)
    }

    @Test func restoreOrderUndoesShuffleAndKeepsCurrent() {
        var q = PlayQueue()
        q.replace(with: Self.songs("1", "2", "3", "4", "5"), startAt: 1)
        let original = q.main.map(\.id)
        q.shuffle(seed: 7)
        let currentId = q.current!.id
        q.addToEnd(Self.songs("late"))
        q.restoreOrder(original)
        #expect(ids(q.main) == ["1", "2", "3", "4", "5", "late"], "entries added since go last")
        #expect(q.current?.id == currentId)
        #expect(q.current?.song.id == "2")
    }
}
