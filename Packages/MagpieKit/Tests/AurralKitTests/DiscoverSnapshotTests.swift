import Foundation
import MagpieCore
import Testing
@testable import AurralKit

/// Round 27 D1 (owner, 2026-11-14, items 2 and 3): Discover's saved file, pure (D283–D285). Its model, its bounds, the
/// lookups' lifetimes, the main-library rule and the background pass's order.
@Suite struct DiscoverSnapshotTests {
    private func song(_ id: String, library: Int? = nil) -> Song {
        Song(id: id, title: "Title \(id)", artist: "Low", artistId: "ar-1", album: "A", albumId: "al-1", track: 1,
             duration: 200, suffix: "flac", bitRate: 900, coverArtId: "co-\(id)",
             recordingMBID: MBID("0383dadf-2a4e-4d10-a46a-e9e041da8eb3"), isrcs: ["GBAAA0000001"], libraryId: library)
    }

    private func playlist(_ id: String, songs: Int = 3, changed: Date? = nil) -> Playlist {
        Playlist(id: id, name: "List \(id)", songCount: songs, duration: 600, coverArtId: "pl-\(id)", owner: "jordan",
                 readOnly: false, changed: changed)
    }

    private func page(_ id: String, songs: Int, savedAt: Date, changed: Date? = nil) -> DiscoverSnapshot.Page {
        let list = (0..<songs).map { song("\(id)-s\($0)") }
        return DiscoverSnapshot.Page(playlist: playlist(id, songs: songs, changed: changed), savedAt: savedAt,
                                     entries: list.map { ($0, nil) }, lookups: [:])
    }

    // MARK: - The file's model

    @Test func roundTripsRowsItemsAndPages() throws {
        let flow = AurralFlow(id: "flow-dw", name: "Discover Weekly", ownerUserId: 3, ownerUsername: "jordan")
        var snapshot = DiscoverSnapshot()
        snapshot.rows = [.init(DiscoverPlaylist(flow: flow, playlist: playlist("pl-dw")), shared: false, caption: nil),
                         .init(DiscoverPlaylist(flow: AurralFlow(id: "", name: "Chill", ownerUserId: 2, ownerUsername: "sam"),
                                                playlist: playlist("pl-c")), shared: false, caption: "sam")]
        snapshot.itemRows = [.init(item: .init(AurralFlow(id: "sp-s", name: "Chill", ownerUserId: 2, ownerUsername: "sam"),
                                               kind: .playlist), mine: false)]
        snapshot.hiddenPlaylistIds = ["pl-e1"]
        snapshot.othersPlaylistIds = ["pl-c"]
        let copy = song("m-1", library: 1)
        snapshot.pages["pl-dw"] = DiscoverSnapshot.Page(playlist: playlist("pl-dw"), savedAt: Date(timeIntervalSince1970: 100),
                                                        entries: [(song("a-1", library: 2), copy), (song("a-2"), nil)],
                                                        lookups: ["a-1": .init(copyId: "m-1", at: Date(timeIntervalSince1970: 90))])
        let data = try snapshot.encoded()
        let read = try #require(DiscoverSnapshot.decode(data))
        #expect(read == snapshot.bounded())
        #expect(read.rows.map(\.discoverPlaylist.flow) == [flow, AurralFlow(id: "", name: "Chill", ownerUserId: 2, ownerUsername: "sam")])
        #expect(read.rows.map(\.discoverPlaylist.playlist.id) == ["pl-dw", "pl-c"])
        #expect(read.rows[1].caption == "sam")
        let saved = try #require(read.pages["pl-dw"])
        #expect(saved.songIds == ["a-1", "a-2"])
        #expect(saved.discoverEntries.map(\.song.id) == ["m-1", "a-2"])
        #expect(saved.discoverEntries.map(\.inYourLibrary) == [true, false])
        #expect(saved.discoverEntries[0].song.libraryId == 1)
    }

