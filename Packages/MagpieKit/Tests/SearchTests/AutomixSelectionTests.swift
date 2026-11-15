import Foundation
import MagpieCore
import Testing
@testable import Search

private func song(_ id: String, artist: String, title: String? = nil, library: Int? = 1) -> Song {
    Song(id: id, title: title ?? "Song \(id)", artist: artist, artistId: "ar-\(artist)", album: "Album", duration: 200,
         libraryId: library)
}

/// `count` songs, each by its own artist ("x0", "x1", …), ids prefixed.
private func distinct(_ prefix: String, _ count: Int) -> [Song] {
    (0..<count).map { song("\(prefix)\($0)", artist: "\(prefix)-artist-\($0)") }
}

/// `count` songs by `artists` artists in turn.
private func spread(_ prefix: String, _ count: Int, artists: Int) -> [Song] {
    (0..<count).map { song("\(prefix)\($0)", artist: "\(prefix)-a\($0 % max(artists, 1))") }
}

private func ids(_ songs: [Song]) -> [String] { songs.map(\.id) }

/// Whether no window of `window` songs in a row (the history first) holds more than `most` of one artist.
private func spaced(_ songs: [Song], history: [Song] = [], most: Int, window: Int) -> Bool {
    let all = (history + songs).map { $0.artistId ?? $0.artist }
    guard all.count > 0 else { return true }
    for end in all.indices {
        let slice = all[max(0, end - window + 1)...end]
        if Dictionary(grouping: slice, by: { $0 }).values.contains(where: { $0.count > most }) { return false }
    }
    return true
}

private func pick(_ candidates: Automix.Candidates, length: Int = 50, variety: Automix.Variety = .balanced,
                  history: [Song] = [], played: Set<String> = [], excluded: (Song) -> Bool = { _ in false },
                  seed: UInt64 = 7) -> [Song] {
    var rng = Automix.Generator(seed: seed)
    return Automix.pick(candidates, length: length, variety: variety, history: history, played: played,
                        excluded: excluded, using: &rng)
}

/// Round 27 A (owner item 17, 2026-11-14: "When you hit automix, it find similar songs within your library and puts them
/// into the queue … select the length of the automix and also select how variable you want the selection"; D306): the
/// pure selection. Library songs only, in Navidrome's order with seeded jitter; the variety's artist spacing; never the
/// seed, a repeat, a Discover copy, a find or a missing file.
@Suite struct AutomixSelectionTests {
    @Test func pick_lengthRespected() {
        let candidates = Automix.Candidates(similar: distinct("s", 200))
        for length in Automix.Length.allCases {
            #expect(pick(candidates, length: length.rawValue).count == length.rawValue)
        }
        #expect(Automix.Length.allCases.map(\.rawValue) == [20, 50, 100])
        #expect(Automix.Length.standard == .fifty && Automix.Variety.standard == .balanced)
        #expect(pick(Automix.Candidates(similar: distinct("s", 12)), length: 50).count == 12, "fewer when the library can't fill it")
        #expect(pick(Automix.Candidates(), length: 50).isEmpty)
    }

    @Test func pick_neverSeedRepeatsDiscoverOrFind() {
        let seed = song("seed", artist: "Seed")
        var similar = distinct("s", 30)
        similar.insert(seed, at: 0)
        similar.append(similar[3])                                                      // the same song twice
        similar.append(song("dup-title", artist: similar[4].artist, title: similar[4].title))   // another copy of it
        let candidates = Automix.Candidates(similar: similar, artistSongs: [seed, song("a1", artist: "Seed")],
                                            genreSongs: [similar[5]])
        let result = pick(candidates, length: 100, variety: .adventurous, history: [seed], played: ["s1", "s2"],
                          excluded: { $0.id == "s6" || $0.id == "s7" })
        #expect(!ids(result).contains("seed"))
        #expect(!ids(result).contains("s1") && !ids(result).contains("s2"), "already played in this mix")
        #expect(!ids(result).contains("s6") && !ids(result).contains("s7"), "a Discover copy or a find")
        #expect(Set(ids(result)).count == result.count, "no repeats")
        #expect(!ids(result).contains("dup-title"), "another copy of a song already in")
    }

    @Test func pick_closeArtistSpacing() {
        let history = [song("seed", artist: "Seed")]
        let candidates = Automix.Candidates(similar: spread("s", 120, artists: 4),
                                            artistSongs: (0..<20).map { song("own\($0)", artist: "Seed") })
        let result = pick(candidates, length: 50, variety: .close, history: history)
        #expect(spaced(result, history: history, most: 2, window: 5))
        #expect(!result.isEmpty)
        #expect(Automix.spacing(.close) == Automix.Spacing(most: 2, window: 5))
    }

