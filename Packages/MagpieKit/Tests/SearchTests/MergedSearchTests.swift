import Foundation
import LidarrKit
import MagpieCore
import MatchIndex
import Testing
@testable import Search

/// A virtual clock: `sleep` suspends until `advance` moves time past its deadline. Cancelled sleeps
/// end at once (throwing), like `Task.sleep`.
final class TestClock: @unchecked Sendable {
    private struct Waiter { let deadline: Duration; let c: CheckedContinuation<Void, Error> }
    private let lock = NSLock()
    private var nowValue: Duration = .zero
    private var waiters: [Int: Waiter] = [:]
    private var cancelled: Set<Int> = []
    private var next = 0

    var now: Duration { lock.withLock { nowValue } }
    var waiting: Int { lock.withLock { waiters.count } }

    func sleep(_ d: Duration) async throws {
        let id = lock.withLock { next += 1; return next }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let early = lock.withLock { () -> Bool in
                    if cancelled.contains(id) { return true }
                    waiters[id] = Waiter(deadline: nowValue + d, c: c)
                    return false
                }
                if early { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let w = lock.withLock { () -> Waiter? in cancelled.insert(id); return waiters.removeValue(forKey: id) }
            w?.c.resume(throwing: CancellationError())
        }
    }

    func advance(by d: Duration) {
        let due = lock.withLock { () -> [Waiter] in
            nowValue += d
            let ready = waiters.filter { $0.value.deadline <= nowValue }
            ready.keys.forEach { waiters.removeValue(forKey: $0) }
            return Array(ready.values)
        }
        due.forEach { $0.c.resume() }
    }

    func until(waiting n: Int) async {
        for _ in 0..<10_000 where waiting != n { await Task.yield() }
    }
}

private let harbourLights = Song(id: "lib-1", title: "Harbour Lights", artist: "Corin Hale", album: "Saltwater Hymns",
                                 duration: 232)

private func ext(_ artist: String, _ title: String, mbid: String? = nil) -> ExternalRecording {
    ExternalRecording(recordingMBID: mbid.flatMap(MBID.init), title: title, artist: artist, source: .listenBrainz)
}

final class EarlyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SearchSections?
    var value: SearchSections? { lock.withLock { stored } }
    func set(_ s: SearchSections) { lock.withLock { stored = s } }
}

@Suite struct MergedSearchTests {
    let clock = TestClock()

    func search(library: LibrarySearchResult, index: MatchIndex = .empty,
                sources: [MergedSearch.Source]) -> MergedSearch {
        let clock = self.clock
        return MergedSearch(library: { _ in library }, sources: sources, index: { index },
                            sleep: { try await clock.sleep($0) })
    }

