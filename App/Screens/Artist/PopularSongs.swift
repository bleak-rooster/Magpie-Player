import Foundation
import MagpieCore
import Observation
import os

/// The artist page's Popular (round 11 R3), saved per account and artist so it shows at once when the page opens,
/// while a read replaces it only when it changed (the pattern of Home's saved shelves, `HomeShelfCache`). Only ids and
/// what a row shows: no secrets, no URLs. One small file per account in Application Support/Magpie/Popular, excluded
/// from backup and removed on sign-out.
struct PopularSongsCache {
    let url: URL

    /// The file for `scope` (the app's own hex id for an account, never a server string) under `root`.
    init(root: URL, scope: String) {
        url = Self.directory(root: root).appending(path: "\(scope).json")
    }

    static func directory(root: URL) -> URL { root.appending(path: "Magpie/Popular", directoryHint: .isDirectory) }

    /// Removes every account's file (sign-out).
    static func removeAll(root: URL) {
        try? FileManager.default.removeItem(at: directory(root: root))
    }

    /// Artists kept (the ones opened most recently), songs per artist, and the file's size limit.
    static let maxArtists = 200
    static let maxSongs = 10
    static let maxBytes = 1024 * 1024

    /// The saved Popular of `artistId`; nil when none was saved or the file doesn't read.
    func load(artistId: String) -> [Song]? {
        read()?.artists[artistId].map { $0.rows.prefix(Self.maxSongs).map(\.song) }
    }

    /// Saves `songs` (the first `maxSongs`) as `artistId`'s Popular; an empty list removes the artist.
    func save(_ songs: [Song], artistId: String, now: Date = .now) {
        var file = read() ?? File(version: File.currentVersion, artists: [:])
        if songs.isEmpty {
            guard file.artists.removeValue(forKey: artistId) != nil else { return }
        } else {
            file.artists[artistId] = Entry(savedAt: now, rows: songs.prefix(Self.maxSongs).map(Row.init))
        }
        if file.artists.count > Self.maxArtists {
            let oldest = file.artists.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(file.artists.count - Self.maxArtists)
            for (id, _) in oldest { file.artists.removeValue(forKey: id) }
        }
        do {
            try AtomicFile.write(file, to: url)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var saved = url, directory = url.deletingLastPathComponent()
            try saved.setResourceValues(values)
            try directory.setResourceValues(values)
        } catch {
            Log.logger("artist").error("cannot save Popular: \(Log.category(of: error), privacy: .public)")
        }
    }

    /// What a Popular row shows, so two lists that look the same compare equal.
    static func rows(_ songs: [Song]) -> [Row] { songs.map(Row.init) }

    private func read() -> File? {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maxBytes,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == File.currentVersion else { return nil }
        return file
    }

    private struct File: Codable {
        static let currentVersion = 1
        var version: Int
        var artists: [String: Entry]
    }

    private struct Entry: Codable {
        var savedAt: Date
        var rows: [Row]
    }

    /// One song as a row shows it.
    struct Row: Codable, Equatable {
        var id: String
        var title: String
        var artist: String
        var artistId: String?
        var album: String
        var albumId: String?
        var duration: TimeInterval
        var coverArtId: String?
        var suffix: String?
        var bitRate: Int?

        init(_ song: Song) {
            id = song.id; title = song.title; artist = song.artist; artistId = song.artistId
            album = song.album; albumId = song.albumId; duration = song.duration; coverArtId = song.coverArtId
            suffix = song.suffix; bitRate = song.bitRate
        }

        var song: Song {
            Song(id: id, title: title, artist: artist, artistId: artistId, album: album, albumId: albumId,
                 duration: duration.isFinite ? max(0, duration) : 0, suffix: suffix, bitRate: bitRate,
                 coverArtId: coverArtId)
        }
    }
}

/// One artist page's Popular: the saved list at once, then the server's, swapped in only when a row would look
/// different (the same rows keep what is on screen, so nothing flickers or reorders).
@MainActor @Observable final class PopularSongs {
    private(set) var songs: [Song] = []
    /// How many times a read changed what shows (tests).
    @ObservationIgnored private(set) var visibleChanges = 0
    @ObservationIgnored private let artistId: String
    @ObservationIgnored private let cache: PopularSongsCache?
    @ObservationIgnored private let read: () async throws -> [Song]

    init(artistId: String, cache: PopularSongsCache?, read: @escaping () async throws -> [Song]) {
        self.artistId = artistId
        self.cache = cache
        self.read = read
        songs = cache?.load(artistId: artistId) ?? []
    }

    /// Reads the server's Popular. A failed read keeps what shows; a list that reads the same keeps its rows.
    func refresh() async {
        guard let fresh = try? await read(), !Task.isCancelled else { return }
        if PopularSongsCache.rows(fresh) != PopularSongsCache.rows(songs) {
            songs = fresh
            visibleChanges += 1
        } else if fresh != songs {
            songs = fresh   // the same rows; the server's copies carry more (stars, ReplayGain)
        }
        cache?.save(fresh, artistId: artistId)
    }
}

extension AppModel {
    /// Popular for an artist page, from this account's saved lists.
    func popularSongs(artistId: String, artistName: String) -> PopularSongs {
        PopularSongs(artistId: artistId, cache: navidromeScope.map { PopularSongsCache(root: dataDirectory, scope: $0) },
                     read: { [weak self] in
                         guard let self else { throw CancellationError() }
                         return try await self.request { try await $0.topSongs(artistName: artistName) }
                     })
    }
}