    @Test func pick_balancedArtistSpacing() {
        let history = [song("seed", artist: "Seed")]
        let result = pick(Automix.Candidates(similar: spread("s", 200, artists: 6)), length: 50, variety: .balanced,
                          history: history)
        #expect(spaced(result, history: history, most: 1, window: 4))
        #expect(result.count == 50)
        #expect(Automix.spacing(.balanced) == Automix.Spacing(most: 1, window: 4))
    }

    @Test func pick_adventurousArtistSpacing() {
        let history = [song("seed", artist: "Seed")]
        let candidates = Automix.Candidates(similar: spread("s", 200, artists: 9), genreSongs: spread("g", 100, artists: 7))
        let result = pick(candidates, length: 100, variety: .adventurous, history: history)
        #expect(spaced(result, history: history, most: 1, window: 6))
        #expect(result.count == 100)
        #expect(Automix.spacing(.adventurous) == Automix.Spacing(most: 1, window: 6))
    }

    /// Close keeps to the nearest 40% of Navidrome's list (and the artist's own songs); Balanced to the nearest 70%.
    @Test func pick_varietyWindows() {
        let similar = distinct("s", 100)
        let close = pick(Automix.Candidates(similar: similar), length: 20, variety: .close)
        #expect(close.allSatisfy { (Int($0.id.dropFirst()) ?? 999) < 40 })
        let balanced = pick(Automix.Candidates(similar: similar), length: 50, variety: .balanced)
        #expect(balanced.allSatisfy { (Int($0.id.dropFirst()) ?? 999) < 70 })
        let adventurous = pick(Automix.Candidates(similar: similar), length: 50, variety: .adventurous)
        #expect(adventurous.contains { (Int($0.id.dropFirst()) ?? 0) >= 70 }, "the whole list")
    }

    /// Navidrome answered too few: the seed artist's songs and the genre's fill, spaced.
    @Test func pick_fallsBackToArtistAndGenre() {
        let history = [song("seed", artist: "Seed")]
        let candidates = Automix.Candidates(similar: distinct("s", 3),
                                            artistSongs: (0..<10).map { song("own\($0)", artist: "Seed") },
                                            genreSongs: distinct("g", 40))
        let result = pick(candidates, length: 20, variety: .balanced, history: history)
        #expect(result.count == 20)
        #expect(ids(result).contains { $0.hasPrefix("own") } && ids(result).contains { $0.hasPrefix("g") })
        #expect(Array(ids(result).prefix(3)).allSatisfy { $0.hasPrefix("s") }, "Navidrome's own suggestions first")
        #expect(spaced(result, history: history, most: 1, window: 4))
    }

    @Test func pick_seededIsDeterministic() {
        let candidates = Automix.Candidates(similar: spread("s", 150, artists: 30), artistSongs: distinct("a", 10),
                                            genreSongs: distinct("g", 50))
        for variety in Automix.Variety.allCases {
            #expect(ids(pick(candidates, variety: variety, seed: 42)) == ids(pick(candidates, variety: variety, seed: 42)))
        }
        #expect(ids(pick(candidates, variety: .adventurous, seed: 1)) != ids(pick(candidates, variety: .adventurous, seed: 2)))
    }

    /// Seeded fuzz: odd inputs (duplicates, blank names, nil artist ids, a length of zero or less) never trap, never pass the
    /// length, never repeat, never take an excluded song, and always keep the variety's spacing.
    @Test func pick_fuzzNeverTrapsOrExceedsLength() {
        var g = Automix.Generator(seed: 2027)
        for _ in 0..<500 {
            func list(_ prefix: String) -> [Song] {
                (0..<Int.random(in: 0...60, using: &g)).map { _ in
                    let n = Int.random(in: 0...40, using: &g)
                    let artist = ["", "A", "B", "C", "Ünïcode", "\(n % 7)"].randomElement(using: &g) ?? ""
                    var s = song("\(prefix)\(n)", artist: artist, title: Bool.random(using: &g) ? "" : "T\(n % 9)")
                    if Bool.random(using: &g) { s.artistId = nil }
                    return s
                }
            }
            let candidates = Automix.Candidates(similar: list("s"), artistSongs: list("a"), genreSongs: list("g"))
            let length = Int.random(in: -5...120, using: &g)
            let variety = Automix.Variety.allCases.randomElement(using: &g) ?? .balanced
            let history = Bool.random(using: &g) ? list("h").prefix(1).map { $0 } : []
            let result = pick(candidates, length: length, variety: variety, history: history,
                              excluded: { $0.id.hasSuffix("3") }, seed: UInt64.random(in: 0...UInt64.max, using: &g))
            #expect(result.count <= max(length, 0))
            #expect(Set(ids(result)).count == result.count)
            #expect(!result.contains { $0.id.hasSuffix("3") })
            #expect(!result.contains { s in history.contains { $0.id == s.id } })
            let rule = Automix.spacing(variety)
            #expect(spaced(result, history: history, most: rule.most, window: rule.window))
        }
    }
}
