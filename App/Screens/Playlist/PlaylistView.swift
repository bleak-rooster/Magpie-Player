import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// Playlist: cover, name in the display face, song count and length, Play / Shuffle, songs.
struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    let playlistId: String
    /// Opened from Downloads: the playlist as downloaded, only its songs on the phone, online too (T23).
    var fromPhone = false
    @State private var page: Loadable<Page> = .loading
    /// Whether what is shown came from the phone (offline) or the server; a change of offline mode loads again.
    @State private var loadedOffline: Bool?
    @State private var removing: Song?
    private let themed = Themed()

    struct Page {
        var playlist: Playlist
        var songs: [Song]
    }

    var body: some View {
        ScrollView {
            LoadableView(state: page, retry: load) { page in
                content(page)
            }
        }
        .navigationTitle(page.value?.playlist.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .songRemovalDialog($removing)
        // Again when offline mode changes, and offline when songs land on or leave the phone (the store may be
        // unreadable before first unlock): the downloaded songs offline, the server's online.
        .task(id: model.offlinePageKey) {
            if page.value == nil || loadedOffline != model.isOffline || model.isOffline { await load() }
        }
    }

    private func content(_ page: Page) -> some View {
        let p = themed.palette
        let songs = page.songs
        let minutes = DurationText.minutes(page.playlist.duration > 0 ? page.playlist.duration
                                                                       : songs.reduce(0) { $0 + $1.duration })
        return VStack(spacing: Tokens.Spacing.l) {
            VStack(spacing: Tokens.Spacing.s) {
                Artwork(page.playlist.coverArtId, side: 220) { SleeveArt(image: $0, side: 220) }
                    .reloadArtworkMenu(page.playlist.coverArtId)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .padding(.bottom, Tokens.Spacing.s)
                Text(page.playlist.name).magpieDisplay(.title).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs") · \(minutes) min")
                    .font(theme.numberFont(.footnote)).foregroundStyle(p.ink2Color)
                DownloadMarkLine(model.downloadIndex.mark(playlistId: page.playlist.id, songIds: songs.map(\.id)))
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)

            PlayShuffleButtons(songs: songs)
            DownloadButton(reason: .playlist(page.playlist.id), songs: songs,
                           playlist: DownloadedPlaylist(id: page.playlist.id, name: page.playlist.name,
                                                        coverArtId: page.playlist.coverArtId,
                                                        songIds: songs.map(\.id), savedAt: .now),
                           coverArtId: page.playlist.coverArtId)

            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    Button { model.play(songs, startAt: index) } label: {
                        Artwork(song.coverArtId, side: 48) { image in
                            SongRow(song: song, state: .library, artwork: image)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("track-\(index)")
                    .contextMenu { SongDownloadMenuItem(song: song, removing: $removing) }
                    Divider().overlay(p.sepColor).padding(.leading, 76)
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    private func load() async {
        loadedOffline = model.isOffline
        if model.isOffline || fromPhone {   // Task 14: the playlist as downloaded, its songs on the phone
            let catalog = await model.offlineCatalog
            guard let playlist = catalog.playlists().first(where: { $0.id == playlistId }) else {
                page = .failed(OfflineCopy.notOnPhone)
                return
            }
            page = .loaded(Page(playlist: playlist, songs: catalog.songs(inPlaylist: playlistId)))
            return
        }
        do {
            let (playlist, songs) = try await model.request { [playlistId] in try await $0.playlist(id: playlistId) }
            page = .loaded(Page(playlist: playlist, songs: songs))
            // Loaded with a connection: a downloaded playlist follows the server's version.
            await model.refreshDownloadedPlaylist(playlist, songs: songs)
        } catch {
            page = .failed(BrowseErrorCopy.message(for: error))
        }
    }
}
