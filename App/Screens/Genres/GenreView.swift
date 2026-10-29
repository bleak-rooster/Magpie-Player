import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// A genre's page (spec §4, Task 19): its albums, with Play and Shuffle over its first `AppModel.groupSongCap` songs in
/// server order (offline, the genre's songs on the phone). Its menu moves the genre to another group.
struct GenreView: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var page: Loadable<Page> = .loading
    @State private var moving = false
    private let themed = Themed()

    struct Page {
        let albums: [Album]
        let songs: [Song]
    }

    var body: some View {
        ScrollView {
            LoadableView(state: page, retry: load) { page in
                content(page)
            }
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

    private func content(_ page: Page) -> some View {
        let p = themed.palette
        return VStack(spacing: Tokens.Spacing.l) {
            Text(name).magpieDisplay(.title).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            PlayShuffleButtons(songs: page.songs)
            if page.albums.isEmpty {
                Text(model.isOffline ? OfflineCopy.notOnPhone : "No albums in this genre.")
                    .font(.footnote).foregroundStyle(p.ink2Color)
            } else {
                AlbumGrid(albums: page.albums) { $0.artist }
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    private func load() async {
        do {
            async let albums = model.genreAlbums(name)
            async let songs = model.genreSongs(name)
            page = .loaded(Page(albums: try await albums, songs: try await songs))
        } catch {
            if page.value == nil { page = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }
}
