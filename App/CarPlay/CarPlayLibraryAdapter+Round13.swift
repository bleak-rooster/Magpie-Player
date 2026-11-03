import Foundation
#if canImport(CarPlay)
import CarPlayUI
import MagpieCore

/// Round 13: the car's third tab (Settings › CarPlay) and Songs on its letter groups. Songs are read by offset from the
/// server's title order, as the phone's Library › Songs reads them (`/api/song?_sort=title`, the library chosen);
/// offline, from the phone's songs put in that order, with nothing asked of the server.
extension CarPlayLibraryAdapter {
    var carPlayTab: CarPlayTab { model.preferences.carPlay.tab(discoverSetUp: model.aurralSetUp) }

    func songIndex() async throws -> CPSongIndex {
        if model.isOffline { return CPSongIndex(sortedTitles: await offlineSongsByTitle().map(\.title)) }
        let model = model
        let total = try await model.request { try await $0.songTitle(at: 0) }.total
        return try await CPSongIndex.read(total: total) { offset in
            try await model.request { try await $0.songTitle(at: offset) }.title
        }
    }

    func songsByTitle(offset: Int, size: Int) async throws -> [Song] {
        guard size > 0 else { return [] }
        if model.isOffline { return Array(await offlineSongsByTitle().dropFirst(max(0, offset)).prefix(size)) }
        return try await model.request { try await $0.songsPage(start: offset, end: offset + size, sort: "title") }.songs
    }

    private func offlineSongsByTitle() async -> [Song] {
        CPSongIndex.titleOrder(await model.offlineCatalog.songs().map { ($0, $0.title) }).map(\.0)
    }
}
#endif
