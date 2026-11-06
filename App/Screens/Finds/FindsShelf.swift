import DesignSystem
import Foundation
import MagpieCore
import Requests

/// The Finds shelf (Task 6.2a), pure so tests can check it: the songs of the Finds library
/// (`libraryId == findsLibraryId`) and the Finds-mode requests still on their way.
///
/// Days left = 7 − whole days since the find arrived (`Song.createdAt`). Nothing leaves by itself in v1
/// (D10): a find past its 7 days stays, at 0. New finds = ready (listed in the Finds library) and not played yet.
struct FindsShelf: Equatable {
    /// The sample window, in days.
    static let sampleDays = 7

    struct Item: Equatable, Identifiable {
        let song: Song
        let daysLeft: Int
        let isNew: Bool
        /// The ready request Keep goes through (Task 6.2b); nil when there is none or a Keep is under way, and
        /// then the row offers no Keep.
        let keepRequest: RequestID?
        /// The ready request Not for me goes through (Task 6.2c); nil when the row offers none (G6: not for
        /// existing-artist or fallback requests, nor while a Keep or Not for me is under way or needs a look).
        let notForMeRequest: RequestID?
        /// Round 18: no request is on it any more; Not for me puts one back first (`FindsShelf.needsRecovery`).
        var needsRecovery = false

        var id: String { song.id }
        /// A round record with a text status and a symbol (D3).
        var state: RowState { isNew ? .newFind : .find(daysLeft: daysLeft) }
        /// Finds come in at Fast Start quality: the "Sample" hallmark.
        var quality: Quality { .sample }
    }

    /// Round 18 (owner): an album asked for with Try this album shows as one album (its songs inside it), not as songs.
    struct AlbumGroup: Equatable, Identifiable {
        /// The library's album id.
        let id: String
        let title: String
        let artist: String
        let coverArtId: String?
        /// In track order.
        let items: [Item]
        /// Not for me lets the whole album go: the request it goes through (any of its songs' rows would).
        let notForMeRequest: RequestID?

        var isNew: Bool { items.contains(where: \.isNew) }
        var daysLeft: Int { items.map(\.daysLeft).max() ?? 0 }
        var songs: [Song] { items.map(\.song) }
    }

    /// Every find song (the car, the badge, playing the shelf): new ones, then the rest.
    var newFinds: [Item]
    var finds: [Item]
    /// Round 18: the finds asked for as albums. Their songs are in `newFinds`/`finds` too; `songs` leaves them out.
    var albums: [AlbumGroup]
    var onTheirWay: [MagpieRequest]

    /// The finds asked for one song at a time (Songs), new ones first.
    var newSongs: [Item] { newFinds.filter { !inAlbums.contains($0.id) } }
    var songs: [Item] { finds.filter { !inAlbums.contains($0.id) } }
    private var inAlbums: Set<String> { Set(albums.flatMap { $0.items.map(\.id) }) }

    var isEmpty: Bool { newFinds.isEmpty && finds.isEmpty && onTheirWay.isEmpty }

    /// Newest first; a song without a date last.
    init(songs: [Song], requests: [MagpieRequest], played: Set<String>, now: Date) {
        let items = songs.map { song in
            Item(song: song, daysLeft: song.createdAt.map { Self.daysLeft(since: $0, now: now) } ?? Self.sampleDays,
                 isNew: !played.contains(song.id), keepRequest: Self.keepRequest(for: song, in: requests),
                 notForMeRequest: Self.notForMeRequest(for: song, in: requests, songs: songs),
                 needsRecovery: Self.needsRecovery(song, in: requests, songs: songs))
        }.sorted { ($0.song.createdAt ?? .distantPast) > ($1.song.createdAt ?? .distantPast) }
        newFinds = items.filter(\.isNew)
        finds = items.filter { !$0.isNew }
        onTheirWay = requests.filter { $0.isFind && $0.isActive }
        albums = Self.albumGroups(items, requests: requests, songs: songs)
    }

