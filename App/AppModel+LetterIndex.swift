import Foundation
import MagpieCore
import NavidromeKit
import Search

/// The A–Z index over the server-paged lists (priority round P2): Library › Songs and Albums read a window from any
/// offset, and a letter's first offset is found by binary search over the server's own sort, one row per read
/// (`LetterIndex.seek`), so a jump never pages through everything before it.
///
/// Verified on the dev Navidrome (0.64): `/api/song?_sort=title` orders by the folded title (case and diacritics off,
/// "œ" as "oe", digits and most symbols first, other scripts after "z") and keeps leading articles; `order_title=d`
/// filters by prefix but gives no offset, so the seek reads single rows instead (about log2 of the song count).
/// `getAlbumList2?type=alphabeticalByName` orders albums with Navidrome's default articles dropped ("The Cat Is Out"
/// under C), so albums are sectioned the same way.
extension AppModel {
    /// Albums per page of Library › Albums.
    static let albumsPageSize = 60

    /// Songs in title order from server offset `start`.
    func songsWindow(from start: Int) async throws -> PagedRead<Song> {
        let end = start + Self.songsPageSize
        let page = try await request { try await $0.songsPage(start: start, end: end, sort: "title") }
        return PagedRead(items: page.songs, next: end, end: end >= page.total)
    }

    /// Albums A–Z from offset `start`. A short page is the end.
    func albumsWindow(from start: Int) async throws -> PagedRead<Album> {
        let size = Self.albumsPageSize
        let albums = try await request { try await $0.albumList(.alphabeticalByName, size: size, offset: start) }
        return PagedRead(items: albums, next: start + size, end: albums.count < size)
    }

    /// The first song offset at or after `letter` in title order.
    func songOffset(forLetter letter: String) async throws -> Int {
        let total = try await request { try await $0.songTitle(at: 0) }.total
        return try await LetterIndex.seek(letter, total: total) { offset in
            try await self.request { try await $0.songTitle(at: offset) }.title
        }
    }

    /// The first album offset at or after `letter` in Navidrome's album order (articles dropped).
    func albumOffset(forLetter letter: String) async throws -> Int {
        try await LetterIndex.seek(letter, total: nil, ignoringArticles: LetterIndex.navidromeArticles) { offset in
            try await self.request { try await $0.albumList(.alphabeticalByName, size: 1, offset: offset) }.first?.name
        }
    }
}
