import Foundation
import MagpieCore

/// Round 27 D1 (owner, 2026-11-14, item 2: "When you open discover, it should have all of the flows and aurral
/// playlists loaded then saved. So when you open it again, it can load quickly"; item 3: the slow playlist page): what
/// Discover saves on the phone, per Navidrome account and Aurral user (D283). Pure: the file's model, its bounds, the
/// lookups' lifetimes (D285), the main-library rule (D285) and the background pass's order (D284). The app keeps it in
/// `Application Support/Magpie/Discover/<feeds hash>-lists.json` (`DiscoverSnapshotFile`).
///
/// Only what the rows show, and ids: playlist and song names, artists, albums, lengths, cover ids, owners' usernames.
/// Never a URL, a token, a preview path, an outside id, a MusicBrainz id or a server address. The rows are only what the
/// last read decided (D286): nothing here decides which playlist is Aurral's or whose it is.
public struct DiscoverSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Playlists (rows and saved pages), songs per page, and the file's size (a bigger file reads as none).
    public static let maxPlaylists = 60
    public static let maxSongsPerPage = 500
    public static let maxBytes = 4 * 1024 * 1024
    /// A saved library copy is looked up again after a week (sooner when the match index no longer holds it); a song
    /// with none after a day.
    public static let hitLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let missLifetime: TimeInterval = 24 * 60 * 60

    public var version = DiscoverSnapshot.currentVersion
    /// Library › Discover's playlists, as the last read identified them (server order).
    public var rows: [Row] = []
    /// Round 26 L's item rows (D271), as the last read listed them.
    public var itemRows: [ItemRow] = []
    /// D273's hidden playlists and D189's other users' playlists, as the last read decided.
    public var hiddenPlaylistIds: [String] = []
    public var othersPlaylistIds: [String] = []
    /// Each playlist's page, by playlist id.
    public var pages: [String: Page] = [:]

    public init() {}

    // MARK: - Rows

    /// A playlist as a row shows it.
    public struct SavedPlaylist: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var songCount: Int
        public var duration: TimeInterval
        public var coverArtId: String?
        public var owner: String?
        public var readOnly: Bool?
        public var changed: Date?

        public init(_ playlist: Playlist) {
            id = playlist.id; name = playlist.name; songCount = playlist.songCount; duration = playlist.duration
            coverArtId = playlist.coverArtId; owner = playlist.owner; readOnly = playlist.readOnly; changed = playlist.changed
        }

        public var playlist: Playlist {
            Playlist(id: id, name: name, songCount: max(0, songCount), duration: duration.isFinite ? max(0, duration) : 0,
                     coverArtId: coverArtId, owner: owner, readOnly: readOnly, changed: changed)
        }
    }

    /// What an Aurral item is: a flow, a shared playlist (Add flow's, an import, one made in Aurral), or not known (a
    /// playlist kept without its item, or another user's, which carries no id).
    public enum ItemKind: String, Codable, Sendable { case flow, playlist, unknown }

    /// An Aurral item as Discover uses it: its id, name and owner. Never its recipe, source or schedule.
    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var kind: ItemKind
        public var ownerUserId: Int?
        public var ownerUsername: String?

        public init(_ flow: AurralFlow, kind: ItemKind) {
            id = flow.id; name = flow.name; self.kind = kind; ownerUserId = flow.ownerUserId; ownerUsername = flow.ownerUsername
        }

        public var flow: AurralFlow {
            AurralFlow(id: id, name: name, ownerUserId: ownerUserId, ownerUsername: ownerUsername)
        }
    }

    /// One of Aurral's Navidrome playlists, with the item the last read identified it as, and D205's caption owner.
    public struct Row: Codable, Equatable, Sendable {
        public var playlist: SavedPlaylist
        public var item: Item
        public var caption: String?

        public init(_ discover: DiscoverPlaylist, shared: Bool, caption: String?) {
            playlist = SavedPlaylist(discover.playlist)
            item = Item(discover.flow, kind: discover.flow.id.isEmpty ? .unknown : shared ? .playlist : .flow)
            self.caption = caption
        }

        public var discoverPlaylist: DiscoverPlaylist { DiscoverPlaylist(flow: item.flow, playlist: playlist.playlist) }
    }

    /// Round 26 L (D271): an Aurral item that is a row of its own, and whether it is the signed-in user's.
    public struct ItemRow: Codable, Equatable, Sendable {
        public var item: Item
        public var mine: Bool
        public init(item: Item, mine: Bool) { self.item = item; self.mine = mine }
    }

    // MARK: - Pages

    /// A song as `SongRow` shows it, plus its ids. No MusicBrainz ids, ISRCs or anything else.
    public struct SavedSong: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var artist: String
        public var artistId: String?
        public var album: String
        public var albumId: String?
        public var track: Int?
        public var disc: Int?
        public var duration: TimeInterval
        public var suffix: String?
        public var bitRate: Int?
        public var coverArtId: String?
        public var libraryId: Int?
        public var starred: Bool

        public init(_ song: Song) {
            id = song.id; title = song.title; artist = song.artist; artistId = song.artistId; album = song.album
            albumId = song.albumId; track = song.track; disc = song.disc; duration = song.duration; suffix = song.suffix
            bitRate = song.bitRate; coverArtId = song.coverArtId; libraryId = song.libraryId; starred = song.starred
        }

        public var song: Song {
            Song(id: id, title: title, artist: artist, artistId: artistId, album: album, albumId: albumId, track: track,
                 disc: disc, duration: duration.isFinite ? max(0, duration) : 0, suffix: suffix, bitRate: bitRate,
                 coverArtId: coverArtId, libraryId: libraryId, starred: starred)
        }
    }

    /// One song of a page: the playlist's song, and the main library's copy shown in its place, if found.
    public struct Entry: Codable, Equatable, Sendable {
        public var song: SavedSong
        public var copy: SavedSong?
    }

    /// One song's lookup for its library copy: the copy's id, or none, and when.
    public struct Lookup: Codable, Equatable, Sendable {
        public var copyId: String?
        public var at: Date

        public init(copyId: String?, at: Date) { self.copyId = copyId; self.at = at }

        /// Whether it may be used as it is (D285): a copy for a week while the match index still holds it
        /// (`indexHoldsCopy` nil: no index built, or an empty one), none for a day. A lookup dated after `now` (the
        /// clock moved) is asked again.
        public func isFresh(now: Date, indexHoldsCopy: Bool?) -> Bool {
            let age = now.timeIntervalSince(at)
            guard age >= 0 else { return false }
            if copyId != nil { return age < DiscoverSnapshot.hitLifetime && indexHoldsCopy != false }
            return age < DiscoverSnapshot.missLifetime
        }
    }

    /// A playlist's page as last shown.
    public struct Page: Codable, Equatable, Sendable {
        public var playlist: SavedPlaylist
        public var savedAt: Date
        /// The playlist's own `changed` and its songs' ids when read: a later read with the same is the same page.
        public var changed: Date?
        public var songIds: [String]
        public var entries: [Entry]
        public var lookups: [String: Lookup]

        public init(playlist: Playlist, savedAt: Date, entries: [(song: Song, copy: Song?)], lookups: [String: Lookup]) {
            self.playlist = SavedPlaylist(playlist)
            self.savedAt = savedAt
            changed = playlist.changed
            songIds = entries.map(\.song.id)
            self.entries = entries.map { Entry(song: SavedSong($0.song), copy: $0.copy.map(SavedSong.init)) }
            self.lookups = lookups
        }

        /// The same page: the same `changed` and the same songs in the same order.
        public func matches(changed: Date?, songIds: [String]) -> Bool {
            self.changed == changed && self.songIds == songIds
        }

        /// The entries as the page shows them (the library's copy in place, "In your library").
        public var discoverEntries: [DiscoverEntry] {
            entries.map { DiscoverEntry(song: ($0.copy ?? $0.song).song, original: $0.song.song) }
        }
    }

    // MARK: - Bounds and the file

    /// At most `maxPlaylists` rows and pages (the pages saved longest ago go) and `maxSongsPerPage` songs a page.
    public func bounded() -> DiscoverSnapshot {
        var copy = self
        copy.rows = Array(rows.prefix(Self.maxPlaylists))
        copy.itemRows = Array(itemRows.prefix(Self.maxPlaylists))
        for (id, page) in copy.pages where page.entries.count > Self.maxSongsPerPage || page.songIds.count > Self.maxSongsPerPage {
            var trimmed = page
            trimmed.entries = Array(page.entries.prefix(Self.maxSongsPerPage))
            trimmed.songIds = Array(page.songIds.prefix(Self.maxSongsPerPage))
            let kept = Set(trimmed.songIds)
            trimmed.lookups = page.lookups.filter { kept.contains($0.key) }
            copy.pages[id] = trimmed
        }
        for id in copy.oldestPages().prefix(max(0, copy.pages.count - Self.maxPlaylists)) { copy.pages[id] = nil }
        return copy
    }

    /// The file's bytes: `fitted()`.
    public func encoded() throws -> Data { try JSONEncoder().encode(fitted()) }

    /// Bounded, and with the pages saved longest ago dropped until it encodes within `maxBytes` (a bigger file would
    /// read as none, losing every page).
    public func fitted() throws -> DiscoverSnapshot {
        var copy = bounded()
        let encoder = JSONEncoder()
        var size = try encoder.encode(copy).count
        var oldest = copy.oldestPages().makeIterator()
        while size > Self.maxBytes, let id = oldest.next() {
            // The page, its key and a little punctuation; measured again exactly once the estimate says it fits.
            if let page = copy.pages.removeValue(forKey: id) { size -= try encoder.encode(page).count + id.utf8.count + 4 }
            if size <= Self.maxBytes { size = try encoder.encode(copy).count }
        }
        return copy
    }

    /// The saved file, or nil when it is too big, another version, or doesn't read.
    public static func decode(_ data: Data) -> DiscoverSnapshot? {
        guard data.count <= maxBytes, let snapshot = try? JSONDecoder().decode(DiscoverSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }

    /// Page ids, saved longest ago first (ties by id, so trimming is the same every time).
    private func oldestPages() -> [String] {
        pages.sorted { $0.value.savedAt != $1.value.savedAt ? $0.value.savedAt < $1.value.savedAt : $0.key < $1.key }.map(\.key)
    }

    // MARK: - Rules

    /// D285: a playlist song that is the main library's own file needs no lookup (Aurral 2.13 files a static playlist's
    /// library songs as the library's, D251). Known only once Aurral's libraries are learnt: by the song's library when
    /// the read names it, else by Aurral's library as read in full (`discoverLibrarySongIds`; nil when not read in full).
    /// Fix round 1 (I2): never a song one of the flow's own Aurral jobs names (`flowJobs` of `flowId`: by recording id,
    /// else artist + title, the duration within 3 s when both are known): the flow may have rotated since the last
    /// library read, or the library been learnt later. The app never keeps this answer as a lookup; it is asked anew
    /// each time.
    public static func isOwnLibraryCopy(_ song: Song, discoverLibraries: Set<Int>, discoverLibrarySongIds: Set<String>?,
                                        flowJobs: [AurralJob] = [], flowId: String? = nil) -> Bool {
        guard !discoverLibraries.isEmpty else { return false }
        if let flowId, !flowId.isEmpty, flowJobs.contains(where: { $0.flowId == flowId && isJob($0, of: song) }) { return false }
        if let library = song.libraryId { return !discoverLibraries.contains(library) }
        guard let ids = discoverLibrarySongIds, !ids.isEmpty else { return false }
        return !ids.contains(song.id)
    }

    /// Whether `job` is `song`'s: the same recording id, else the same artist and title (folded) with the durations
    /// within `DiscoverRules.durationTolerance` when both are known.
    static func isJob(_ job: AurralJob, of song: Song) -> Bool {
        if let recording = song.recordingMBID, let track = job.trackMBID { return recording == track }
        guard DiscoverRules.normalised(job.artistName) == DiscoverRules.normalised(song.artist),
              DiscoverRules.normalised(job.trackName) == DiscoverRules.normalised(song.title) else { return false }
        if let duration = job.duration, duration > 0, song.duration > 0 {
            return abs(duration - song.duration) <= DiscoverRules.durationTolerance
        }
        return true
    }

    /// D284: the pages a background pass reads, newest-changed first (never-changed last), at most `limit`; a playlist
    /// whose saved page has the same `changed` and as many songs is skipped without a read.
    public static func pagesToRefresh(rows: [Playlist], saved: [String: Page], limit: Int) -> [String] {
        let ordered = rows.enumerated().sorted { a, b in
            switch (a.element.changed, b.element.changed) {
            case let (x?, y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: a.offset < b.offset
            }
        }.map(\.element)
        var seen = Set<String>()
        return ordered.filter { row in
            guard seen.insert(row.id).inserted else { return false }
            guard let page = saved[row.id], let changed = row.changed else { return true }
            return !(page.changed == changed && page.songIds.count == row.songCount)
        }.prefix(max(0, limit)).map(\.id)
    }
}
