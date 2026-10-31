import DesignSystem
import MagpieCore
import SwiftUI

/// Library › Favourites (spec §3, Task 21): every starred song (a row plays the starred songs from that one), then
/// every starred album as a grid. Read with `getStarred2`.
struct FavouritesView: View {
    @Environment(AppModel.self) private var model
    @State private var starred: Loadable<Starred> = .loading
    @State private var removing: Song?
    private let themed = Themed()

    var body: some View {
        ScrollView {
            LoadableView(state: starred, retry: load) { starred in
                if starred.songs.isEmpty, starred.albums.isEmpty {
                    ContentUnavailableView("No favourites yet", systemImage: "heart",
                                           description: Text("Songs and albums you star show up here."))
                } else {
                    content(starred)
                }
            }
        }
        .refreshable { await load() }
        .navigationTitle("Favourites")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .songRemovalDialog($removing)
        .task { if starred.value == nil { await load() } }
    }

    private func content(_ starred: Starred) -> some View {
        let p = themed.palette
        let songs = starred.songs
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    heading("Songs")
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                            Button { model.play(songs, startAt: index) } label: {
                                Artwork(song.coverArtId, side: 48) { image in
                                    SongRow(song: song, state: .library, artwork: image)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("favourite-song-\(index)")
                            .contextMenu { SongDownloadMenuItem(song: song, removing: $removing) }
                            .songSwipeActions(song, in: .stack)   // R12
                            Divider().overlay(p.sepColor).padding(.leading, 76)
                        }
                    }
                }
            }
            if !starred.albums.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    heading("Albums")
                    AlbumGrid(albums: starred.albums) { $0.artist }
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    private func heading(_ title: String) -> some View {
        Text(title).magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
    }

    private func load() async {
        do {
            starred = .loaded(try await model.favourites())
        } catch {
            if starred.value == nil { starred = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }
}
