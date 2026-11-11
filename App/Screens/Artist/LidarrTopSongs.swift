import AurralKit
import Foundation
import MagpieCore
import MatchIndex
import Observation
import os
import Requests
import Search

/// Round 26 K2 (owner, 2026-11-10, item 6: "This list should be saved for when the artist is next opened up, so that it
/// can immediately be seen"; D263): the Top songs of artists Lidarr has, saved per account and artist, modelled on
/// Popular's file (`PopularSongsCache`, R3). Only ids and what a row shows: no URLs, preview paths, outside ids, MBIDs,
/// ISRCs or keys. One small file per account in Application Support/Magpie/TopSongs, excluded from backup and removed on
/// sign-out.
struct LidarrTopSongsCache {
    let url: URL

    /// The file for `scope` (the app's own hex id for an account, never a server string) under `root`.
    init(root: URL, scope: String) {
        url = Self.directory(root: root).appending(path: "\(scope).json")
    }

    static func directory(root: URL) -> URL { root.appending(path: "Magpie/TopSongs", directoryHint: .isDirectory) }

    /// Removes every account's file (sign-out).
    static func removeAll(root: URL) {
        try? FileManager.default.removeItem(at: directory(root: root))
    }

    /// Artists kept (the ones saved most recently), rows per artist ("a total of 5 songs"), and the file's size limit.
    static let maxArtists = 300
    static let maxRows = LidarrTopSongs.limit
    static let maxBytes = 1024 * 1024

    /// An artist's key: `mbid:<artist MBID>` (shared by the library and outside pages, D267), else `id:<library artist
    /// id>`; nil when the page has neither.
    static func key(mbid: MBID?, artistId: String?) -> String? {
        if let mbid { return "mbid:\(mbid.rawValue)" }
        guard let artistId, !artistId.isEmpty else { return nil }
        return "id:\(artistId)"
    }

    /// The saved rows of `key`; nil when none were saved or the file doesn't read.
    func load(_ key: String) -> [Row]? {
        read()?.artists[key].map { Array($0.rows.prefix(Self.maxRows)) }
    }

    /// Offline (D268), where the page has only the library's artist id: the entry saved under it, else the most recently
    /// saved one whose songs are that artist's (an artist saved under their MBID).
    func load(offlineArtistId id: String) -> [Row]? {
        guard let file = read() else { return nil }
        if let rows = file.artists["id:\(id)"]?.rows { return Array(rows.prefix(Self.maxRows)) }
        return file.artists.values.filter { $0.rows.contains { $0.artistId == id } }
            .max { $0.savedAt < $1.savedAt }.map { Array($0.rows.prefix(Self.maxRows)) }
    }

    /// How many artists are saved (tests).
    var count: Int { read()?.artists.count ?? 0 }

    /// Saves `rows` (the first five) as `key`'s Top songs; an empty list removes the artist.
    func save(_ rows: [LidarrTopSongs.Row], key: String, now: Date = .now) {
        write(rows.prefix(Self.maxRows).map(Row.init), key: key, now: now)
    }

    /// Forgets `key`'s Top songs (the artist left Lidarr, or none of their top songs are in the library).
    func remove(_ key: String) {
        guard var file = read(), file.artists.removeValue(forKey: key) != nil else { return }
        store(&file)
    }

    private func write(_ rows: [Row], key: String, now: Date) {
        var file = read() ?? File(version: File.currentVersion, artists: [:])
        if rows.isEmpty {
            guard file.artists.removeValue(forKey: key) != nil else { return }
        } else {
            file.artists[key] = Entry(savedAt: now, rows: rows)
        }
        if file.artists.count > Self.maxArtists {
            let oldest = file.artists.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(file.artists.count - Self.maxArtists)
            for (id, _) in oldest { file.artists.removeValue(forKey: id) }
        }
        store(&file)
    }

    private func store(_ file: inout File) {
        do {
            try AtomicFile.write(file, to: url)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var saved = url, directory = url.deletingLastPathComponent()
            try saved.setResourceValues(values)
            try directory.setResourceValues(values)
        } catch {
            Log.logger("artist").error("cannot save Top songs: \(Log.category(of: error), privacy: .public)")
        }
    }

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

    /// One song as a row shows it (`PopularSongsCache.Row`'s fields), and where it came from ("aurral", "listenBrainz"
    /// or "library"; for tests only, never shown, plan §3 h).
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
        var source: String

        init(_ row: LidarrTopSongs.Row) {
            let song = row.song
            id = song.id; title = song.title; artist = song.artist; artistId = song.artistId
            album = song.album; albumId = song.albumId; duration = song.duration; coverArtId = song.coverArtId
            suffix = song.suffix; bitRate = song.bitRate; source = row.source.rawValue
        }

        var song: Song {
            Song(id: id, title: title, artist: artist, artistId: artistId, album: album, albumId: albumId,
                 duration: duration.isFinite ? max(0, duration) : 0, suffix: suffix, bitRate: bitRate,
                 coverArtId: coverArtId)
        }
    }
}

/// Round 26 K2 (owner, 2026-11-10, items 6–7; D263–D265, D268): one artist page's Top songs for an artist Lidarr has.
/// The saved list shows at once; once the page's Lidarr line says the artist qualifies (`topSongsLidarrArtistId`,
/// D257), a refresh reads the sources in the background, and a complete answer replaces the list in place only when its
/// songs differ (the same songs keep their rows, so nothing flickers or reorders). Without a list (none saved, Lidarr
/// unread, the artist not in Lidarr, or none of their top songs in the library), the page shows its ordinary Top
/// songs (`wantsOrdinary`).
@MainActor @Observable final class LidarrTopSongsModel {
    /// What the page knows so far.
    enum Phase: Equatable {
        /// Lidarr hasn't answered yet: a saved list shows, nothing else waits.
        case waiting
        /// This list is the page's Top songs.
        case shown
        /// The page's ordinary Top songs (D104, or Popular) instead.
        case ordinary
    }

