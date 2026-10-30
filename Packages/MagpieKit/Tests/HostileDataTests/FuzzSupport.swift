import Foundation
import MagpieCore
import MagpieTestSupport
import os
import Testing
@testable import CarPlayUI
@testable import MatchIndex
@testable import Playback
@testable import Search

enum Fixture {
    static func data(_ dir: String, _ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: dir),
              let data = try? Data(contentsOf: url) else { fatalError("Missing fixture \(dir)/\(name).json") }
        return data
    }
}

/// What the catch-all stub answers next: the fuzzed body, its status and headers.
final class Answer: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: MockTransport.Response(status: 200))

    func set(_ body: Data, status: Int = 200, headers: [String: String] = [:]) {
        state.withLock { $0 = MockTransport.Response(status: status, body: body, headers: headers) }
    }

    var response: MockTransport.Response { state.withLock { $0 } }
}

/// The time bounds every sweep holds (no quadratic blow-ups): no single case over `maxCase` seconds.
struct SweepStats {
    var cases = 0
    var decoded = 0
    var errors = 0
    var slowest = 0.0

    mutating func record(seconds: Double, ok: Bool) {
        cases += 1
        if ok { decoded += 1 } else { errors += 1 }
        slowest = max(slowest, seconds)
    }
}

/// Crash hunt 4: the decoded models go through everything that shows them, the phone's and the car's builders, and
/// the limits of D12 must hold whatever the server sent.
enum UISink {
    static let carItems = 12, carSections = 5

