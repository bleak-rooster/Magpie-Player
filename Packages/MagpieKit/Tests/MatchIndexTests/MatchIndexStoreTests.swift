import Foundation
import MagpieCore
import os
import Testing
@testable import MatchIndex

@Suite struct MatchIndexStoreTests {
    static func songs(_ n: Int) -> [Song] {
        (0..<n).map { Song(id: String(format: "%05d", $0), title: "Song \($0)", artist: "Artist", album: "A", duration: 100) }
    }

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "MatchIndexStoreTests-\(UUID().uuidString)/index.json")
    }

    @Test func pagesInThousandsUntilTotalThenSavesAndReloads() async throws {
        let all = Self.songs(2345)
        let calls = OSAllocatedUnfairLock(initialState: [Range<Int>]())
        let url = tempURL()
        let store = MatchIndexStore(fileURL: url)
        try await store.refresh { start, end in
            calls.withLock { $0.append(start..<end) }
            return (Array(all[min(start, all.count)..<min(end, all.count)]), all.count)
        }
        #expect(calls.withLock { $0 } == [0..<1000, 1000..<2000, 2000..<3000])
        #expect(await store.index.count == 2345)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let relaunched = MatchIndexStore(fileURL: url)
        #expect(await relaunched.index.count == 0)
        #expect(await relaunched.loadSnapshot())
        #expect(await relaunched.index.count == 2345)
        let probe = ExternalRecording(title: "Song 7", artist: "Artist", duration: 101, source: .listenBrainz)
        #expect(await relaunched.index.match(probe)?.songId == "00007")

        await relaunched.erase()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await relaunched.index.count == 0)
    }

    @Test func failedRefreshKeepsPreviousIndex() async throws {
        let store = MatchIndexStore(fileURL: nil)
        try await store.refresh { _, _ in (Self.songs(3), 3) }
        await #expect(throws: URLError.self) {
            try await store.refresh { start, _ in
                if start > 0 { throw URLError(.timedOut) }
                return (Self.songs(1000), 5000)
            }
        }
        #expect(await store.index.count == 3)
    }

    @Test func damagedSnapshotIsIgnored() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = MatchIndexStore(fileURL: url)
        #expect(await store.loadSnapshot() == false)
        #expect(await store.index.count == 0)
    }

    @Test func snapshotNamePerServerAndUserWithoutLeakingThem() {
        let dir = URL(filePath: "/tmp/x")
        let a = MatchIndexStore.snapshotURL(server: "http://127.0.0.1:4533", user: "jordan", in: dir)
        let b = MatchIndexStore.snapshotURL(server: "http://127.0.0.1:4533", user: "sam", in: dir)
        #expect(a != b)
        #expect(a == MatchIndexStore.snapshotURL(server: "http://127.0.0.1:4533", user: "jordan", in: dir))
        #expect(!a.path.contains("jordan") && !a.path.contains("127.0.0.1"))
        #expect(a.path.hasPrefix("/tmp/x/Magpie/MatchIndex/"))
    }
}
