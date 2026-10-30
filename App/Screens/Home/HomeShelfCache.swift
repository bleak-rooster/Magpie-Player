import Foundation
import MagpieCore
import os
import Search

/// Home's last shelves on disk, one small file per account (P5), so Home shows them at once at launch while a read
/// replaces them in the background. Only ids, titles, counts and cover ids: no secrets, no URLs. Lives in
/// Application Support/Magpie/Home, is excluded from backup and is removed on sign-out.
struct HomeShelfCache {
    let url: URL

    /// The file for `scope` (the app's own hex id for an account, never a server string) under `root`.
    init(root: URL, scope: String) {
        url = Self.directory(root: root).appending(path: "\(scope).json")
    }

    static func directory(root: URL) -> URL { root.appending(path: "Magpie/Home", directoryHint: .isDirectory) }

    /// Removes every account's file (sign-out).
    static func removeAll(root: URL) {
        try? FileManager.default.removeItem(at: directory(root: root))
    }

    /// The saved shelves; none when there is no file or it doesn't read. Bounded: at most one shelf per section and
    /// `AppModel.homeShelfSize` tiles each, whatever the file says.
    func load() -> [HomeShelf] {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maxBytes,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == File.currentVersion else { return [] }
        var seen = Set<HomeSection>()
        return file.shelves.prefix(HomeSection.allCases.count).compactMap { shelf in
            guard shelf.section != .madeForYou, seen.insert(shelf.section).inserted else { return nil }
            let items = shelf.items.prefix(AppModel.homeShelfSize).map(\.item)
            return items.isEmpty ? nil : HomeShelf(section: shelf.section, items: Array(items))
        }
    }

    func save(_ shelves: [HomeShelf]) {
        let file = File(version: File.currentVersion,
                        shelves: shelves.map { Shelf(section: $0.section, items: $0.items.map(Item.init)) })
        do {
            try AtomicFile.write(file, to: url)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var saved = url, directory = url.deletingLastPathComponent()
            try saved.setResourceValues(values)
            try directory.setResourceValues(values)
        } catch {
            Log.logger("home").error("cannot save Home's shelves: \(Log.category(of: error), privacy: .public)")
        }
    }

    /// A real file is a few kilobytes; anything far bigger isn't ours.
    static let maxBytes = 256 * 1024

    private struct File: Codable {
        static let currentVersion = 1
        var version: Int
        var shelves: [Shelf]
    }

    private struct Shelf: Codable {
        var section: HomeSection
        var items: [Item]
    }

    /// One tile: what it opens and what it shows.
    private struct Item: Codable {
        enum Kind: String, Codable { case album, downloadedAlbum, playlist, genreGroup }
        var kind: Kind
        var id: String
        var title: String
        var subtitle: String?
        var artistId: String?
        var coverArtId: String?
        var count: Int?

        init(_ item: HomeShelf.Item) {
            switch item {
            case .album(let a), .downloadedAlbum(let a):
                if case .album = item { kind = .album } else { kind = .downloadedAlbum }
                id = a.id; title = a.name; subtitle = a.artist; artistId = a.artistId; coverArtId = a.coverArtId
                count = a.songCount
            case .playlist(let p):
                kind = .playlist; id = p.id; title = p.name; coverArtId = p.coverArtId; count = p.songCount
            case .genreGroup(let g):
                kind = .genreGroup; id = g.group.id; title = g.group.name; count = g.albumCount
            }
        }

        var item: HomeShelf.Item {
            let count = max(0, min(self.count ?? 0, 1_000_000))
            switch kind {
            case .album, .downloadedAlbum:
                let album = Album(id: id, name: title, artist: subtitle ?? "", artistId: artistId, songCount: count,
                                  duration: 0, coverArtId: coverArtId)
                return kind == .album ? .album(album) : .downloadedAlbum(album)
            case .playlist:
                return .playlist(Playlist(id: id, name: title, songCount: count, duration: 0, coverArtId: coverArtId))
            case .genreGroup:
                return .genreGroup(GenreGroupSection(group: GenreGroup(id: id, name: title), genres: [], albumCount: count,
                                                     songCount: 0))
            }
        }
    }
}