    /// Lidarr's answer for the artist, as the page's line read it.
    enum LidarrAnswer: Sendable, Equatable {
        case answered(ArtistLidarrState)
        /// The read failed or took longer than `AppModel.lidarrTopSongsWait`: the artist can't be confirmed.
        case unread
    }

    private(set) var songs: [Song]
    private(set) var phase: Phase = .waiting
    /// How many times a refresh changed which songs show (tests).
    @ObservationIgnored private(set) var visibleChanges = 0
    @ObservationIgnored let key: String
    @ObservationIgnored let name: String
    @ObservationIgnored let mbid: MBID?
    /// Built offline (D268): the songs on the phone only; the page builds it again once online.
    @ObservationIgnored let offline: Bool
    @ObservationIgnored private let cache: LidarrTopSongsCache?
    @ObservationIgnored private unowned let app: AppModel

    /// `saved`: the saved list as it may show now (already without songs the library or the phone no longer has).
    init(app: AppModel, key: String, name: String, mbid: MBID?, offline: Bool, cache: LidarrTopSongsCache?, saved: [Song]) {
        self.app = app; self.key = key; self.name = name; self.mbid = mbid; self.offline = offline; self.cache = cache
        songs = saved
    }

    /// The page shows this list in place of its ordinary Top songs and Popular.
    var showsList: Bool { !songs.isEmpty }
    /// The page needs its ordinary Top songs (D104 / Popular): there's no list for this artist.
    var wantsOrdinary: Bool { phase == .ordinary && songs.isEmpty }

    /// D264: waits for Lidarr's answer (`lidarr`, at most `AppModel.lidarrTopSongsWait`; the read itself isn't cut short,
    /// so the page's line still shows when it comes), then refreshes when the artist qualifies, at most once every two
    /// minutes per artist in a session unless `fresh` (pull to refresh). Leaving Lidarr drops the saved list; Lidarr
    /// unread keeps it and refreshes nothing.
    func run(fresh: Bool, lidarr: @escaping @MainActor () async -> LidarrAnswer) async {
        let answer = await app.waitForLidarrTopSongsAnswer(lidarr)
        guard !Task.isCancelled else { return }
        switch answer {
        case .unread:
            phase = songs.isEmpty ? .ordinary : .shown
        case .answered(let state):
            guard let lidarrId = state.topSongsLidarrArtistId else { return leave() }
            guard fresh || app.lidarrTopSongsMayRefresh(key) else {
                phase = songs.isEmpty ? .ordinary : .shown
                return
            }
            let result = await app.readLidarrTopSongs(name: name, mbid: mbid, lidarrArtistId: lidarrId, fresh: fresh)
            guard !Task.isCancelled else { return }
            app.noteLidarrTopSongsRefreshed(key)
            apply(result)
        }
    }

    /// D264, D265: a complete refresh replaces the list (in place, only when its songs differ) and is saved; with no songs
    /// the saved entry goes and the ordinary list shows. An incomplete one never replaces a list that shows; with none
    /// showing, its songs show and are saved.
    func apply(_ result: LidarrTopSongs.Result) {
        let fresh = result.rows.map(\.song)
        if result.complete {
            if fresh.isEmpty {
                cache?.remove(key)
                show([])
                phase = .ordinary
            } else {
                show(fresh)
                cache?.save(result.rows, key: key)
                phase = .shown
            }
        } else if !songs.isEmpty {
            phase = .shown   // a server blip never shuffles the list
        } else if !fresh.isEmpty {
            show(fresh)
            cache?.save(result.rows, key: key)
            phase = .shown
        } else {
            phase = .ordinary
        }
    }

    /// D264: Lidarr says the artist doesn't qualify (not in Lidarr, a name-only match, a find on trial): the saved list
    /// goes and the ordinary one shows.
    private func leave() {
        cache?.remove(key)
        show([])
        phase = .ordinary
    }

    /// Replaces the rows only when the songs differ (by id, in order); the same songs take the fresh details silently.
    private func show(_ fresh: [Song]) {
        if fresh.map(\.id) != songs.map(\.id) {
            songs = fresh
            visibleChanges += 1
        } else if fresh != songs {
            songs = fresh
        }
    }
}

/// Round 26 K2 (D263, D264): what lasts for the session: when each artist's list was last refreshed (at most once every
/// two minutes) and Aurral's answers that came back (never a failure, which `artistPreviewSongs` keeps as empty).
/// Tests set the clock and the deadlines' sleep (told which wait it is, so one slow source can be cut on its own).
@MainActor final class LidarrTopSongsSession {
    /// What a deadline is waiting for.
    enum Wait: Sendable { case lidarrAnswer, aurral, listenBrainz, library, lidarrReads, song, search }

    var refreshedAt: [String: Date] = [:]
    var aurral: [MBID: [AurralSong]] = [:]
    var now: () -> Date = { .now }
    var sleep: @Sendable (Wait, Duration) async throws -> Void = { _, limit in try await Task.sleep(for: limit) }

    /// The deadline's sleep for `wait`.
    func sleep(for wait: Wait) -> Deadline.Sleep {
        let sleep = sleep
        return { try await sleep(wait, $0) }
    }

    /// Sign-out: nothing of this account's is kept.
    func forget() {
        refreshedAt = [:]
        aurral = [:]
    }
}
