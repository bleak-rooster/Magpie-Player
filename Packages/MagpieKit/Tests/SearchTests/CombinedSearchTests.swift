import AurralKit
import Foundation
import ListenBrainzKit
import MagpieCore
import MagpieTestSupport
import MatchIndex
import Testing
@testable import Search

/// Round 14 A5 (owner answer 5, D95–D99): combined search. Songs = the library first, then the songs on the albums
/// Lidarr's search returns (tracklists from MusicBrainz) whose title matches; ListenBrainz only when Lidarr has no
/// album hit. Artists and albums = Aurral's paged search merged with Lidarr's, de-duplicated by MBID; each source on its
/// own, and the band pages (Load more) for outside rows too.

private func mb(_ n: Int, _ kind: Int = 1) -> MBID {
    MBID(String(format: "00000000-0000-4000-%04d-%012d", 8000 + kind, n))!
}

private func album(_ title: String, by artist: String, _ n: Int, artistMBID: MBID? = nil) -> NotYetAlbum {
    NotYetAlbum(title: title, artist: artist, mbid: mb(n, 2), artistMBID: artistMBID ?? mb(n, 3), kind: "Album")
}

private func release(_ group: Int, _ tracks: [(String, Int, TimeInterval?)]) -> MBReleaseDetail {
    MBReleaseDetail(id: mb(group, 4), title: "Release \(group)", date: "2010", status: "Official",
                    tracks: tracks.map { MBTrack(recording: mb($0.1, 5), title: $0.0, length: $0.2) })
}

/// Counts calls (thread-safe).
final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.withLock { list.append(s) } }
    var all: [String] { lock.withLock { list } }
    func count(_ prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }
}

private let never: MergedSearch.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }

@Suite struct TracklistMatchTests {
    @Test func titleMatchesTheTermOrTheTermWithoutTheArtist() {
        #expect(TracklistSongs.matches(title: "Bloodbuzz Ohio", query: "bloodbuzz", artist: "The National"))
        #expect(TracklistSongs.matches(title: "Bloodbuzz Ohio", query: "Bloodbuzz Ohio", artist: "The National"))
        #expect(TracklistSongs.matches(title: "Bloodbuzz Ohio", query: "the national bloodbuzz", artist: "The National"))
        #expect(TracklistSongs.matches(title: "Bloodbuzz Ohio", query: "bloodbuzz ohio the national", artist: "The National"))
        #expect(TracklistSongs.matches(title: "Fake Empire (Live)", query: "fake empire", artist: "The National"))
    }

    @Test func noMatchOnPartsOfWordsOrTheArtistAlone() {
        #expect(!TracklistSongs.matches(title: "Bloodbuzz Ohio", query: "blood", artist: "The National"), "whole words only")
        #expect(!TracklistSongs.matches(title: "Fake Empire", query: "the national", artist: "The National"),
                "the artist alone matches every song: none")
        #expect(!TracklistSongs.matches(title: "Fake Empire", query: "", artist: "The National"))
        #expect(!TracklistSongs.matches(title: "Fake Empire", query: "empire state", artist: "The National"))
    }

    @Test func albumsToReadHaveMBIDsComeBestFirstAndAreCapped() {
        let albums = (0..<20).map { album("Album \($0)", by: "Someone", $0) }
            + [NotYetAlbum(title: "No id", artist: "Someone")]
        let picked = TracklistSongs.candidates(albums, query: "album 7")
        #expect(picked.count == TracklistSongs.maxAlbums)
        #expect(picked.first?.title == "Album 7")
        #expect(!picked.contains { $0.mbid == nil })
    }
}

@Suite struct TracklistReadTests {
    @Test func readsTracklistsKeepingMatchingSongsWithMBIDs() async {
        let calls = Calls()
        let reader = TracklistSongs(release: { group in
            calls.add("mb \(group.rawValue)")
            return group == mb(1, 2) ? release(1, [("Bloodbuzz Ohio", 10, 276), ("Terrible Love", 11, 280)])
                : release(2, [("Bloodbuzz Ohio (Live)", 12, 290)])
        }, sleep: never)
        let albums = [album("High Violet", by: "The National", 1), album("Live at Brixton", by: "The National", 2)]
        let read = await reader.read(query: "bloodbuzz", albums: albums)
        #expect(read.songs.map(\.title) == ["Bloodbuzz Ohio", "Bloodbuzz Ohio (Live)"])
        #expect(read.songs.first?.recordingMBID == mb(10, 5))
        #expect(read.songs.first?.artist == "The National")
        #expect(read.songs.first?.releaseTitle == "Release 1")
        #expect(read.songs.first?.duration == 276)
        #expect(read.unread.isEmpty)
        #expect(calls.count("mb") == 2)
    }

