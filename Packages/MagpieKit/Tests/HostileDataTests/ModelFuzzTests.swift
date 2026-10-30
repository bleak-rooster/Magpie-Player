import Foundation
@testable import MagpieCore
import MagpieTestSupport
import Testing
@testable import CarPlayUI
@testable import ListenBrainzKit
@testable import MatchIndex
@testable import Search

/// Hostile values for models built straight in memory (what a decoder, an offline snapshot or the player may hand
/// the UI): every string, count and duration a server or a file could carry, and the non-finite ones local sources
/// can produce.
struct ModelFuzz {
    var rng: SeededRNG

    static let strings: [String] = JSONFuzzer.hostileStrings.map { escaped in
        (try? JSONSerialization.jsonObject(with: Data("\"\(escaped)\"".utf8), options: [.fragmentsAllowed])) as? String
            ?? "\u{FFFD}"
    } + ["Rock", "Pop & Rock", "Halo (Live)", "Halo", "Beyoncé", "BEYONCE", "東京事変", "Sigur Rós"]
    static let ints = [Int.min, Int.min + 1, -1, 0, 1, 2, 7, 1000, Int(Int32.max), Int.max - 1, Int.max]
    static let doubles: [Double] = [.nan, .infinity, -.infinity, 1e300, -1e300, .greatestFiniteMagnitude,
                                    -.greatestFiniteMagnitude, 5e-324, -1, 0, 0.4, 59.5, 3599.6, 1e9, 1e17, 201.5]

    static let short = strings.filter { $0.count <= 1_000 }

    /// Mostly short (ids repeat, so duplicates happen); now and then one of the 20,000-character ones.
    mutating func string() -> String {
        if rng.chance(0.3) { return "s\(Int.random(in: 0..<20, using: &rng))" }
        return (rng.chance(0.01) ? Self.strings : Self.short).randomElement(using: &rng)!
    }
    mutating func int() -> Int { rng.chance(0.4) ? Int.random(in: -3...30, using: &rng) : Self.ints.randomElement(using: &rng)! }
    mutating func optionalInt() -> Int? { rng.chance(0.2) ? nil : int() }
    mutating func double() -> Double { rng.chance(0.3) ? Double.random(in: 0...600, using: &rng) : Self.doubles.randomElement(using: &rng)! }
    mutating func optionalString() -> String? { rng.chance(0.3) ? nil : string() }
    mutating func mbid() -> MBID? {
        rng.chance(0.5) ? nil : MBID(String(format: "%08x-0000-4000-8000-%012x", Int.random(in: 0..<8, using: &rng), Int.random(in: 0..<8, using: &rng)))
    }

    mutating func song() -> Song {
        Song(id: string(), title: string(), artist: string(), artistId: optionalString(), album: string(),
             albumId: optionalString(), track: optionalInt(), disc: optionalInt(), duration: double(),
             suffix: optionalString(), bitRate: optionalInt(), coverArtId: optionalString(), recordingMBID: mbid(),
             artistMBID: mbid(), isrcs: rng.chance(0.5) ? [] : [string(), string()], libraryId: optionalInt(),
             starred: Bool.random(using: &rng),
             createdAt: rng.chance(0.5) ? nil : Date(timeIntervalSince1970: [0, -1e12, 1e12, 1.8e9].randomElement(using: &rng)!),
             genre: optionalString())
    }

    mutating func songs() -> [Song] { (0..<Int.random(in: 0...40, using: &rng)).map { _ in song() } }

    mutating func album() -> Album {
        Album(id: string(), name: string(), artist: string(), artistId: optionalString(), year: optionalInt(),
              songCount: int(), duration: double(), coverArtId: optionalString(), releaseGroupMBID: mbid(),
              songs: rng.chance(0.5) ? nil : songs())
    }

    mutating func artist() -> Artist { Artist(id: string(), name: string(), albumCount: int(), coverArtId: optionalString(), mbid: mbid()) }
    mutating func playlist() -> Playlist { Playlist(id: string(), name: string(), songCount: int(), duration: double()) }
    mutating func genre() -> Genre { Genre(name: string(), songCount: int(), albumCount: int(), countsKnown: Bool.random(using: &rng)) }

    mutating func recording() -> ExternalRecording {
        ExternalRecording(recordingMBID: mbid(), artistMBID: mbid(), title: string(), artist: string(),
                          releaseTitle: optionalString(), duration: rng.chance(0.3) ? nil : double(),
                          isrcs: rng.chance(0.7) ? [] : [string()], source: Bool.random(using: &rng) ? .lidarr : .listenBrainz)
    }

