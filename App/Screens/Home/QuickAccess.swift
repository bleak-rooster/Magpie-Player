import Foundation
import MagpieCore
import NavidromeKit
import os

/// Round 14 A6: an album, playlist or flow played from its page, for Home's quick-access grid. Plain values: no URL.
struct RecentPlay: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case album, playlist }

    var kind: Kind
    var itemId: String
    var title: String
    var subtitle: String?
    var coverArtId: String?
    /// When it was played; nil for an album from the server's recently played list.
    var playedAt: Date?

    var id: String { "\(kind.rawValue)-\(itemId)" }

    static func album(_ album: Album, at date: Date? = nil) -> RecentPlay {
        RecentPlay(kind: .album, itemId: album.id, title: album.name, subtitle: album.artist, coverArtId: album.coverArtId,
                   playedAt: date)
    }

    static func playlist(_ playlist: Playlist, at date: Date? = nil) -> RecentPlay {
        RecentPlay(kind: .playlist, itemId: playlist.id, title: playlist.name, subtitle: nil,
                   coverArtId: playlist.coverArtId, playedAt: date)
    }
}

enum QuickAccess {
    /// What the history file keeps.
    static let historyLimit = 16

    /// The grid (D108): what was played on this phone most recently first (albums, playlists, flows), then the server's
    /// recently played albums not already there, at most `count`.
    static func tiles(history: [RecentPlay], recentAlbums: [Album], count: Int) -> [RecentPlay] {
        var seen = Set<String>()
        let played = history.sorted { ($0.playedAt ?? .distantPast) > ($1.playedAt ?? .distantPast) }
        let server = recentAlbums.map { RecentPlay.album($0) }
        return Array((played + server).filter { seen.insert($0.id).inserted }.prefix(max(0, count)))
    }

    /// `play` added to the front of `history`, any older copy of it removed, capped at `historyLimit`.
    static func noting(_ play: RecentPlay, in history: [RecentPlay]) -> [RecentPlay] {
        Array(([play] + history.filter { $0.id != play.id }).prefix(historyLimit))
    }
}

/// The quick grid's history on disk, one small file per account next to Home's saved shelves (so sign-out removes it
/// with them). Ids, titles and cover ids only.
struct QuickAccessStore {
    let url: URL

    init(root: URL, scope: String) {
        url = HomeShelfCache.directory(root: root).appending(path: "\(scope).recent.json")
    }

    /// The saved history; none when there is no file or it doesn't read. Bounded whatever the file says.
    func load() -> [RecentPlay] {
        guard let data = try? Data(contentsOf: url), data.count <= HomeShelfCache.maxBytes,
              let plays = try? JSONDecoder().decode([RecentPlay].self, from: data) else { return [] }
        var seen = Set<String>()
        return Array(plays.filter { seen.insert($0.id).inserted }.prefix(QuickAccess.historyLimit))
    }

    func save(_ plays: [RecentPlay]) {
        do {
            try AtomicFile.write(plays, to: url)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var saved = url
            try saved.setResourceValues(values)
        } catch {
            Log.logger("home").error("cannot save the quick grid: \(Log.category(of: error), privacy: .public)")
        }
    }
}

extension AppModel {
    /// Played from an album's, playlist's or flow's page: it heads Home's quick grid.
    func noteRecentlyPlayed(_ play: RecentPlay?) {
        guard let play else { return }
        homeFeed.notePlayed(play)
    }

    /// The quick grid's tiles now: the history and the Quick access shelf's albums.
    func quickAccessTiles(recentAlbums: [Album]) -> [RecentPlay] {
        QuickAccess.tiles(history: homeFeed.recentPlays, recentAlbums: recentAlbums,
                          count: preferences.layout.style(for: .quickAccess).count)
    }
}