    @Test func readsAtMostAPageOfAlbumsAndLeavesTheRestForMore() async {
        let calls = Calls()
        let reader = TracklistSongs(release: { group in calls.add("mb"); return release(9, [("Song", 1, 100)]) },
                                    sleep: never)
        let albums = (0..<5).map { album("A\($0)", by: "X", $0) }
        let read = await reader.read(query: "song", albums: albums)
        #expect(calls.count("mb") == TracklistSongs.albumsPerRead)
        #expect(read.unread.map(\.title) == ["A3", "A4"])
    }

    @Test func aSlowMusicBrainzKeepsWhatCameAndLeavesTheRest() async {
        let clock = TestClock()
        let gate = AsyncGate()
        let reader = TracklistSongs(release: { group in
            if group == mb(2, 2) { await gate.wait() }   // the second album hangs
            return release(1, [("Song", 1, 100)])
        }, budget: .seconds(4), sleep: { try await clock.sleep($0) })
        let albums = (1...3).map { album("A\($0)", by: "X", $0) }
        async let read = reader.read(query: "song", albums: albums)
        await clock.until(waiting: 1)
        for _ in 0..<200 { await Task.yield() }
        clock.advance(by: .seconds(4))
        let got = await read
        #expect(got.songs.count == 1, "the first album's song")
        #expect(got.unread.map(\.title) == ["A2", "A3"], "the one in flight is read again on More")
        gate.open()
    }

    @Test func aFailingAlbumIsSkipped() async {
        let reader = TracklistSongs(release: { group in
            if group == mb(1, 2) { throw MusicBrainzError.http(status: 503) }
            return release(2, [("Song", 2, 100)])
        }, sleep: never)
        let read = await reader.read(query: "song", albums: [album("A1", by: "X", 1), album("A2", by: "X", 2)])
        #expect(read.songs.map(\.recordingMBID) == [mb(2, 5)])
    }
}

/// A gate a fake source waits at until the test opens it.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { c in
            let now = lock.withLock { () -> Bool in if isOpen { return true }; waiters.append(c); return false }
            if now { c.resume() }
        }
    }
    func open() {
        let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in isOpen = true; defer { waiters = [] }; return waiters }
        w.forEach { $0.resume() }
    }
}

@Suite struct CombinedSongsSourceTests {
    func lidarr(_ albums: [NotYetAlbum], artists: [NotYetArtist] = [], calls: Calls, fail: Bool = false) -> SharedOutsideSearch {
        SharedOutsideSearch(timeout: .seconds(5), sleep: never) { q in
            calls.add("lidarr \(q)")
            if fail { throw URLError(.timedOut) }
            return ExternalHits(albums: albums, artists: artists)
        }
    }

    @Test func lidarrIsAskedOnceForBothItsRowsAndTheSongs() async throws {
        let calls = Calls()
        let shared = lidarr([album("High Violet", by: "The National", 1)], calls: calls)
        let reader = TracklistSongs(release: { _ in release(1, [("Bloodbuzz Ohio", 10, 276)]) }, sleep: never)
        let songs = MergedSearch.Source.songs(lidarr: shared, tracklists: reader, backup: { _ in calls.add("lb"); return [] })
        let rows = MergedSearch.Source.lidarr(shared)
        async let a = songs.fetch("bloodbuzz")
        async let b = rows.fetch("bloodbuzz")
        let (s, r) = try await (a, b)
        #expect(s.songs.map(\.title) == ["Bloodbuzz Ohio"])
        #expect(r.albums.map(\.title) == ["High Violet"])
        #expect(calls.count("lidarr") == 1)
        #expect(calls.count("lb") == 0, "ListenBrainz only when Lidarr has no album hit")
    }

    @Test func listenBrainzIsTheBackupWhenLidarrHasNoAlbum() async throws {
        let calls = Calls()
        let backup: MergedSearch.SongSearch = { _ in
            calls.add("lb")
            return [ExternalRecording(recordingMBID: mb(1, 6), title: "Harbour Wall", artist: "Ines Morrow", source: .listenBrainz)]
        }
        let reader = TracklistSongs(release: { _ in calls.add("mb"); return nil }, sleep: never)
        let none = MergedSearch.Source.songs(lidarr: lidarr([], artists: [NotYetArtist(name: "Ines Morrow")], calls: calls),
                                             tracklists: reader, backup: backup)
        #expect(try await none.fetch("harbour").songs.map(\.title) == ["Harbour Wall"])
        let failing = MergedSearch.Source.songs(lidarr: lidarr([album("A", by: "B", 1)], calls: calls, fail: true),
                                                tracklists: reader, backup: backup)
        #expect(try await failing.fetch("harbour").songs.map(\.title) == ["Harbour Wall"], "a failed Lidarr has no album hit")
        #expect(calls.count("lb") == 2)
        #expect(calls.count("mb") == 0)
    }

