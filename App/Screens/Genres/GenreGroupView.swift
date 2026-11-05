import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// A group's page (spec §4, Task 19): its albums, from every genre in it, and Shuffle. A group mixes many genres,
/// so it offers Shuffle only (D41); its songs (at most `AppModel.groupSongCap`, taken from each genre in turn) are
/// fetched when Shuffle is tapped. Round 15 C4 (D141–D145): the albums are sorted and filtered (sort, sub-genres,
/// decade, album or artist, Favourites, Downloaded) and read a page at a time.
struct GenreGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    let groupId: String
    @State private var page: Loadable<Page> = .loading
    @State private var shuffling = false
    @State private var shuffleError: String?
    @State private var browser = GenreAlbumBrowser(kind: .group)
    @State private var text = ""
    private let themed = Themed()

    struct Page {
        let group: AppModel.GenreGroupPage
        var section: GenreGroupSection { group.section }
    }

    var body: some View {
        ScrollView {
            LoadableView(state: page, retry: load) { page in
                content(page)
            }
        }
        .navigationTitle(page.value?.section.group.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $text, prompt: "Album or artist")
        .magpieScreen()
        .task(id: model.offlinePageKey) { await load() }
        .task(id: text) { await browser.setText(text) }
    }

    private func content(_ page: Page) -> some View {
        let p = themed.palette
        return VStack(spacing: Tokens.Spacing.l) {
            VStack(spacing: Tokens.Spacing.s) {
                Text(page.section.group.name).magpieDisplay(.title).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(GenreLabel.counts(albums: page.section.albumCount, songs: page.section.songCount))
                    .font(theme.numberFont(.footnote)).foregroundStyle(p.ink2Color)
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)

            // Y7: the same ActionBar as every page; a group offers Shuffle only (D41), across the full row.
            ActionBar {
                // Review minor 6: the spinner sits in the capsule, so nothing shifts while songs load.
                ActionButton("Shuffle", symbol: "shuffle", busy: shuffling) { Task { await shuffle() } }
                    .disabled(shuffling)
                    .accessibilityIdentifier("shuffle")
            }
            if let shuffleError {
                Text(shuffleError).font(.footnote).foregroundStyle(p.ink2Color).multilineTextAlignment(.center)
                    .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            }

            GenreAlbumControls(browser: browser)
            GenreAlbumList(browser: browser, emptyText: "No albums in this group.")
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    private func load() async {
        do {
            // One `getGenres` for the page: the albums and Shuffle use the genres in hand.
            guard let group = try await model.genreGroup(groupId) else {
                page = .failed("This group has no genres now.")
                return
            }
            page = .loaded(Page(group: group))
            await browser.start(model: model, genres: group.genres)
        } catch {
            if page.value == nil { page = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }

    private func shuffle() async {
        guard let genres = page.value?.group.genres else { return }
        shuffling = true
        shuffleError = nil
        defer { shuffling = false }
        do {
            let songs = try await model.groupSongs(in: genres)   // already shuffled
            if songs.isEmpty { shuffleError = model.isOffline ? OfflineCopy.notOnPhone : "No songs in this group." }
            model.play(songs, startAt: 0)
        } catch {
            shuffleError = BrowseErrorCopy.message(for: error)
        }
    }
}
