import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// A genre's page (spec §4, Task 19): its albums (at most `AppModel.genreAlbumCap`), with Play and Shuffle over its
/// first `AppModel.groupSongCap` songs in server order (offline, the genre's songs on the phone). The songs are fetched
/// when Play or Shuffle is tapped, so a failure there leaves the albums in place. Its menu moves the genre to another
/// group.
struct GenreView: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var albums: Loadable<[Album]> = .loading
    @State private var moving = false
    @State private var fetchingSongs = false
    @State private var songsError: String?
    private let themed = Themed()

    var body: some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.l) {
                Text(name).magpieDisplay(.title).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                playShuffle
                LoadableView(state: albums, retry: load) { albums in
                    if albums.isEmpty {
                        Text(model.isOffline ? OfflineCopy.notOnPhone : "No albums in this genre.")
                            .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    } else {
                        AlbumGrid(albums: albums) { $0.artist }
                    }
                }
            }
            .padding(.vertical, Tokens.Spacing.l)
            .foregroundStyle(themed.palette.inkColor)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Move to group…", systemImage: "folder") { moving = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("genre-menu")
            }
        }
        .sheet(isPresented: $moving) { MoveGenreSheet(genre: name) }
        .task(id: model.offlinePageKey) { await load() }
    }

    /// Play and Shuffle capsules (as `PlayShuffleButtons`), fetching the songs when tapped.
    private var playShuffle: some View {
        VStack(spacing: Tokens.Spacing.s) {
            CapsuleRow {
                wide("Play", symbol: "play.fill") { model.play($0, startAt: 0) }
                wide("Shuffle", symbol: "shuffle") { model.shuffle($0) }
            }
            .disabled(fetchingSongs)
            .padding(.horizontal, Tokens.Spacing.margin)
            if fetchingSongs { ProgressView().accessibilityLabel("Getting songs") }
            if let songsError {
                Text(songsError).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .multilineTextAlignment(.center).padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            }
        }
    }

    private func wide(_ title: String, symbol: String, then start: @escaping ([Song]) -> Void) -> some View {
        CapsuleButton(title, symbol: symbol) { Task { await withSongs(start) } }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(title.lowercased())
    }

    private func withSongs(_ start: ([Song]) -> Void) async {
        fetchingSongs = true
        songsError = nil
        defer { fetchingSongs = false }
        do {
            let songs = try await model.genreSongs(name)
            if songs.isEmpty { songsError = model.isOffline ? OfflineCopy.notOnPhone : "No songs in this genre." }
            start(songs)
        } catch {
            songsError = BrowseErrorCopy.message(for: error)
        }
    }

    private func load() async {
        do {
            albums = .loaded(try await model.genreAlbums(name))
        } catch {
            if albums.value == nil { albums = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }
}