    @Test func noBackupMeansNoSongs() async throws {
        let calls = Calls()
        let reader = TracklistSongs(release: { _ in nil }, sleep: never)
        let s = MergedSearch.Source.songs(lidarr: lidarr([], calls: calls), tracklists: reader, backup: nil)
        #expect(try await s.fetch("x").songs.isEmpty)
    }

    @Test func unreadAlbumsAreKeptForMore() async throws {
        let calls = Calls()
        let albums = (1...5).map { album("Song \($0)", by: "X", $0) }
        let reader = TracklistSongs(release: { _ in release(1, [("Song", 1, 100)]) }, sleep: never)
        let s = MergedSearch.Source.songs(lidarr: lidarr(albums, calls: calls), tracklists: reader, backup: nil)
        let hits = try await s.fetch("song")
        #expect(hits.cursor.unreadAlbums.count == 2)
    }
}

@Suite struct CombinedMergeTests {
    let harbour = Song(id: "lib-1", title: "Harbour Lights", artist: "Corin Hale", album: "Saltwater Hymns", duration: 232,
                       recordingMBID: mb(1, 5))
    let ohio = Song(id: "lib-2", title: "Bloodbuzz Ohio", artist: "The National", album: "High Violet", duration: 276)

    func tracklist(_ title: String, _ artist: String, _ n: Int, duration: TimeInterval? = 200) -> ExternalRecording {
        ExternalRecording(recordingMBID: mb(n, 5), title: title, artist: artist, releaseTitle: "R", duration: duration,
                          source: .lidarr, releaseMBID: mb(n, 4))
    }

    @Test func songsAreDeduplicatedByRecordingMBID() {
        let a = tracklist("Bloodbuzz Ohio", "The National", 10)
        var b = a; b.releaseTitle = "Another release"; b.title = "Bloodbuzz Ohio (2010)"
        let lb = ExternalRecording(recordingMBID: mb(10, 5), title: "bloodbuzz ohio", artist: "national", source: .listenBrainz)
        let s = MergedSearch.merge(query: "bloodbuzz", library: LibrarySearchResult(),
                                   outside: [ExternalHits(songs: [a, b]), ExternalHits(songs: [lb])], index: .empty)
        #expect(s.notYet.songs.count == 1)
    }

    @Test func aTracklistSongTheLibraryHasIsInYourLibrary() {
        // By recording MBID, and by artist + title + duration; the one already a library row is not repeated.
        let byMBID = tracklist("Harbour Lights", "Corin Hale", 1, duration: nil)
        let byDuration = tracklist("Bloodbuzz Ohio", "The National", 10, duration: 277)
        let index = MatchIndex(songs: [harbour, ohio])
        let s = MergedSearch.merge(query: "x", library: LibrarySearchResult(songs: [harbour]),
                                   outside: [ExternalHits(songs: [byMBID, byDuration])], index: index)
        #expect(s.notYet.songs.isEmpty)
        #expect(s.notYet.owned.map(\.songId) == ["lib-2"], "Harbour Lights is already a library row")
        #expect(s.notYet.owned.first?.recording.title == "Bloodbuzz Ohio")
    }

    @Test func neverInYourLibraryByNameAlone() {
        let unknownLength = Song(id: "lib-3", title: "Fake Empire", artist: "The National", album: "Boxer", duration: 0)
        let apart = tracklist("Bloodbuzz Ohio", "The National", 10, duration: 400)
        let noDuration = tracklist("Fake Empire", "The National", 11, duration: nil)
        let s = MergedSearch.merge(query: "x", library: LibrarySearchResult(),
                                   outside: [ExternalHits(songs: [apart, noDuration])],
                                   index: MatchIndex(songs: [ohio, unknownLength]))
        #expect(s.notYet.owned.isEmpty)
        #expect(Set(s.notYet.songs.map(\.title)) == ["Bloodbuzz Ohio", "Fake Empire"])
    }