    /// Only what rows show and ids: no MusicBrainz ids, ISRCs, URLs or anything else a song carries.
    @Test func songsKeepOnlyWhatRowsShow() throws {
        let saved = DiscoverSnapshot.SavedSong(song("a-1", library: 2)).song
        #expect(saved.id == "a-1" && saved.title == "Title a-1" && saved.artist == "Low" && saved.album == "A")
        #expect(saved.coverArtId == "co-a-1" && saved.duration == 200 && saved.libraryId == 2 && saved.suffix == "flac")
        #expect(saved.recordingMBID == nil && saved.isrcs.isEmpty)
        var snapshot = DiscoverSnapshot()
        snapshot.pages["p"] = page("p", songs: 2, savedAt: Date())
        let text = String(decoding: try snapshot.encoded(), as: UTF8.self)
        for banned in ["http", "0383dadf", "GBAAA", "token", "password"] { #expect(!text.contains(banned), "\(banned)") }
    }

    @Test func otherVersionOrTooBigReadsAsNone() throws {
        var snapshot = DiscoverSnapshot()
        snapshot.version = 2
        #expect(DiscoverSnapshot.decode(try JSONEncoder().encode(snapshot)) == nil)
        #expect(DiscoverSnapshot.decode(Data(repeating: 0x20, count: DiscoverSnapshot.maxBytes + 1)) == nil)
        #expect(DiscoverSnapshot.decode(Data("{}".utf8)) == nil)
    }

    // MARK: - Bounds

    @Test func fileBoundsAndTrim() throws {
        var snapshot = DiscoverSnapshot()
        snapshot.rows = (0..<80).map { .init(DiscoverPlaylist(flow: AurralFlow(id: "f\($0)", name: "F"), playlist: playlist("p\($0)")),
                                             shared: false, caption: nil) }
        let start = Date(timeIntervalSince1970: 1_000)
        for i in 0..<70 { snapshot.pages["p\(i)"] = page("p\(i)", songs: 2, savedAt: start.addingTimeInterval(Double(i))) }
        snapshot.pages["big"] = page("big", songs: 700, savedAt: start.addingTimeInterval(500))
        let bounded = snapshot.bounded()
        #expect(bounded.rows.count == DiscoverSnapshot.maxPlaylists)
        #expect(bounded.pages.count == DiscoverSnapshot.maxPlaylists)
        #expect(bounded.pages["big"]?.entries.count == DiscoverSnapshot.maxSongsPerPage)
        #expect(bounded.pages["big"]?.songIds.count == DiscoverSnapshot.maxSongsPerPage)
        #expect(bounded.pages["p0"] == nil && bounded.pages["p10"] == nil, "the oldest pages go first")
        #expect(bounded.pages["p69"] != nil)
    }

    /// Over 4 MB, the oldest pages go until it fits (a file that big would read as none).
    @Test func trimsOldestPageFirstToFitTheSize() throws {
        var snapshot = DiscoverSnapshot()
        let start = Date(timeIntervalSince1970: 1_000)
        for i in 0..<50 { snapshot.pages["p\(i)"] = page("p\(i)", songs: 500, savedAt: start.addingTimeInterval(Double(i))) }
        let data = try snapshot.encoded()
        #expect(data.count <= DiscoverSnapshot.maxBytes)
        let read = try #require(DiscoverSnapshot.decode(data))
        #expect(read.pages.count < 50)
        #expect(read.pages["p49"] != nil && read.pages["p0"] == nil)
        let kept = read.pages.keys.compactMap { Int($0.dropFirst()) }.sorted()
        #expect(kept == Array((50 - kept.count)..<50), "only the newest kept")
    }

    // MARK: - Pages and lookups

    @Test func pageMatchesOnlyTheSameChangeAndSongs() {
        let changed = Date(timeIntervalSince1970: 50)
        let saved = page("p", songs: 2, savedAt: Date(), changed: changed)
        #expect(saved.matches(changed: changed, songIds: ["p-s0", "p-s1"]))
        #expect(!saved.matches(changed: changed.addingTimeInterval(1), songIds: ["p-s0", "p-s1"]))
        #expect(!saved.matches(changed: changed, songIds: ["p-s1", "p-s0"]))
        #expect(page("q", songs: 1, savedAt: Date()).matches(changed: nil, songIds: ["q-s0"]))
    }

    @Test func savedHitKeptWhileIndexHoldsIt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let hit = DiscoverSnapshot.Lookup(copyId: "m-1", at: now.addingTimeInterval(-6 * 24 * 3600))
        #expect(hit.isFresh(now: now, indexHoldsCopy: true))
        #expect(hit.isFresh(now: now, indexHoldsCopy: nil), "no index built: kept")
        #expect(!hit.isFresh(now: now, indexHoldsCopy: false), "the index no longer has it: asked again")
        let old = DiscoverSnapshot.Lookup(copyId: "m-1", at: now.addingTimeInterval(-7 * 24 * 3600 - 1))
        #expect(!old.isFresh(now: now, indexHoldsCopy: true), "after 7 days: asked again")
    }

    @Test func savedMissAskedAgainAfterADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DiscoverSnapshot.Lookup(copyId: nil, at: now.addingTimeInterval(-23 * 3600)).isFresh(now: now, indexHoldsCopy: nil))
        #expect(!DiscoverSnapshot.Lookup(copyId: nil, at: now.addingTimeInterval(-24 * 3600 - 1)).isFresh(now: now, indexHoldsCopy: nil))
        #expect(!DiscoverSnapshot.Lookup(copyId: nil, at: now.addingTimeInterval(60)).isFresh(now: now, indexHoldsCopy: nil),
                "a lookup from the future (the clock moved) is asked again")
    }

    // MARK: - The main library's songs

    @Test func mainLibrarySongNeedsNoLookup() {
        let discoverLibraries: Set<Int> = [2]
        #expect(DiscoverSnapshot.isOwnLibraryCopy(song("m-1", library: 1), discoverLibraries: discoverLibraries, discoverLibrarySongIds: nil))
        #expect(!DiscoverSnapshot.isOwnLibraryCopy(song("a-1", library: 2), discoverLibraries: discoverLibraries, discoverLibrarySongIds: nil))
        // The playlist read doesn't say the library: Aurral's library, as read in full, does.
        #expect(DiscoverSnapshot.isOwnLibraryCopy(song("m-1"), discoverLibraries: discoverLibraries, discoverLibrarySongIds: ["a-1"]))
        #expect(!DiscoverSnapshot.isOwnLibraryCopy(song("a-1"), discoverLibraries: discoverLibraries, discoverLibrarySongIds: ["a-1"]))
        #expect(!DiscoverSnapshot.isOwnLibraryCopy(song("m-1"), discoverLibraries: discoverLibraries, discoverLibrarySongIds: nil),
                "Aurral's library not read in full: looked up")
        #expect(!DiscoverSnapshot.isOwnLibraryCopy(song("m-1", library: 1), discoverLibraries: [], discoverLibrarySongIds: ["a-1"]),
                "Aurral's library not learnt yet: looked up (the lookups are how it is learnt)")
    }

    // MARK: - The background pass

    @Test func backgroundPassOrderAndSkips() {
        let t = { (s: Double) in Date(timeIntervalSince1970: s) }
        let rows = [playlist("old", songs: 2, changed: t(10)), playlist("new", songs: 2, changed: t(30)),
                    playlist("same", songs: 2, changed: t(20)), playlist("never", songs: 2, changed: nil),
                    playlist("grew", songs: 3, changed: t(25))]
        let saved: [String: DiscoverSnapshot.Page] = [
            "same": page("same", songs: 2, savedAt: t(21), changed: t(20)),
            "grew": page("grew", songs: 2, savedAt: t(21), changed: t(25)),
        ]
        #expect(DiscoverSnapshot.pagesToRefresh(rows: rows, saved: saved, limit: 40) == ["new", "grew", "old", "never"])
        #expect(DiscoverSnapshot.pagesToRefresh(rows: rows, saved: saved, limit: 2) == ["new", "grew"])
    }
}