    @Test func libraryFirst() async {
        let library = LibrarySearchResult(songs: [harbourLights],
                                          artists: [Artist(id: "ar", name: "Corin Hale", albumCount: 1)])
        let lb = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(songs: [ext("Judie Tzuke", "Harbour Lights"), ext("Hollis Gray", "Harbour Bells")])
        }
        let lidarr = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(albums: [NotYetAlbum(title: "Red Room Sessions", artist: "Hollis Gray")],
                         artists: [NotYetArtist(name: "Hollis Gray"), NotYetArtist(name: "Corin Hale")])
        }
        let s = await search(library: library, sources: [lb, lidarr]).run("harbour")
        #expect(s.top == .song(harbourLights), "top result comes from the library when it has anything")
        #expect(s.songs == [harbourLights])
        #expect(s.notYet.songs.map(\.title) == ["Harbour Lights", "Harbour Bells"],
                "same title by another artist is a different song")
        #expect(s.notYet.albums.map(\.title) == ["Red Room Sessions"])
        #expect(s.notYet.artists.map(\.name) == ["Hollis Gray"], "an artist in the library is not 'not yet'")

        // Nothing in the library: still no not-yet top result; the band carries the results.
        let none = await search(library: LibrarySearchResult(), sources: [lb]).run("harbour")
        #expect(none.top == nil)
        #expect(none.libraryIsEmpty && !none.notYet.isEmpty)
    }

    @Test func externalDuplicateDropped() async {
        // In the index (by recording MBID) but not among this search's library rows.
        let tagged = Song(id: "lib-2", title: "Night Ferry", artist: "Corin Hale", album: "Saltwater Hymns",
                          duration: 245, recordingMBID: MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d"))
        let index = MatchIndex(songs: [harbourLights, tagged])
        let lb = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(songs: [
                ext("Corin Hale", "Harbour Lights (Remastered 2011)"),                   // by name, on screen
                ext("Someone", "Renamed", mbid: "c2272a15-8f3a-4cdc-8f32-7e723352d44d"),  // by MBID, in the index
                ext("Ines Morrow", "Harbour Wall"),
                ext("Ines Morrow", "Harbour Wall"),                                        // a second recording
            ])
        }
        let lidarr = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(albums: [NotYetAlbum(title: "Saltwater Hymns", artist: "Corin Hale"),
                                  NotYetAlbum(title: "Fieldnotes", artist: "Ines Morrow")])
        }
        let s = await search(library: LibrarySearchResult(songs: [harbourLights]), index: index,
                             sources: [lb, lidarr]).run("harbour")
        #expect(s.songs == [harbourLights])
        #expect(s.notYet.songs.map(\.title) == ["Harbour Wall"], "library songs and repeats are dropped")
        #expect(s.notYet.albums.map(\.title) == ["Fieldnotes"], "an album the library has is dropped")
    }

    @Test func sourceTimeoutDegrades() async throws {
        let lbNeverAnswers = MergedSearch.Source(timeout: .seconds(5)) { _ in
            // Ignores cancellation on purpose: search must not wait for it.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return ExternalHits()
        }
        let merged = search(library: LibrarySearchResult(songs: [harbourLights]), sources: [lbNeverAnswers])
        let early = EarlyBox()
        let task = Task { try await merged.runReportingLibraryFailure("harbour", libraryFirst: { early.set($0) }) }
        await clock.until(waiting: 1)            // library answered; only LB's 5 s limit is left
        #expect(clock.waiting == 1)
        for _ in 0..<10_000 where early.value == nil { await Task.yield() }
        #expect(early.value?.songs == [harbourLights], "library rows are shown before LB gives up")
        #expect(clock.now == .zero)
        clock.advance(by: .seconds(5))
        let s = try await task.value
        #expect(s.songs == [harbourLights])
        #expect(s.notYet.isEmpty)
        #expect(clock.now <= .milliseconds(5200), "results within 5.2 s")
    }

    @Test func slowLibraryGivesUpAfterThreeSeconds() async throws {
        let clock = self.clock
        let merged = MergedSearch(library: { _ in try await Task.sleep(for: .seconds(3600)); return LibrarySearchResult() },
                                  sources: [], index: { .empty }, sleep: { try await clock.sleep($0) })
        let task = Task { try await merged.runReportingLibraryFailure("harbour") }
        await clock.until(waiting: 1)
        clock.advance(by: .seconds(3))
        await #expect(throws: SearchTimedOut.self) { try await task.value }
    }

    @Test func libraryFailureIsReportedOnlyWhenNothingElseCame() async throws {
        let failing: @Sendable (String) async throws -> LibrarySearchResult = { _ in throw URLError(.cannotConnectToHost) }
        let lb = MergedSearch.Source(timeout: .seconds(5)) { _ in ExternalHits(songs: [ext("Ines Morrow", "Harbour Wall")]) }
        let clock = self.clock
        let alone = MergedSearch(library: failing, sources: [], index: { .empty }, sleep: { try await clock.sleep($0) })
        await #expect(throws: URLError.self) { try await alone.runReportingLibraryFailure("x") }
        #expect(await alone.run("x") == .empty)

        let withLB = MergedSearch(library: failing, sources: [lb], index: { .empty }, sleep: { try await clock.sleep($0) })
        let s = try await withLB.runReportingLibraryFailure("x")
        #expect(s.notYet.songs.count == 1)
    }

    @Test func failingSourceAddsNothing() async {
        let broken = MergedSearch.Source(timeout: .seconds(5)) { _ in throw URLError(.badServerResponse) }
        let s = await search(library: LibrarySearchResult(songs: [harbourLights]), sources: [broken]).run("harbour")
        #expect(s.songs == [harbourLights] && s.notYet.isEmpty)
    }

    @Test func lidarrRowsBecomeNotYetAlbumsAndArtists() throws {
        let mbid = MBID("75ab6ba6-9197-4f83-8a23-a1925a7ec5a2")
        let hits = MergedSearch.Source.hits(from: [
            LidarrSearchHit(kind: .artist, foreignId: mbid, artistName: "Hollis Gray"),
            LidarrSearchHit(kind: .album, foreignId: mbid, artistName: "Hollis Gray", albumTitle: "Red Room Sessions",
                            albumType: "EP", releaseDate: Date(timeIntervalSince1970: 1_700_000_000)),
        ])
        #expect(hits.artists == [NotYetArtist(name: "Hollis Gray", mbid: mbid)])
        let album = try #require(hits.albums.first)
        #expect(album.title == "Red Room Sessions" && album.kind == "EP" && album.year == 2023)
    }
}