    mutating func notYetAlbum() -> NotYetAlbum {
        NotYetAlbum(title: string(), artist: string(), mbid: mbid(), artistMBID: mbid(), year: optionalInt(), kind: optionalString())
    }

    mutating func genrePreferences() -> GenrePreferences {
        let groups = GenreGroups.builtIn.map(\.id) + ["custom", "", string()]
        var p = GenrePreferences(mode: .grouped, assignments: [:], groupNames: [:], hidden: [], customGroups: [])
        for _ in 0..<Int.random(in: 0...6, using: &rng) { p.assignments[GenreGroups.key(string())] = groups.randomElement(using: &rng)! }
        for _ in 0..<Int.random(in: 0...3, using: &rng) { p.groupNames[groups.randomElement(using: &rng)!] = string() }
        for _ in 0..<Int.random(in: 0...3, using: &rng) { p.hidden.insert(groups.randomElement(using: &rng)!) }
        p.customGroups = (0..<Int.random(in: 0...3, using: &rng)).map { _ in groups.randomElement(using: &rng)! }
        return rng.chance(0.5) ? p.normalised() : p
    }
}

/// Crash hunt 4: Search, MatchIndex and every model → UI and car builder, with generated hostile models.
@Suite(.serialized) struct ModelFuzzTests {
    /// 6,000 generated cases (1,000 per kind) through search merging, the match ladder, Made for you, Not yet albums,
    /// genre grouping, the offline catalog and the car's rows (D12 limits held throughout).
    @Test(arguments: 0..<6) func searchMatchAndBuildersNeverTrap(kind: Int) throws {
        var f = ModelFuzz(rng: SeededRNG(seed: 0x5EA_4C4 &+ UInt64(kind)))
        var slowest = 0.0
        let total = FuzzClock.seconds {
            for _ in 0..<1_000 {
                let s = FuzzClock.seconds {
                    switch kind {
                    case 0:
                        let library = LibrarySearchResult(songs: f.songs(), albums: (0..<Int.random(in: 0...6, using: &f.rng)).map { _ in f.album() },
                                                          artists: (0..<Int.random(in: 0...6, using: &f.rng)).map { _ in f.artist() })
                        let outside = (0..<3).map { _ in
                            ExternalHits(songs: (0..<Int.random(in: 0...20, using: &f.rng)).map { _ in f.recording() },
                                         albums: (0..<Int.random(in: 0...10, using: &f.rng)).map { _ in f.notYetAlbum() },
                                         artists: (0..<Int.random(in: 0...6, using: &f.rng)).map { _ in NotYetArtist(name: f.string(), mbid: f.mbid()) })
                        }
                        let merged = MergedSearch.merge(query: f.string(), library: library, outside: outside,
                                                        index: MatchIndex(songs: f.songs()))
                        #expect(merged.notYet.songs.count <= MergedSearch.limits.songs)
                        #expect(merged.notYet.albums.count <= MergedSearch.limits.albums)
                        #expect(merged.notYet.artists.count <= MergedSearch.limits.artists)
                        UISink.checkClamped(CarPlayRows.searchResults(library, notYet: merged.notYet.songs, offer: .next, playingId: nil))
                        #expect(CarPlayRows.fitSearchItems(CarPlayRows.searchItems(library, notYet: merged.notYet.songs, offer: .next),
                                                           maxItems: Int.random(in: 0...12, using: &f.rng)).count <= 12)
                    case 1:
                        let songs = f.songs()
                        let index = MatchIndex(songs: songs)
                        let recordings = (0..<10).map { _ in f.recording() }
                        for r in recordings {
                            if let m = index.match(r) { #expect((0...1).contains(m.confidence)) }
                            _ = index.librarySong(for: r)
                            _ = index.hasArtist(name: r.artist, mbid: r.artistMBID)
                            _ = index.hasAlbum(title: r.releaseTitle ?? "", artist: r.artist)
                        }
                        let tracks = MadeForYou.resolve(recordings, index: index)
                        #expect(tracks.count == recordings.count)
                        UISink.songs(songs)
                    case 2:
                        let library = (0..<Int.random(in: 0...20, using: &f.rng)).map { _ in f.album() }
                        let found = ArtistNotYet.excluding((0..<Int.random(in: 0...60, using: &f.rng)).map { _ in f.notYetAlbum() }, library: library)
                        #expect(found.count <= ArtistNotYet.limit)
                        UISink.albums(library)
                    case 3:
                        let genres = (0..<Int.random(in: 0...40, using: &f.rng)).map { _ in f.genre() }
                        let sections = GenreGroups.grouped(genres, preferences: f.genrePreferences())
                        #expect(Set(sections.map(\.group.id)).count == sections.count)
                        UISink.genres(genres)
                    case 4:
                        UISink.artists((0..<Int.random(in: 0...30, using: &f.rng)).map { _ in f.artist() })
                        UISink.playlists((0..<Int.random(in: 0...30, using: &f.rng)).map { _ in f.playlist() })
                        let refs = (0..<Int.random(in: 0...20, using: &f.rng)).compactMap { _ in
                            f.mbid().map { LBPlaylistRef(id: $0, title: f.string(), date: f.optionalString(), sourcePatch: f.optionalString()) }
                        }
                        #expect(MadeForYou.shelf(refs).count <= MadeForYou.shelfLimit)
                    default:
                        let counts = (0..<Int.random(in: 0...12, using: &f.rng)).map { _ in f.int() }
                        let maxItems = f.int()
                        let sizes = CarPlayRows.homeShelfSizes(counts, maxItems: maxItems)
                        #expect(sizes.count == counts.count)
                        #expect(sizes.allSatisfy { $0 >= 0 && $0 <= CarPlayRows.homeShelfMaxSize })
                        #expect(sizes.reduce(0, +) <= max(0, maxItems))
                        var nav = CPNavigator()
                        for _ in 0..<6 { nav.push(.albums) }
                        #expect(nav.depth <= CPNavigator.maxBrowseDepth)
                        let sections = (0..<Int.random(in: 0...20, using: &f.rng)).map { _ in
                            CPSectionModel(header: f.optionalString(), rows: (0..<Int.random(in: 0...30, using: &f.rng)).map { _ in
                                CPRowModel(id: f.string(), title: f.string(), action: .none)
                            })
                        }
                        let items = f.int(), groups = f.int()
                        let clamped = clamp(sections, maxItems: items, maxSections: groups)
                        #expect(clamped.reduce(0) { $0 + $1.rows.count } <= max(0, items))
                        #expect(clamped.count <= max(0, groups))
                        for d in ModelFuzz.doubles { _ = CarPlayRows.duration(d) }
                    }
                }
                slowest = max(slowest, s)
            }
        }
        #expect(slowest < 1, "slowest case \(slowest) s")
        #expect(total < 9, "sweep took \(total) s")
    }

    /// Normalising never-ending or adversarial names stays linear: 20,000 combining marks, brackets, dashes.
    @Test func normaliseStaysLinear() {
        let long = [String(repeating: "e\u{0301}", count: 20_000), String(repeating: "(", count: 20_000),
                    String(repeating: "a - ", count: 10_000), String(repeating: "[live] ", count: 5_000),
                    String(repeating: "feat. ", count: 10_000), String(repeating: "🇬🇧", count: 10_000),
                    String(repeating: "Rock & Pop; ", count: 5_000)]
        let seconds = FuzzClock.seconds {
            for s in long {
                _ = Normalize.key(artist: s, title: s)
                _ = Normalize.hasVersionAside(s)
                _ = GenreGroups.split(s)
                _ = GenreGroups.groupId(for: s)
                _ = ArtistNotYet.titleKey(s)
            }
        }
        #expect(seconds < 9, "took \(seconds) s")
    }

    /// 5,000 mutated match index snapshots: loading never traps, and a damaged one is ignored.
    @Test func matchIndexSnapshotsNeverTrap() async throws {
        let songs = (0..<40).map { i in
            Song(id: "s\(i)", title: "Title \(i)", artist: "Artist \(i % 5)", album: "Album \(i % 7)", duration: Double(i * 10),
                 recordingMBID: MBID(String(format: "%08x-0000-4000-8000-000000000000", i)), isrcs: i % 3 == 0 ? ["GB\(i)"] : [])
        }
        let snapshot = MatchIndexStore.Snapshot(version: 1, savedAt: Date(timeIntervalSince1970: 1.8e9), index: MatchIndex(songs: songs))
        let seed = try JSONEncoder().encode(snapshot)
        let dir = FileManager.default.temporaryDirectory.appending(path: "hunt4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "snapshot.json")
        var fuzzer = JSONFuzzer(seed: 0x1D_E5)
        var loaded = 0
        let seconds = await FuzzClock.seconds {
            for _ in 0..<5_000 {
                try? fuzzer.mutate(seed).write(to: file)
                let store = MatchIndexStore(fileURL: file)
                if await store.loadSnapshot() {
                    loaded += 1
                    let index = await store.index
                    _ = index.match(ExternalRecording(title: "Title 1", artist: "Artist 1", source: .listenBrainz))
                }
            }
        }
        #expect(loaded > 100)
        #expect(seconds < 9, "took \(seconds) s")
    }
}