    /// Round 18: how each find was asked for. A song whose request (its own, else one of a song of the same album) was
    /// Try this album (`albumTarget`) belongs to that album; the rest are songs. Albums newest first.
    static func albumGroups(_ items: [Item], requests: [MagpieRequest], songs: [Song]) -> [AlbumGroup] {
        let albumAsked = Set(requests.filter { $0.albumTarget != nil && ($0.state == .ready || $0.isActive) }
            .compactMap(\.songId).compactMap { id in songs.first { $0.id == id }?.albumId })
        let grouped = Dictionary(grouping: items.filter { $0.song.albumId.map(albumAsked.contains) == true },
                                 by: { $0.song.albumId ?? "" })
        return grouped.map { album, members in
            let sorted = members.sorted { ($0.song.disc ?? 0, $0.song.track ?? 0) < ($1.song.disc ?? 0, $1.song.track ?? 0) }
            let first = sorted[0].song
            return AlbumGroup(id: album, title: first.album, artist: first.artist, coverArtId: first.coverArtId,
                              items: sorted, notForMeRequest: sorted.lazy.compactMap(\.notForMeRequest).first)
        }.sorted { a, b in
            let at = a.items.compactMap(\.song.createdAt).max() ?? .distantPast
            let bt = b.items.compactMap(\.song.createdAt).max() ?? .distantPast
            return at != bt ? at > bt : a.title < b.title
        }
    }

    /// The ready request on this song with no Keep under way (the runner checks everything else on fresh state).
    static func keepRequest(for song: Song, in requests: [MagpieRequest]) -> RequestID? {
        requests.last {
            $0.state == .ready && $0.songId == song.id && $0.keep == nil && !$0.keepNeedsAttention && $0.lidarrArtistId != nil
                && $0.notForMe == nil && !$0.notForMeNeedsAttention
        }?.id
    }

    /// The ready find on this song, with nothing under way for it; else (round 18) the ready find of another song of the
    /// same album in the Finds library (`songs`): Not for me lets the whole release go, so the release's other songs
    /// (and a second song of a find's artist, or one round 17 brought in on another release) go through it too.
    /// The runner proves everything else on fresh state before anything is deleted.
    static func notForMeRequest(for song: Song, in requests: [MagpieRequest], songs: [Song] = []) -> RequestID? {
        func free(_ r: MagpieRequest) -> Bool {
            r.state == .ready && r.isFind && r.lidarrArtistId != nil && r.albumId != nil && r.keep == nil
                && !r.keepNeedsAttention && r.notForMe == nil && !r.notForMeNeedsAttention
        }
        if let own = requests.last(where: { free($0) && $0.songId == song.id }) { return own.id }
        guard let album = song.albumId else { return nil }
        let siblings = Set(songs.filter { $0.albumId == album && $0.id != song.id }.map(\.id))
        return requests.last { free($0) && $0.songId.map(siblings.contains) == true }?.id
    }

    /// Round 18: no request is on this song or its album any more (its Activity row was removed before round 18), and
    /// nothing is under way for one: Not for me first puts its request back (`RequestRunner.recoverFind`).
    static func needsRecovery(_ song: Song, in requests: [MagpieRequest], songs: [Song]) -> Bool {
        let album = song.albumId
        let mine = Set(songs.filter { $0.id == song.id || (album != nil && $0.albumId == album) }.map(\.id) + [song.id])
        return !requests.contains { r in
            r.songId.map(mine.contains) == true
                && (r.state == .ready || r.isActive || r.keep != nil || r.notForMe != nil || r.keepNeedsAttention
                    || r.notForMeNeedsAttention)
        }
    }

    /// 7 − whole days since `created`, between 0 and 7.
    static func daysLeft(since created: Date, now: Date) -> Int {
        // Held to ±1e9 days (NaN reads as today) before `Int(_:)`, which traps past Int or on NaN: `createdAt` comes from
        // the server or a saved copy of it (crash hunt 4).
        let elapsed = now.timeIntervalSince(created) / (24 * 3600)
        let days = elapsed.isNaN ? 0 : Int(min(max(elapsed, -1e9), 1e9).rounded(.down))
        return min(sampleDays, max(0, sampleDays - max(0, days)))
    }
}
