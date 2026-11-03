import DesignSystem
import MagpieCore
import SwiftUI

/// Library › Favourites (spec §3, Task 21; round 11 R7): every favourite song (a row plays the favourite songs from
/// that one), then albums as a grid, then artists. Read with `getStarred2`. Something unfavourited here leaves the list
/// at once.
struct FavouritesView: View {
    @Environment(AppModel.self) private var model
    @State private var starred: Loadable<Starred> = .loading
    @State private var removing: Song?
    private let themed = Themed()

    var body: some View {
        ScrollView {
            LoadableView(state: starred, retry: load) { starred in
                let shown = visible(starred)
                if shown.songs.isEmpty, shown.albums.isEmpty, shown.artists.isEmpty {
                    ContentUnavailableView("No favourites yet", systemImage: "heart",
                                           description: Text("Songs, albums and artists you favourite show up here."))
                } else {
                    content(shown)
                }
            }
        }
        .refreshable { await RefreshSafety.run { await load() } }   // Round 13 Z2
        .navigationTitle("Favourites")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .songRemovalDialog($removing)
        .task { if starred.value == nil { await load() } }
    }

    /// What is still a favourite (the session's changes applied).
    private func visible(_ starred: Starred) -> Starred {
        Starred(songs: starred.songs.filter(model.isStarred),
                albums: starred.albums.filter { model.isFavourite(.album($0.id), given: true) },
                artists: starred.artists.filter { model.isFavourite(.artist($0.id), given: true) })
    }

    private func content(_ starred: Starred) -> some View {
        let p = themed.palette
        let songs = starred.songs
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
            // Y7 phase 2: Play and Shuffle over the favourite songs, as on every other page.
            if !songs.isEmpty { ActionBar { PlayShuffleButtons(songs: songs) } }
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
                            .contextMenu { SongQueueMenuItems(song: song); SongDownloadMenuItem(song: song, removing: $removing) }
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
            if !starred.artists.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    heading("Artists")
                    LazyVStack(spacing: 0) {
                        ForEach(Array(starred.artists.enumerated()), id: \.element.id) { index, artist in
                            artistRow(artist)
                                .accessibilityIdentifier("favourite-artist-\(index)")
                            Divider().overlay(p.sepColor).padding(.leading, 76)
                        }
                    }
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    private func artistRow(_ artist: Artist) -> some View {
        NavigationLink(value: Route.artist(id: artist.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(artist.coverArtId, side: 48) { SleeveArt(image: $0, side: 48).clipShape(Circle()) }
                Text(artist.name).font(.body).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Tokens.Spacing.margin)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .artistMenu(artist)
    }

    private func heading(_ title: String) -> some View {
        Text(title).magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
    }

    private func load() async {
        do {
            starred = .loaded(try await model.favourites())
        } catch {
            starred = starred.failing(error)   // Round 13 Z2: also never for a load cut short
        }
    }
}