    /// D12: a clamped list never exceeds the car's limits.
    static func checkClamped(_ sections: [CPSectionModel], sourceLocation: SourceLocation = #_sourceLocation) {
        let clamped = clamp(sections, maxItems: carItems, maxSections: carSections)
        let rows = clamped.reduce(0) { $0 + $1.rows.count }
        #expect(rows <= carItems, sourceLocation: sourceLocation)
        #expect(clamped.count <= carSections, sourceLocation: sourceLocation)
        #expect(clamped.allSatisfy { !$0.rows.isEmpty }, sourceLocation: sourceLocation)
        _ = needsRebuild(old: clamped, new: sections)
        for row in clamped.flatMap(\.rows) { #expect(!row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }

    static func songs(_ songs: [Song]) {
        let album = Album(id: "a", name: songs.first?.album ?? "", artist: songs.first?.artist ?? "", songCount: songs.count,
                          duration: songs.reduce(0) { $0 + $1.duration }, songs: songs)
        checkClamped(CarPlayRows.album(album, playingId: songs.first?.id))
        checkClamped(CarPlayRows.downloadedAlbum(album, playingId: songs.last?.id))
        checkClamped(CarPlayRows.playlist(Playlist(id: "p", name: "", songCount: songs.count, duration: 0), songs: songs, playingId: nil))
        checkClamped(CarPlayRows.favourites(Starred(songs: songs), playingId: nil))
        checkClamped(CarPlayRows.downloadedArtist(Artist(id: "x", name: "", albumCount: 1), albums: [album]))
        checkClamped(CarPlayRows.madeForYou(songs.map { .song($0) }, offer: .unavailable, playingId: nil))
        let items = CarPlayRows.searchItems(LibrarySearchResult(songs: songs))
        #expect(CarPlayRows.fitSearchItems(items, maxItems: carItems).count <= carItems)
        for song in songs.prefix(200) {
            if let text = CarPlayRows.duration(song.duration) { #expect(!text.isEmpty) }
        }
        // The match index (and its snapshot) and what's on the phone.
        let index = MatchIndex(songs: songs)
        if let snapshot = try? JSONEncoder().encode(index) { _ = try? JSONDecoder().decode(MatchIndex.self, from: snapshot) }
        for song in songs.prefix(50) {
            _ = index.librarySong(for: ExternalRecording(recordingMBID: song.recordingMBID, title: song.title,
                                                          artist: song.artist, duration: song.duration, source: .lidarr))
        }
        offline(songs)
        genres(songs.compactMap(\.genre).map { Genre(name: $0, songCount: 1, albumCount: 1) })
        finds(songs)
    }

    static func offline(_ songs: [Song]) {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = songs.prefix(500).enumerated().map { i, song in
            AudioEntry(songId: song.id, quality: .original, fileName: "f\(i)", size: 1, kind: i % 3 == 0 ? .cache : .download,
                       reasons: [.song], downloadedAt: date, lastPlayed: i % 2 == 0 ? date : nil, metadata: AudioMetadata(song))
        }
        let catalog = OfflineCatalog(entries: entries, playlists: [
            DownloadedPlaylist(id: "p", name: "", coverArtId: nil, songIds: songs.prefix(500).map(\.id), savedAt: date),
        ])
        let albums = catalog.albums(), artists = catalog.artists(), playlists = catalog.playlists()
        checkClamped(CarPlayRows.downloads(albums: albums, artists: artists, playlists: playlists))
        for album in albums.prefix(5) {
            if let full = catalog.album(id: album.id) { checkClamped(CarPlayRows.downloadedAlbum(full, playingId: nil)) }
        }
        for artist in artists.prefix(5) {
            checkClamped(CarPlayRows.downloadedArtist(artist, albums: catalog.albums(byArtist: artist.id)))
        }
        _ = catalog.genres()
        _ = catalog.songs()
        _ = catalog.search(songs.first?.title ?? "a")
        _ = catalog.recentlyPlayed(matching: "")
        home(albums: albums, playlists: playlists, genres: [])
    }

    static func finds(_ songs: [Song]) {
        let finds = songs.prefix(100).map { CPFind(song: $0, daysLeft: $0.track ?? $0.disc ?? 0, isNew: ($0.bitRate ?? 0) % 2 == 0) }
        checkClamped(CarPlayRows.finds(CPFindsShelf(newFinds: Array(finds.prefix(10)), finds: Array(finds.dropFirst(10))),
                                       playingId: songs.first?.id))
    }

    static func albums(_ albums: [Album]) {
        checkClamped(CarPlayRows.albums(albums))
        checkClamped(CarPlayRows.artist(Artist(id: "a", name: "", albumCount: albums.count), albums: albums))
        checkClamped(CarPlayRows.favourites(Starred(albums: albums), playingId: nil))
        checkClamped(CarPlayRows.downloads(albums: albums, playlists: []))
        for album in albums.prefix(20) { if let songs = album.songs { self.songs(songs) } }
        home(albums: albums, playlists: [], genres: [])
    }

    static func artists(_ artists: [Artist]) {
        checkClamped(CarPlayRows.artists(artists))
        checkClamped(CarPlayRows.downloads(albums: [], artists: artists, playlists: []))
    }

    static func playlists(_ playlists: [Playlist]) {
        checkClamped(CarPlayRows.playlists(playlists))
        checkClamped(CarPlayRows.downloads(albums: [], playlists: playlists))
        home(albums: [], playlists: playlists, genres: [])
    }

    static func genres(_ genres: [Genre]) {
        var prefs = GenrePreferences.defaultValue
        prefs.assignments = Dictionary(genres.prefix(3).map { (GenreGroups.key($0.name), "jazz") }, uniquingKeysWith: { a, _ in a })
        let sections = GenreGroups.grouped(genres, preferences: prefs)
        let all = GenreGroups.allGenres(genres)
        #expect(all.count <= genres.count)
        for name in genres.prefix(200).map(\.name) { _ = GenreGroups.split(name); _ = GenreGroups.groupId(for: name) }
        checkClamped(CarPlayRows.genres(sections.map { (id: $0.group.id, name: $0.group.name, albumCount: $0.albumCount) }))
        for section in sections.prefix(4) { checkClamped(CarPlayRows.genreGroup(id: section.group.id, subgenres: section.genres)) }
        home(albums: [], playlists: [], genres: sections)
    }

    /// D12 on Home: at most the car's sections and items, at most `homeShelfMaxSize` tiles a shelf.
    static func home(albums: [Album], playlists: [Playlist], genres: [GenreGroupSection]) {
        let shelves = [
            CPHomeShelf(section: .recentlyAdded, items: albums.map { .album($0) }),
            CPHomeShelf(section: .downloaded, items: albums.map { .album($0) }),
            CPHomeShelf(section: .playlists, items: playlists.map { .playlist($0) }),
            CPHomeShelf(section: .genres, items: genres.map { .genreGroup(id: $0.group.id, name: $0.group.name, albumCount: $0.albumCount) }),
        ]
        let sections = CarPlayRows.home(shelves, maxItems: carItems, maxSections: 3)
        #expect(sections.count <= 3)
        #expect(sections.reduce(0) { $0 + $1.rows.count } <= carItems)
        #expect(sections.allSatisfy { $0.rows.count <= CarPlayRows.homeShelfMaxSize || $0.rows.first?.id.hasPrefix("state.") == true })
    }

    static func notYet(_ recordings: [ExternalRecording]) {
        let rows = CarPlayRows.notYetRows(recordings, offer: .next)
        #expect(CarPlayRows.fitSearchItems(rows, maxItems: carItems).count <= carItems)
        checkClamped(CarPlayRows.searchResults(LibrarySearchResult(), notYet: recordings, offer: .ask(intoFinds: true), playingId: nil))
        checkClamped(CarPlayRows.madeForYou(recordings.map { .notYet($0) }, offer: .next, playingId: nil))
    }
}