    @Test func aurralAndLidarrArtistsAndAlbumsMergeByMBID() {
        let aurral = ExternalHits(albums: [NotYetAlbum(title: "Wide Open", artist: "Stub Arrows", mbid: mb(1, 2)),
                                           NotYetAlbum(title: "Low", artist: "Stub Arrows", mbid: mb(2, 2))],
                                  artists: [NotYetArtist(name: "Stub Arrows", mbid: mb(1, 3))])
        let lidarr = ExternalHits(albums: [NotYetAlbum(title: "Wide Open (Deluxe)", artist: "Stub Arrows", mbid: mb(1, 2)),
                                           NotYetAlbum(title: "Third", artist: "Stub Arrows", mbid: mb(3, 2))],
                                  artists: [NotYetArtist(name: "Stub  Arrows", mbid: mb(1, 3)),
                                            NotYetArtist(name: "Other", mbid: mb(2, 3))])
        let s = MergedSearch.merge(query: "stub arrows", library: LibrarySearchResult(), outside: [aurral, lidarr],
                                   index: .empty)
        #expect(s.notYet.albums.count == 3)
        #expect(s.notYet.artists.count == 2)
    }

    @Test func outsideRowsBeyondThePageWaitForMore() {
        let artists = (0..<12).map { NotYetArtist(name: "Arrow \($0)", mbid: mb($0, 3)) }
        let s = MergedSearch.merge(query: "arrow", library: LibrarySearchResult(), outside: [ExternalHits(artists: artists)],
                                   index: .empty)
        #expect(s.notYet.artists.count == MergedSearch.limits.artists)
        #expect(s.hasMoreOutside(.artists))
        #expect(!s.hasMoreOutside(.albums))
        #expect(!s.hasMoreOutside(.songs))
    }
}

@Suite struct CombinedRunTests {
    let clock = TestClock()

    func search(_ sources: [MergedSearch.Source], more: MergedSearch.OutsideMore = .init()) -> MergedSearch {
        let clock = self.clock
        return MergedSearch(library: { _ in LibrarySearchResult() }, sources: sources, outsideMore: more, index: { .empty },
                            sleep: { try await clock.sleep($0) })
    }

    @Test func aFailingSourceNeverHidesTheOther() async throws {
        let aurral = MergedSearch.Source(timeout: .seconds(5)) { _ in throw URLError(.cannotConnectToHost) }
        let lidarr = MergedSearch.Source(timeout: .seconds(5)) { _ in ExternalHits(artists: [NotYetArtist(name: "Ines Morrow")]) }
        let s = try await search([aurral, lidarr]).runReportingLibraryFailure("ines")
        #expect(s.notYet.artists.map(\.name) == ["Ines Morrow"])
        let s2 = try await search([lidarr, aurral]).runReportingLibraryFailure("ines")
        #expect(s2.notYet.artists.map(\.name) == ["Ines Morrow"])
    }

