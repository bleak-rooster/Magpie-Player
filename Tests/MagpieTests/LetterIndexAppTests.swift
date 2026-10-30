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

    func makeList(_ server: Server, pageSize: Int = 50) -> PagedLetterList<String> {
        let titles = Self.titles
        return PagedLetterList(pageSize: pageSize, name: { $0 }, id: { $0 },
            read: { offset in
                server.lock.withLock { server.reads.append(offset) }
                let end = min(offset + pageSize, titles.count)
                return PagedRead(items: Array(titles[min(offset, titles.count)..<end]), next: offset + pageSize,
                                 end: end >= titles.count)
            },
            seek: { letter in
                server.lock.withLock { server.seeks.append(letter) }
                return try await LetterIndex.seek(letter, total: titles.count) { titles.indices.contains($0) ? titles[$0] : nil }
            })
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
}
