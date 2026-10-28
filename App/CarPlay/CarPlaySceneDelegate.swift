import UIKit
#if canImport(CarPlay)
import CarPlay
import CarPlayUI
import MagpieCore
import Observation

/// The CarPlay scene. Works when Magpie is cold-launched from the car with the phone UI never
/// opened: `AppModel.shared` restores the session from the Keychain on first use, and the
/// controller follows its state (locked, not set up, ready).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?
    private var watch: Task<Void, Never>?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let model = AppModel.shared
        let controller = CarPlayController(interfaceController: interfaceController,
                                           library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        self.controller = controller
        controller.setAvailability(Self.availability(model))
        watch = Task { [weak controller] in
            let states = Observations { @MainActor in Self.availability(model) }
            for await state in states {
                controller?.setAvailability(state)
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        watch?.cancel()
        watch = nil
        controller?.disconnect()
        controller = nil
    }

    @MainActor
    static func availability(_ model: AppModel) -> CarPlayAvailability {
        if model.isWaitingForUnlock { return .locked }
        guard let account = model.artworkScope else { return .notSetUp }
        return .ready(account: account)
    }
}

/// The app's session, artwork cache and recent searches, as CarPlay reads them.
@MainActor
final class CarPlayLibraryAdapter: CarPlayLibrary {
    private let model: AppModel
    private let recents: RecentSearches

    init(model: AppModel, recents: RecentSearches = RecentSearches()) {
        self.model = model
        self.recents = recents
    }

    func albumList(_ type: AlbumListType, size: Int) async throws -> [Album] {
        try await model.request { try await $0.albumList(type, size: size, offset: 0) }
    }

    func album(id: String) async throws -> Album {
        try await model.request { try await $0.album(id: id) }
    }

    func artists() async throws -> [Artist] {
        try await model.request { try await $0.artists() }
    }

    func artist(id: String) async throws -> (Artist, [Album]) {
        let result = try await model.request { client in
            let (artist, albums) = try await client.artist(id: id)
            return ArtistPage(artist: artist, albums: albums)
        }
        return (result.artist, result.albums)
    }

    func playlists() async throws -> [Playlist] {
        try await model.request { try await $0.playlists() }
    }

    func playlist(id: String) async throws -> (Playlist, [Song]) {
        let result = try await model.request { client in
            let (playlist, songs) = try await client.playlist(id: id)
            return PlaylistPage(playlist: playlist, songs: songs)
        }
        return (result.playlist, result.songs)
    }

    func search(_ query: String) async throws -> CarPlaySearchResult { try await model.carPlaySearch(query) }

    /// Server-side sizes match the phone's, so the in-memory cache is shared.
    func artwork(coverArtId: String, pixelSide: Int) async -> UIImage? {
        guard let scope = model.artworkScope else { return nil }
        let size = [120, 300, 600].first { $0 >= pixelSide } ?? 600
        let key = ArtworkCache.key(scope: scope, coverArtId: coverArtId, size: size)
        if let hit = ArtworkCache.shared.cached(key) { return hit }
        guard let url = model.coverArtURL(coverArtId, size: size) else { return nil }
        return await ArtworkCache.shared.image(key: key, url: url)
    }

    func isOutOfReach(_ error: Error) -> Bool { AppModel.isConnectionError(error) }

    var localNetwork: CPLocalNetwork { model.carPlayLocalNetwork }

    var recentSearches: [String] { recents.items }

    func addRecentSearch(_ query: String) { recents.add(query) }

    // Finds, Keep and Try: the phone's own (AppModel+CarPlay.swift).

    var findsShelf: CPFindsShelf? { model.carPlayFinds }

    func refreshFinds() async { await model.refreshFinds() }

    func mayKeep(songId: String) -> Bool { model.carPlayMayKeep(songId: songId) }

    func keep(songId: String) async -> CPKeepResult { await model.carPlayKeep(songId: songId) }

    var tryOffer: CPTryOffer { model.carPlayTryOffer }

    func tryNext(_ recording: ExternalRecording) async -> CPTryResult { await model.tryNext(recording) }

    private struct ArtistPage: Sendable {
        let artist: Artist
        let albums: [Album]
    }

    private struct PlaylistPage: Sendable {
        let playlist: Playlist
        let songs: [Song]
    }
}
#endif