    @Test func aSlowSourceDoesntHoldTheOthersRowsBack() async throws {
        let gate = AsyncGate()
        let slow = MergedSearch.Source(timeout: .seconds(5)) { _ in
            await gate.wait()
            return ExternalHits(artists: [NotYetArtist(name: "Slow Artist", mbid: mb(1, 3))])
        }
        let fast = MergedSearch.Source(timeout: .seconds(5)) { _ in ExternalHits(artists: [NotYetArtist(name: "Fast Artist", mbid: mb(2, 3))]) }
        let updates = UpdateBox()
        async let done = search([slow, fast]).runReportingLibraryFailure("artist") { updates.add($0) }
        for _ in 0..<2_000 where !updates.all.contains(where: { $0.notYet.artists.map(\.name) == ["Fast Artist"] }) {
            await Task.yield()
        }
        #expect(updates.all.contains { $0.notYet.artists.map(\.name) == ["Fast Artist"] },
                "the fast source's rows show while the slow one is out")
        await clock.until(waiting: 1)
        clock.advance(by: .seconds(5))   // the slow source runs out of time
        let final = try await done
        #expect(final.notYet.artists.map(\.name) == ["Fast Artist"])
        gate.open()
    }

    @Test func moreArtistsComeFromTheQueueThenAurralsNextPage() async throws {
        let calls = Calls()
        let more = MergedSearch.OutsideMore(artists: { q, offset in
            calls.add("aurral \(offset)")
            return (items: (offset..<offset + 3).map { NotYetArtist(name: "Arrow \($0)", mbid: mb($0, 3)) }, next: nil)
        })
        let first = (0..<7).map { NotYetArtist(name: "Arrow \($0)", mbid: mb($0, 3)) }
        let source = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(artists: first, cursor: OutsideCursor(aurralArtistsOffset: 7))
        }
        let search = search([source], more: more)
        var s = try await search.runReportingLibraryFailure("arrow")
        #expect(s.notYet.artists.count == 5)
        let page = try await search.moreOutside(.artists, in: s)
        s.append(page)
        #expect(s.notYet.artists.map(\.name) == (0..<10).map { "Arrow \($0)" }, "two from the queue, three from Aurral")
        #expect(calls.all == ["aurral 7"])
        #expect(!s.hasMoreOutside(.artists))
    }

    @Test func moreSongsReadTheNextAlbums() async throws {
        let calls = Calls()
        let reader = TracklistSongs(release: { group in
            calls.add("mb")
            return MBReleaseDetail(id: group, title: "R", date: nil, status: "Official",
                                   tracks: [MBTrack(recording: group, title: "Song " + group.rawValue.suffix(2), length: 100)])
        }, sleep: never)
        let source = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(cursor: OutsideCursor(unreadAlbums: (1...4).map { album("A\($0)", by: "X", $0) }))
        }
        let search = search([source], more: MergedSearch.OutsideMore(tracklists: reader))
        var s = try await search.runReportingLibraryFailure("song")
        #expect(s.hasMoreOutside(.songs))
        s.append(try await search.moreOutside(.songs, in: s))
        #expect(s.notYet.songs.count == 3)
        #expect(s.hasMoreOutside(.songs))
        s.append(try await search.moreOutside(.songs, in: s))
        #expect(s.notYet.songs.count == 4)
        #expect(!s.hasMoreOutside(.songs))
        #expect(calls.count("mb") == 4)
    }

    @Test func aFailedMorePageThrowsAndKeepsTheOffset() async throws {
        let more = MergedSearch.OutsideMore(albums: { _, _ in throw URLError(.cannotConnectToHost) })
        let source = MergedSearch.Source(timeout: .seconds(5)) { _ in ExternalHits(cursor: OutsideCursor(aurralAlbumsOffset: 24)) }
        let search = search([source], more: more)
        let s = try await search.runReportingLibraryFailure("x")
        await #expect(throws: (any Error).self) { try await search.moreOutside(.albums, in: s) }
        #expect(s.hasMoreOutside(.albums))
    }

    @Test func aMorePageForOneKindLeavesTheOthersPagingAlone() async throws {
        let more = MergedSearch.OutsideMore(artists: { _, _ in ([NotYetArtist(name: "Late", mbid: mb(99, 3))], nil) })
        let source = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(albums: (0..<10).map { NotYetAlbum(title: "Album \($0)", artist: "X", mbid: mb($0, 2)) },
                         cursor: OutsideCursor(aurralArtistsOffset: 0, aurralAlbumsOffset: 10))
        }
        let search = search([source], more: more)
        var s = try await search.runReportingLibraryFailure("album")
        let albumsBefore = s.outside
        s.append(try await search.moreOutside(.artists, in: s))
        #expect(s.notYet.artists.map(\.name) == ["Late"])
        #expect(s.hasMoreOutside(.albums))
        #expect(s.outside?.queued.albums == albumsBefore?.queued.albums)
        #expect(s.outside?.cursor.aurralAlbumsOffset == 10)
    }
}

final class UpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SearchSections] = []
    func add(_ s: SearchSections) { lock.withLock { list.append(s) } }
    var all: [SearchSections] { lock.withLock { list } }
}

/// The Aurral source over the in-process stub (2.13): artists and albums with MBIDs, and its offset for Load more.
@Suite struct AurralSearchSourceTests {
    func client() async throws -> (StubAurral, AurralClient) {
        let stub = StubAurral()
        stub.useAurral213()
        return (stub, AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub))
    }

    @Test func firstPageOfArtistsAndAlbumsWithTheNextOffsets() async throws {
        let (stub, client) = try await client()
        let hits = try await MergedSearch.Source.aurral(client).fetch("arrows")
        #expect(hits.artists.count == 24)
        #expect(hits.albums.count == 24)
        #expect(hits.albums.first?.mbid != nil)
        #expect(hits.albums.first?.artistMBID != nil)
        #expect(hits.cursor.aurralArtistsOffset == 24)
        #expect(hits.cursor.aurralAlbumsOffset == 24)
        let paths = stub.requests.compactMap(\.url).filter { $0.path == "/api/search" }
        #expect(paths.count == 2)
    }

    @Test func morePagesUntilAurralSaysThereIsNoMore() async throws {
        let (_, client) = try await client()
        let more = MergedSearch.OutsideMore.aurral(client)
        let page = try #require(try await more.albums?("arrows", 24))
        #expect(page.items.count == 6)
        #expect(page.next == nil)
    }
}
