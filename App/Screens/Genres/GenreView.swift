import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// A genre's page (spec §4, Task 19): its albums (at most `AppModel.genreAlbumCap`), with Play and Shuffle over its
/// first `AppModel.groupSongCap` songs in server order (offline, the genre's songs on the phone). The songs are fetched
/// when Play or Shuffle is tapped, so a failure there leaves the albums in place. Its menu moves the genre to another
/// group. Round 15 C4 (D141–D145): the albums are sorted and filtered (sort, decade, album or artist, Favourites,
/// Downloaded) and read a page at a time.
struct GenreView: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var browser = GenreAlbumBrowser(kind: .genre)
    @State private var text = ""
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
                GenreAlbumControls(browser: browser)
                GenreAlbumList(browser: browser, emptyText: "No albums in this genre.")
            }
            .padding(.vertical, Tokens.Spacing.l)
            .foregroundStyle(themed.palette.inkColor)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $text, prompt: "Album or artist")
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
        .task(id: text) { await browser.setText(text) }
    }

    /// Play and Shuffle in the ActionBar (as on Album), fetching the songs when tapped.
    private var playShuffle: some View {
        VStack(spacing: Tokens.Spacing.s) {
            ActionBar {
                PlayShuffleActions(disabled: fetchingSongs) {
                    Task { await withSongs { model.play($0, startAt: 0) } }
                } shuffle: {
                    Task { await withSongs { model.shuffle($0) } }
                }
            }
            if fetchingSongs { ProgressView().accessibilityLabel("Getting songs") }
            if let songsError {
                Text(songsError).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .multilineTextAlignment(.center).padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            }
        }
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

    /// The genre's albums through the browser (its counts aren't needed: a genre page has no sub-genre chips).
    private func load() async {
        await browser.start(model: model, genres: [Genre(name: name, songCount: 0, albumCount: 0, countsKnown: false)])
    }
}
