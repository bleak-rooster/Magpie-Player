import CoreGraphics
import Foundation
import MagpieCore
import MagpieTestSupport
import os
import Testing

/// B1 fix round (review): covers deep in the queue still load (the time limit starts with the fetch, not the wait), a
/// page on screen goes before a background prefetch, Aurral's catalog cover is the last source, the disk copy is bounded
/// in bytes and least-recently-used, a sign-out stops loads already in flight from writing, and the shared helpers
/// (`Deadline`, `KeyedGather`) answer by key.
@MainActor @Suite struct B1FixRoundTests {
    static let rg = OutsideArtTests.rg
    let dir = FileManager.default.temporaryDirectory.appending(path: "B1FixRound-\(UUID().uuidString)")

    func ids(_ n: Int) -> [MBID] { (0..<n).map { MBID(String(format: "%08d-2222-4222-8222-222222222222", $0))! } }

    /// Review 2: 20 covers, four at a time, each fetch 1 s, a 3 s limit per step: all 20 fill (the queue wait never
    /// counts against the limit).
    @Test func coversDeepInTheQueueStillLoad() async {
        let slow = SlowArtTransport(delay: .seconds(1))
        let art = OutsideArtLoader(transport: slow, userAgent: OutsideArtTests.ua, artistImage: nil, isOffline: { false },
                                   disk: OutsideArtDiskCache(directory: dir), limiter: AsyncLimiter(limit: 4),
                                   stepTimeout: .seconds(3))
        let keys = ids(20).map(OutsideArtKey.releaseGroup)
        await art.prefetch(keys, priority: .visible)
        var filled = 0
        for key in keys where art.peek(key) != nil { filled += 1 }
        #expect(filled == 20, "every cover fills: \(filled)/20")
        #expect(slow.peak <= 4)
    }

    /// Review 2: a page on screen is never starved by a background prefetch: its picture goes next.
    @Test func aVisiblePageGoesBeforeABackgroundPrefetch() async {
        let slow = SlowArtTransport(delay: .milliseconds(150))
        let limiter = AsyncLimiter(limit: 1)
        let background = OutsideArtLoader(transport: slow, userAgent: OutsideArtTests.ua, artistImage: nil,
                                          isOffline: { false }, limiter: limiter)
        let page = OutsideArtLoader(transport: slow, userAgent: OutsideArtTests.ua, artistImage: nil,
                                    isOffline: { false }, limiter: limiter)
        let queued = ids(10).map(OutsideArtKey.releaseGroup)
        let prefetch = Task { await background.prefetch(queued, priority: .background) }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        #expect(await page.image(.release(OutsideArtTests.release)) != nil)
        #expect(ContinuousClock.now - start < .seconds(1), "the page's cover waited for at most the one in flight")
        prefetch.cancel()
        await prefetch.value
    }

    /// Review 1 (D125): after the release group, its releases and Lidarr, a cover Aurral's catalog names fills it;
    /// without the album's name nothing is asked of Aurral.
    @Test func aurralsCatalogCoverIsTheLastSource() async {
        let t = MockTransport()   // every Cover Art Archive answer 404s
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let covers = OutsideCoverFallbacks(releases: { _ in [] }, lidarrCover: { _ in nil },
                                           aurralCover: { _, hint in asked.withLock { $0.append(hint.title) }; return b1png() })
        let art = OutsideArtLoader(transport: t, userAgent: OutsideArtTests.ua, artistImage: nil, isOffline: { false },
                                   covers: covers)
        #expect(await art.image(.releaseGroup(Self.rg)) == nil, "no name: Aurral isn't asked")
        #expect(asked.withLock { $0 }.isEmpty)
        art.note(Self.rg, OutsideAlbumHint(title: "Roads to the North", artist: "Panopticon"))
        #expect(await art.image(.releaseGroup(Self.rg)) != nil)
        #expect(asked.withLock { $0 } == ["Roads to the North"])
    }

