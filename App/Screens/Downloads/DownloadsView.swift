import DesignSystem
import MagpieCore
import Playback
import Search
import SwiftUI

/// Library › Downloads (spec §6, Task 14): what's on the phone, by Albums, Artists, Playlists or Songs, from the
/// snapshots kept with the files, so it works with no server. Songs play from the phone. Genres (Task 19) groups the
/// downloads' genres like Library › Genres.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var catalog: OfflineCatalog?
    @State private var kind = Kind.albums
    @State private var removing: Song?
    private let themed = Themed()

    enum Kind: String, CaseIterable, Identifiable {
        case albums = "Albums", artists = "Artists", playlists = "Playlists", songs = "Songs", genres = "Genres"
        var id: String { rawValue }
    }

    var body: some View {
        let index = index   // once per update (the catalog lists are rebuilt and folded)
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                DownloadingNowLink().padding(.horizontal, Tokens.Spacing.largeTitleMargin)   // P1, while anything downloads
                Picker("Show", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                .accessibilityIdentifier("downloads-kind")
                if model.isOffline {
                    OfflineNotice().padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                }
                if let catalog {
                    content(catalog)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.vertical, Tokens.Spacing.l)
        }
        // P2: offline too, the index runs over what's on the phone.
        .letterIndex(available: Set(index.sections.map(\.key)), hidden: index.sections.isEmpty) { letter in
            guard let target = LetterIndex.target(letter, in: index.sections) else { return }
            proxy.scrollTo(index.ids[target.range.lowerBound], anchor: .top)
        }
        }
        .navigationTitle("Downloads")
        .magpieScreen()
        .songRemovalDialog($removing)
        // Again whenever a song lands on or leaves the phone.
        .task(id: model.downloads?.localFiles.count) { catalog = await model.offlineCatalog }
    }

    @ViewBuilder private func content(_ catalog: OfflineCatalog) -> some View {
        switch kind {
        case .albums:
            let albums = catalog.albums()
            if albums.isEmpty { empty } else { AlbumGrid(albums: albums) { $0.artist } }
        case .artists:
            let artists = catalog.artists()
            if artists.isEmpty { empty } else { rows(artists, id: \.id) { artistRow($0) } }
        case .playlists:
            let playlists = catalog.playlists()
            if playlists.isEmpty { empty } else { rows(playlists, id: \.id) { playlistRow($0) } }
        case .songs:
            let songs = catalog.songs()
            if songs.isEmpty {
                empty
            } else {
                rows(Array(songs.enumerated()), id: \.element.id) { index, song in songRow(song, index: index, in: songs) }
            }
        case .genres:
            let sections = GenreGroups.grouped(catalog.genres(), preferences: model.preferences.genres)
            if sections.isEmpty { empty } else { GenreGroupRows(sections: sections) }
        }
    }

    /// The shown kind's names in list order, and their rows' ids, for the letter index.
    private var index: (sections: [LetterIndex.Section], ids: [String]) {
        guard let catalog else { return ([], []) }
        let rows: [(name: String, id: String)] = switch kind {
        case .albums: catalog.albums().map { ($0.name, $0.id) }
        case .artists: catalog.artists().map { ($0.name, $0.id) }
        case .playlists: catalog.playlists().map { ($0.name, $0.id) }
        case .songs: catalog.songs().map { ($0.title, $0.id) }
        case .genres: GenreGroups.grouped(catalog.genres(), preferences: model.preferences.genres).map { ($0.group.name, $0.group.id) }
        }
        return (LetterIndex.sections(rows) { $0.name }, rows.map(\.id))
    }

    private var empty: some View {
        ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                               description: Text("Albums and playlists you download play here without a connection."))
            .accessibilityIdentifier("downloads-empty")
    }

    private func rows<Item, ID: Hashable, Row: View>(_ items: [Item], id: KeyPath<Item, ID>,
                                                     @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(items, id: id) { item in
                row(item).id(item[keyPath: id])
                Divider().overlay(themed.palette.sepColor).padding(.leading, 76)
            }
        }
    }

    private func artistRow(_ artist: Artist) -> some View {
        NavigationLink(value: Route.artist(id: artist.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Circle().fill(themed.palette.surfaceColor).frame(width: 48, height: 48)
                    .overlay { Image(systemName: "person.fill").foregroundStyle(themed.palette.ink2Color) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(artist.name).font(.body)
                    HStack(spacing: 4) {
                        Text(artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums")
                            .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        DownloadMarkView(model.downloadIndex.listMark(artist: artist))   // P1
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Tokens.Spacing.margin)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .foregroundStyle(themed.palette.inkColor)
        .collectionMenu(.downloadedArtist(artist.id), coverArtId: nil)   // R12
        .collectionSwipeActions(.downloadedArtist(artist.id), in: .stack)   // R12
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        NavigationLink(value: Route.downloadedPlaylist(id: playlist.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(playlist.coverArtId, side: 48) { SleeveArt(image: $0, side: 48) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).font(.body).lineLimit(2)
                    HStack(spacing: 4) {
                        Text(playlist.songCount == 1 ? "1 song" : "\(playlist.songCount) songs")
                            .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        DownloadMarkView(model.downloadIndex.mark(playlistId: playlist.id))   // P1
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Tokens.Spacing.margin)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .foregroundStyle(themed.palette.inkColor)
        .collectionMenu(.downloadedPlaylist(playlist.id), coverArtId: playlist.coverArtId)   // R12, P4
        .collectionSwipeActions(.downloadedPlaylist(playlist.id), in: .stack)   // R12
    }

    private func songRow(_ song: Song, index: Int, in songs: [Song]) -> some View {
        Button { model.play(songs, startAt: index) } label: {
            Artwork(song.coverArtId, side: 48) { SongRow(song: song, state: .library, artwork: $0) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("downloads-song-\(index)")
        .contextMenu {
            SongQueueMenuItems(song: song)
            SongDownloadMenuItem(song: song, removing: $removing)
        }
        // R12: Remove download keeps its trailing place, never on a full swipe; it asks first.
        .songSwipeActions(song, in: .stack,
                          destructive: RowDestructiveAction(title: "Remove download", symbol: "trash") { removing = song })
    }
}
