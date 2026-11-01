import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// Playlist: cover, name in the display face, song count and length, Play / Shuffle, the Download capsule, songs.
/// Round 11 R8: the ⋯ menu (`PlaylistMoreMenu`: only the items that don't change it on a playlist the user doesn't
/// own, which says who made it), and on the user's own a row's swipe "Remove from playlist" (never a full swipe).
struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let playlistId: String
    /// Opened from Downloads: the playlist as downloaded, only its songs on the phone, online too (T23).
    var fromPhone = false
    @State private var page: Loadable<Page> = .loading
    /// Whether what is shown came from the phone (offline) or the server; a change of offline mode loads again.
    @State private var loadedOffline: Bool?
    @State private var removing: Song?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var editError: String?
    private let themed = Themed()

    struct Page {
        var playlist: Playlist
        var songs: [Song]
    }

    var body: some View {
        List {
            LoadableView(state: page, retry: load) { page in
                content(page)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(page.value?.playlist.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let page = page.value, !fromPhone {
                ToolbarItem(placement: .topBarTrailing) {
                    PlaylistMoreMenu(playlist: page.playlist, songs: page.songs,
                                     rename: { newName = page.playlist.name; renaming = true },
                                     delete: { confirmingDelete = true })
                }
            }
        }
        .magpieScreen()
        .songRemovalDialog($removing)
        .alert("Rename playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { edit { try await model.renamePlaylist($0, to: newName) } }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(PlaylistCopy.deleteTitle(page.value?.playlist.name ?? ""), isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete playlist", role: .destructive) {
                edit { playlist in
                    try await model.deletePlaylist(playlist)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PlaylistCopy.deleteMessage)
        }
        .alert("Couldn't change the playlist", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editError ?? "")
        }
        // Again when offline mode changes, and offline when songs land on or leave the phone (the store may be
        // unreadable before first unlock): the downloaded songs offline, the server's online.
        .task(id: model.offlinePageKey) {
            if page.value == nil || loadedOffline != model.isOffline || model.isOffline { await load() }
        }
        // R8: again after a change to any playlist (this one's songs, name).
        .onChange(of: model.libraryEdits.playlistsRevision) { Task { await load() } }
    }

    @ViewBuilder private func content(_ page: Page) -> some View {
        let p = themed.palette
        let songs = page.songs
        let minutes = DurationText.minutes(page.playlist.duration > 0 ? page.playlist.duration
                                                                       : songs.reduce(0) { $0 + $1.duration })
        let editable = !fromPhone && model.canEdit(page.playlist)
        VStack(spacing: Tokens.Spacing.l) {
            VStack(spacing: Tokens.Spacing.s) {
                Artwork(page.playlist.coverArtId, side: 220) { SleeveArt(image: $0, side: 220) }
                    .reloadArtworkMenu(page.playlist.coverArtId)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .padding(.bottom, Tokens.Spacing.s)
                Text(page.playlist.name).magpieDisplay(.title).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs") · \(minutes) min")
                    .font(theme.numberFont(.footnote)).foregroundStyle(p.ink2Color)
                if !editable, !fromPhone, !model.isOffline, let owner = page.playlist.owner {
                    Text(PlaylistCopy.madeBy(owner)).font(.footnote).foregroundStyle(p.ink2Color)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("playlist-read-only")
                }
                DownloadMarkLine(model.downloadIndex.mark(playlistId: page.playlist.id, songIds: songs.map(\.id)))
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)

            PlayShuffleButtons(songs: songs)
            DownloadButton(reason: .playlist(page.playlist.id), songs: songs, playlist: snapshot(page),
                           coverArtId: page.playlist.coverArtId)
        }
        .padding(.vertical, Tokens.Spacing.l)
        .frame(maxWidth: .infinity)
        .foregroundStyle(p.inkColor)

        ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
            VStack(spacing: 0) {
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
            .foregroundStyle(p.inkColor)
            // R8: a tap on Remove (no full swipe) is the confirmation. The row leaves at once; the server checks the
            // song is still at that position (review fix I2), and the list reads again after.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if editable {
                    Button("Remove from playlist", systemImage: "minus.circle", role: .destructive) {
                        remove(at: index, song)
                    }
                }
            }
        }
        Color.clear.frame(height: Tokens.Spacing.l)
    }

    private func snapshot(_ page: Page) -> DownloadedPlaylist {
        DownloadedPlaylist(id: page.playlist.id, name: page.playlist.name, coverArtId: page.playlist.coverArtId,
                           songIds: page.songs.map(\.id), savedAt: .now)
    }

    /// A change to this playlist on the server; a failure says why, and the page reads again.
    private func edit(_ change: @escaping (Playlist) async throws -> Void) {
        guard let playlist = page.value?.playlist else { return }
        Task {
            do { try await change(playlist) } catch {
                editError = PlaylistEditError.message(for: error)
                await load()
            }
        }
    }

    /// The row animates out now (the appraisal's §6); the model removes it on the server, one edit at a time.
    private func remove(at index: Int, _ song: Song) {
        guard var shown = page.value, shown.songs.indices.contains(index), shown.songs[index].id == song.id else { return }
        shown.songs.remove(at: index)
        withAnimation { page = .loaded(shown) }
        edit { try await model.removeSong(at: index, songId: song.id, from: $0) }
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
            // Deleted (here or elsewhere): nothing to show; the list behind reads again.
            if page.value == nil { page = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }
}
