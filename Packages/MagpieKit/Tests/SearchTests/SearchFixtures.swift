import Foundation
import MagpieCore
@testable import Search

/// A small real-world library for the ranking table and the fake server (Y1).
enum Fixture {
    static func song(_ id: String, _ title: String, _ artist: String, _ album: String) -> Song {
        Song(id: id, title: title, artist: artist, artistId: "ar-" + Self.slug(artist), album: album,
             albumId: "al-" + Self.slug(album + "|" + artist), duration: 200)
    }

    static func slug(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }

    static let songs: [Song] = [
        song("s01", "Hey Jude", "Wilson Pickett", "Hey Jude"),
        song("s02", "Hey Jude (Remastered 2015)", "The Beatles", "1 (Remastered)"),
        song("s03", "Hey Bulldog", "The Beatles", "Yellow Submarine"),
        song("s04", "Hey Jude", "The Beatles", "1"),
        song("s05", "Hey Jupiter", "Tori Amos", "Boys for Pele"),
        song("s06", "Let It Be", "The Beatles", "Let It Be"),
        song("s07", "Yesterday", "The Beatles", "Help!"),
        song("s08", "National Anthem", "Radiohead", "Kid A"),
        song("s09", "Fake Empire", "The National", "Boxer"),
        song("s10", "Bloodbuzz Ohio", "The National", "High Violet"),
        song("s11", "Myth", "Beach House", "Bloom"),
        song("s12", "Hoppípolla", "Sigur Rós", "Takk..."),
        song("s13", "Jóga", "Björk", "Homogenic"),
        song("s14", "Halo", "Beyoncé", "I Am... Sasha Fierce"),
        song("s15", "Владивосток 2000", "Мумий Тролль", "Морская"),
        song("s16", "戦場のメリークリスマス", "坂本龍一", "Merry Christmas Mr. Lawrence"),
        song("s17", "Bohemian Rhapsody", "Queen", "A Night at the Opera"),
        song("s18", "Around the World", "Daft Punk", "Homework"),
        song("s19", "Skinny Love", "Bon Iver", "For Emma, Forever Ago"),
        song("s20", "Sweet Child o' Mine", "Guns N' Roses", "Appetite for Destruction"),
        song("s21", "Highway to Hell", "AC/DC", "Highway to Hell"),
        song("s22", "This Is the Day", "The The", "Soul Mining"),
        song("s23", "Saman", "Ólafur Arnalds", "re:member"),
        song("s24", "Stand by Me", "Ben E. King", "Don't Play That Song!"),
        song("s25", "Paranoid Android", "Radiohead", "OK Computer"),
        song("s26", "Help!", "The Beatles", "Help!"),
        song("s27", "Lowlands", "Aurora Field", "Lowlands"),
        song("s28", "Heron", "Aurora Field", "Lowlands"),
    ]

    static let albums: [Album] = {
        var seen = Set<String>()
        return songs.compactMap { s in
            guard let id = s.albumId, seen.insert(id).inserted else { return nil }
            return Album(id: id, name: s.album, artist: s.artist, artistId: s.artistId, songCount: 1, duration: 200)
        }
    }()

    static let artists: [Artist] = {
        var seen = Set<String>()
        return songs.compactMap { s in
            guard let id = s.artistId, seen.insert(id).inserted else { return nil }
            return Artist(id: id, name: s.artist, albumCount: 1)
        }
    }()

    static var all: LibrarySearchResult { LibrarySearchResult(songs: songs, albums: albums, artists: artists) }
}

/// A fake Navidrome `search3`: every query word must be a prefix of a word of the item's text (song: title, artist
/// and album; album: name and artist; artist: name), after case and accents are folded; words in unspaced scripts
/// match anywhere. Punctuation in the query is dropped (Navidrome ignores " - "). Counts and offsets page the matches
/// in library order, a count of 0 returns none, and every call is recorded.
final class FakeNavidrome: @unchecked Sendable {
    let library: LibrarySearchResult
    private let lock = NSLock()
    private var calls: [LibraryQuery] = []
    private var running = 0
    private(set) var peak = 0
    var delay: Duration = .zero
    var failing: Set<String> = []
    /// Queries that never answer (until cancelled).
    var slow: Set<String> = []

    init(_ library: LibrarySearchResult = Fixture.all) { self.library = library }

    var queries: [LibraryQuery] { lock.withLock { calls } }

    func search(_ q: LibraryQuery) async throws -> LibrarySearchResult {
        lock.withLock { calls.append(q); running += 1; peak = max(peak, running) }
        defer { lock.withLock { running -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        if slow.contains(q.text) { try await Task.sleep(for: .seconds(3600)) }   // until cancelled
        try Task.checkCancellation()
        if failing.contains(q.text) { throw URLError(.badServerResponse) }
        let words = Self.words(q.text)
        func page<T>(_ all: [T], _ text: (T) -> String, offset: Int, count: Int) -> [T] {
            let hits = all.filter { item in
                let target = Self.words(text(item))
                let joined = target.joined(separator: " ")
                return words.allSatisfy { w in
                    w.unicodeScalars.contains(where: { $0.value >= 0x3040 }) ? joined.contains(w)
                        : target.contains { $0.hasPrefix(w) }
                }
            }
            guard count > 0, offset < hits.count else { return [] }
            return Array(hits[offset..<min(hits.count, offset + count)])
        }
        return LibrarySearchResult(
            songs: page(library.songs, { "\($0.title) \($0.artist) \($0.album)" }, offset: q.songOffset, count: q.songCount),
            albums: page(library.albums, { "\($0.name) \($0.artist)" }, offset: q.albumOffset, count: q.albumCount),
            artists: page(library.artists, { $0.name }, offset: q.artistOffset, count: q.artistCount))
    }

    static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