    /// Review 5: bounded in bytes; a picture read recently stays while older ones go.
    @Test func theDiskCopyIsBoundedInBytesAndLeastRecentlyUsedGoesFirst() throws {
        let item = Data(repeating: 7, count: 10_000)
        let disk = OutsideArtDiskCache(directory: dir, maxFiles: 1000, maxBytes: 50_000)
        let keys = ids(4).map(OutsideArtKey.artist)
        for key in keys { disk.save(item, for: key) }
        let old = Date(timeIntervalSinceNow: -3600)
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }
        #expect(disk.data(for: keys[0]) != nil, "read: now the most recently used")
        for key in ids(6).dropFirst(4).map(OutsideArtKey.artist) { disk.save(item, for: key) }
        #expect(disk.totalBytes <= 50_000)
        #expect(disk.data(for: keys[0]) != nil, "the one in use stays")
        #expect(disk.data(for: keys[1]) == nil, "an old one went")
    }

    /// Review minor 1: after sign-out clears the folder, a cache made before it never writes again.
    @Test func aLoadInFlightAtSignOutNeverWritesAgain() {
        let before = OutsideArtDiskCache(directory: dir)
        before.save(Data([1, 2, 3]), for: .artist(ids(1)[0]))
        OutsideArtDiskCache(directory: dir).removeAll()
        before.save(Data([1, 2, 3]), for: .artist(ids(2)[1]))
        #expect(!FileManager.default.fileExists(atPath: dir.path), "the folder isn't made again")
        let after = OutsideArtDiskCache(directory: dir)
        after.save(Data([1, 2, 3]), for: .artist(ids(3)[2]))
        #expect(after.count == 1, "the next account's cache works")
    }

    @Test func deadlineAnswersInTimeAndCutsOffASilentSource() async {
        #expect((try? await Deadline.run(.seconds(5)) { 7 }.get()) == 7)
        let silent = await Deadline.run(.milliseconds(50)) { () async throws -> Int in
            try await Task.sleep(for: .seconds(600))
            return 1
        }
        if case .failure(let error) = silent { #expect(error is Deadline.Exceeded) } else { Issue.record("no deadline") }
    }

    /// Review 4 (D120): answers come back by key, whatever order they finish in, in Release too.
    @Test func keyedGatherAnswersByKey() async throws {
        let keys = (0..<12).map { "k\($0)" }
        let got = try await KeyedGather.inOrder(keys, width: 4) { key -> String in
            try await Task.sleep(for: .milliseconds(5 * (12 - Int(key.dropFirst())!)))
            return key.uppercased()
        }
        #expect(got == keys.map { $0.uppercased() })
    }
}

/// D120's minimal repro: the shape the optimised build mishandled. In Debug it is right; in Release (`swift test -c
/// release -Xswiftc -enable-testing`, `scripts/test-app.sh --release`) the position is lost and every answer lands on
/// position 0. Recorded as a known issue there, so the suite stays green while the repro stays checked in.
@Suite struct D120ReproTests {
    static func badShape(_ n: Int) async -> [Int?] {
        await withTaskGroup(of: (Int, Result<Int, any Error>).self) { group in
            for index in 0..<n {
                group.addTask {
                    do { return (index, .success(try await Self.work(index, of: n))) } catch { return (index, .failure(error)) }
                }
            }
            var results = [Int?](repeating: nil, count: n)
            for await (index, result) in group where results.indices.contains(index) { results[index] = try? result.get() }
            return results
        }
    }

    static func work(_ index: Int, of n: Int) async throws -> Int {
        try await Task.sleep(for: .milliseconds(5 * (n - index)))
        return index * 10
    }

    @Test func theMiscompiledShape() async {
        let got = await Self.badShape(5)
        let want: [Int?] = [0, 10, 20, 30, 40]
        #if DEBUG
        #expect(got == want)
        #else
        withKnownIssue("D120: Release loses the index paired with an inline try await", isIntermittent: true) {
            #expect(got == want)
        }
        #endif
    }
}
