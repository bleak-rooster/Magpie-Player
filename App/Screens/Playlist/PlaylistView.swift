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
        /// Round 28 O3 (D341): where the page came from; on the phone's page, its kind and how many songs are here.
        var source: PageSource = .server
        var kind: OfflinePlaylistKind = .playlist
        var onPhone = 0
        var total: Int?
    }

    /// Round 28 O3: the page as one load shows it.
    typealias Shown = Page

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
        // Y3 (item 4): the playlist again, its cover colours forgotten, after a quick scan picks up new downloads.
        // Round 13 Z2: in a task of its own, and a load cut short never shows an error (RefreshSafety).
        .refreshable {
            await RefreshSafety.run { await model.refreshPage(coverArtIds: [page.value?.playlist.coverArtId]) { await load() } }
        }
        .navigationTitle(page.value?.playlist.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let page = page.value, !fromPhone {
                ToolbarItem(placement: .topBarTrailing) {
                    // Round 28 O3 (D341): on the phone's page only what works there (Add to queue).
                    PlaylistMoreMenu(playlist: page.playlist, songs: page.songs, onServer: page.source == .server,
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
        let editable = Self.isEditable(canEdit: model.canEdit(page.playlist), fromPhone: fromPhone, source: page.source)
            && !model.isOffline
        if page.source == .phoneCopy { PhoneCopyNote() }   // round 28 O3 (D341)
        VStack(spacing: Tokens.Spacing.l) {
            VStack(spacing: Tokens.Spacing.s) {
                Artwork(page.playlist.coverArtId, side: 220) { SleeveArt(image: $0, side: 220) }
                    .reloadArtworkMenu(page.source == .server ? page.playlist.coverArtId : nil)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .padding(.bottom, Tokens.Spacing.s)
                Text(page.playlist.name).magpieDisplay(.title).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs") · \(minutes) min")
                    .font(theme.numberFont(.footnote)).foregroundStyle(p.ink2Color)
                if page.source.isPhone {
                    // Round 28 O3 (D341, D205 offline too): who made another user's playlist or flow (a flow's owner is
                    // its saved caption, which already leaves your own out), and how many of its songs are here.
                    OwnerCaption(owner: page.playlist.owner,
                                 signedInUser: page.kind == .playlist ? model.session?.username : nil)
                    OnPhoneCountLine(onPhone: page.onPhone, total: page.total)
                } else if !editable, !fromPhone, !model.isOffline, let owner = page.playlist.owner {
                    Text(PlaylistCopy.madeBy(owner)).font(.footnote).foregroundStyle(p.ink2Color)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("playlist-read-only")
                }
                DownloadMarkLine(model.downloadIndex.mark(playlistId: page.playlist.id, songIds: songs.map(\.id)))
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)

            VStack(spacing: Tokens.Spacing.s) {
                ActionBar {
                    PlayShuffleButtons(songs: songs, recent: fromPhone ? nil : .playlist(page.playlist))   // round 14
                    // Round 28 O3 (D341): on the phone's page only once there is a download to remove.
                    if AlbumView.showsDownload(page.source, status: model.downloadStatus(songs.map(\.id),
                                                                                         reason: .playlist(page.playlist.id))) {
                        DownloadButton(reason: .playlist(page.playlist.id), songs: songs, playlist: snapshot(page),
                                       coverArtId: page.playlist.coverArtId)
                    }
                }
                DownloadNote(reason: .playlist(page.playlist.id), songs: songs)
            }
            if editable { LibraryCopyBanner(playlist: page.playlist, songs: songs) }   // Y6
        }
        .padding(.vertical, Tokens.Spacing.l)
        .frame(maxWidth: .infinity)
        .foregroundStyle(p.inkColor)

        ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
            VStack(spacing: 0) {
                Button {
                    if !fromPhone { model.noteRecentlyPlayed(.playlist(page.playlist)) }   // round 14: the quick grid
                    model.play(songs, startAt: index)
                } label: {
                    Artwork(song.coverArtId, side: 48) { image in
                        SongRow(song: song, state: .library, artwork: image)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("track-\(index)")
                .contextMenu { SongQueueMenuItems(song: song); SongDownloadMenuItem(song: song, removing: $removing) }
                Divider().overlay(p.sepColor).padding(.leading, 76)
            }
            .foregroundStyle(p.inkColor)
            // R12 swipes; R8: Remove from playlist keeps the trailing edge's outer place, never on a full swipe, so a
            // tap on it is the confirmation. The row leaves at once; the server checks the song is still at that
            // position (review fix I2), and the list reads again after.
            .songSwipeActions(song, in: .list, destructive: editable
                              ? RowDestructiveAction(title: "Remove from playlist", symbol: "minus.circle") { remove(at: index, song) }
                              : nil)
        }
        if !fromPhone, !model.isOffline, page.source == .server { ComingRows(playlistId: page.playlist.id) }   // R14 A3
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

    /// Round 28 O3 (D341): whether the page may change the playlist (rename, delete, remove a song): the user's own, on
    /// the server's page; never on the phone's copy or offline.
    static func isEditable(canEdit: Bool, fromPhone: Bool, source: PageSource) -> Bool {
        canEdit && !fromPhone && source == .server
    }

    private func load() async {
        loadedOffline = model.isOffline
        await Self.load(model, playlistId: playlistId, fromPhone: fromPhone) { outcome in
            switch outcome {
            case .shown(let new): page = .loaded(new)
            case .notOnPhone: page = .failed(OfflineCopy.notOnPhone)
            // Deleted (here or elsewhere): nothing to show; the list behind reads again.
            case .failed(let error): page = page.failing(error, noticeTo: model)   // Round 13 Z2: never for a load cut short
            }
        }
    }

    /// Round 28 O3 (D341): what one load of the page gives.
    enum Outcome {
        case shown(Page)
        /// From the phone, with none of its songs on the phone.
        case notOnPhone
        case failed(any Error)
    }

    /// Round 28 O3 (D341, D343): one load of the playlist page, handed to `show`, then (online) recorded for the phone.
    /// Offline, or opened from Downloads (T23): the phone's page: a flow on the phone (O2's `offlineFlowPage`, from the
    /// saved Discover file) or a downloaded or recorded playlist (`playlistPage`, Q3). Online: the server's, a downloaded
    /// playlist following it (`readPlaylistPage`); a failed read (but one cut short, D77) shows the phone's copy when it
    /// has one. The record goes into the downloads captured **before** the read (O2, security M3).
    static func load(_ model: AppModel, playlistId: String, fromPhone: Bool, show: (Outcome) -> Void) async {
        if model.isOffline || fromPhone {
            show(await phonePage(model, playlistId: playlistId, source: .phone).map(Outcome.shown) ?? .notOnPhone)
            return
        }
        let target = model.downloads
        do {
            // Loaded with a connection: a downloaded playlist follows the server's version. Round 28 O2 fix round 2 (SN5):
            // into the downloads as they were before the read (`readPlaylistPage`).
            let (playlist, songs) = try await model.readPlaylistPage(id: playlistId)
            show(.shown(Page(playlist: playlist, songs: songs)))
            await model.recordPlaylistPage(playlist, songs: songs, kind: .playlist, into: target)   // O2's D333, Q3
        } catch {
            if PageSource.fallsBack(after: error), let copy = await phonePage(model, playlistId: playlistId, source: .phoneCopy) {
                show(.shown(copy))
            } else {
                show(.failed(error))
            }
        }
    }

    /// Round 28 O3 (D341, D343): the phone's page: a flow listed offline first (its songs, library copies where
    /// downloaded, and its owner from the saved caption), else the downloaded or recorded playlist.
    private static func phonePage(_ model: AppModel, playlistId: String, source: PageSource) async -> Page? {
        if let flow = await model.offlineFlowPage(id: playlistId) {
            return Page(playlist: flow.playlist, songs: flow.songs, source: source, kind: flow.kind,
                        onPhone: flow.onPhone, total: flow.total)
        }
        guard let page = await model.offlineCatalog.playlistPage(id: playlistId) else { return nil }
        return Page(playlist: page.playlist, songs: page.songs, source: source, kind: page.kind,
                    onPhone: page.onPhone, total: page.total)
    }
}
