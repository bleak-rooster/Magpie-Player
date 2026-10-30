import Foundation
import MagpieCore
import Search
import Testing
@testable import Magpie

/// P2: the paged letter list over a fake server of 1,000 titles ("a 0" … "j 999", 100 per letter), and the index bar's
/// touch mapping.
@MainActor @Suite struct LetterIndexAppTests {
    /// 100 titles per letter a…j, in the server's order.
    static let titles = (0..<1_000).map { i in "\(Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(i / 100)))) \(i)" }

    final class Server: @unchecked Sendable {
        var reads: [Int] = []
        var seeks: [String] = []
        let lock = NSLock()
    }

    /// `albums`: like Library › Albums (no total: the seek gallops, a short page is the end); else like Songs.
    /// `hold`: the first seek waits until it is released.
    func makeList(_ server: Server, pageSize: Int = 50, albums: Bool = false, hold: Hold? = nil) -> PagedLetterList<String> {
        let titles = Self.titles
        return PagedLetterList(pageSize: pageSize, name: { $0 }, id: { $0 },
            read: { offset in
                server.lock.withLock { server.reads.append(offset) }
                let end = min(offset + pageSize, titles.count)
                let page = Array(titles[min(offset, titles.count)..<max(end, min(offset, titles.count))])
                return PagedRead(items: page, next: offset + pageSize,
                                 end: albums ? page.count < pageSize : end >= titles.count)
            },
            seek: { letter in
                let first = server.lock.withLock { server.seeks.append(letter); return server.seeks.count == 1 }
                if first, let hold { await hold.wait() }
                return try await LetterIndex.seek(letter, total: albums ? nil : titles.count) {
                    titles.indices.contains($0) ? titles[$0] : nil
                }
            })
    }

    /// Holds the first seek until released, and says when it has started.
    actor Hold {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var started = false
        func wait() async {
            started = true
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { released = true; waiters.forEach { $0.resume() }; waiters = [] }
    }

    /// I1: a letter after the last name (no "Z" titles) on a list not loaded to the end never empties it: the last page
    /// shows, scrolled to the last item, and the index stays.
    @Test(arguments: [false, true])
    func aLetterPastTheEndShowsTheLastPage(albums: Bool) async {
        let server = Server()
        let list = makeList(server, albums: albums)
        await list.load()
        await list.jump(to: "Z")
        #expect(list.items.value?.isEmpty == false)
        #expect(list.items.value?.last == "j 999")
        #expect(list.scrollRequest?.id == "j 999")
        #expect(!list.availableLetters.isEmpty, "the index stays")
        #expect(list.windowStart > 0)
    }

    /// I2: letters picked while a seek runs aren't dropped: the latest one wins, one seek at a time.
    @Test func theLatestLetterPickedDuringASeekWins() async {
        let server = Server()
        let hold = Hold()
        let list = makeList(server, hold: hold)
        await list.load()
        let first = Task { await list.jump(to: "D") }
        while !(await hold.started) { await Task.yield() }
        await list.jump(to: "F")   // replaced by H before the seek ends
        await list.jump(to: "H")
        await hold.release()
        await first.value
        #expect(server.seeks == ["D", "H"])
        #expect(list.scrollRequest?.id == "h 700")
        #expect(!list.seeking)
    }

    @Test func aLoadedLetterScrollsWithoutAskingTheServer() async {
        let server = Server()
        let list = makeList(server, pageSize: 300)
        await list.load()
        await list.jump(to: "B")
        #expect(list.scrollRequest?.id == "b 100")
        #expect(server.seeks.isEmpty)
        #expect(server.reads == [0])
    }

    @Test func aNearLetterPagesForward() async {
        let server = Server()
        let list = makeList(server)
        await list.load()
        await list.jump(to: "C")   // offset 200: three pages past the window's end at 50
        #expect(server.seeks == ["C"])
        #expect(list.windowStart == 0)
        #expect(list.windowEnd > 200)
        #expect(list.scrollRequest?.id == "c 200")
    }

    @Test func aFarLetterRestartsTheWindowThereAndCanShowEarlier() async {
        let server = Server()
        let list = makeList(server)
        await list.load()
        await list.jump(to: "H")   // offset 700: far past 50 + 150
        #expect(list.windowStart == 700)
        #expect(list.items.value?.first == "h 700")
        #expect(list.scrollRequest?.id == "h 700")
        #expect(!server.reads.contains(350), "nothing between was read")
        await list.loadEarlier()
        #expect(list.windowStart == 650)
        #expect(list.items.value?.first == "g 650")
        #expect(list.items.value?.count == 100)
        #expect(list.scrollRequest?.id == "h 700", "the row in view stays in view")
        // A letter at the very start of the window isn't trusted: the run may have begun earlier, so it asks again.
        await list.jump(to: "G")
        #expect(server.seeks.last == "G")
        #expect(list.windowStart == 600)
    }

    @Test func aLetterBeforeTheWindowRestartsThere() async {
        let server = Server()
        let list = makeList(server)
        await list.load()
        await list.jump(to: "H")
        await list.jump(to: "B")
        #expect(list.windowStart == 100)
        #expect(list.scrollRequest?.id == "b 100")
    }

    @Test func barMapsTouchToLetters() {
        let h: CGFloat = 270   // 10 pt a letter
        #expect(LetterIndexBar.letter(atY: 0, height: h) == "#")
        #expect(LetterIndexBar.letter(atY: 15, height: h) == "A")
        #expect(LetterIndexBar.letter(atY: 265, height: h) == "Z")
        #expect(LetterIndexBar.letter(atY: -40, height: h) == "#")
        #expect(LetterIndexBar.letter(atY: 900, height: h) == "Z")
        #expect(LetterIndexBar.letter(atY: .nan, height: h) == "#")
        #expect(LetterIndexBar.letter(atY: 10, height: 0) == "#")
    }

    @Test func artistsSortAsNavidromeDoes() {
        let artists = ["The Midnight Cartographers", "Static Choir", "Aurora Field", "Éléonore Brûlé", "坂本光"]
            .enumerated().map { Artist(id: "\($0.offset)", name: $0.element, albumCount: 1) }
        #expect(ArtistsListView.sorted(artists).map(\.name)
                == ["Aurora Field", "Éléonore Brûlé", "The Midnight Cartographers", "Static Choir", "坂本光"])
    }

    /// N3: a pick during a jump joins it (no second task), and cancelling the one task (the screen closing) stops it.
    @Test func aJumpIsOneCancellableTask() async {
        let server = Server()
        let hold = Hold()
        let list = makeList(server, hold: hold)
        await list.load()
        let task = list.startJump(to: "D")
        #expect(task != nil && list.seeking)
        #expect(list.startJump(to: "H") == nil, "joins the running jump")
        while !(await hold.started) { await Task.yield() }
        task?.cancel()
        await hold.release()
        await task?.value
        #expect(server.seeks == ["D"], "cancelled: H never runs")
        #expect(!list.seeking)
        #expect(list.windowStart == 0, "nothing applied after the cancel")
    }
}
