import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// A group's page (spec §4, Task 19): its albums, merged from every genre in it, and Shuffle. A group mixes many genres,
/// so it offers Shuffle only (D41); its songs (at most `AppModel.groupSongCap`) are fetched when Shuffle is tapped.
struct GenreGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    let groupId: String
    @State private var page: Loadable<Page> = .loading
    @State private var shuffling = false
    @State private var shuffleError: String?
    private let themed = Themed()

    struct Page {
        let section: GenreGroupSection
        let albums: [Album]
    }

    var body: some View {
        ScrollView {
            LoadableView(state: page, retry: load) { page in
                content(page)
            }
        }
        .navigationTitle(page.value?.section.group.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task(id: model.offlinePageKey) { await load() }
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

            HStack(spacing: Tokens.Spacing.s) {
                CapsuleButton("Shuffle", symbol: "shuffle") { Task { await shuffle() } }
                    .disabled(shuffling)
                    .accessibilityIdentifier("shuffle")
                if shuffling { ProgressView().accessibilityLabel("Getting songs") }
            }
            if let shuffleError {
                Text(shuffleError).font(.footnote).foregroundStyle(p.ink2Color).multilineTextAlignment(.center)
                    .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            }

            if page.albums.isEmpty {
                Text(model.isOffline ? OfflineCopy.notOnPhone : "No albums in this group.")
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
            guard let section = try await model.genreSection(groupId) else {
                page = .failed("This group has no genres now.")
                return
            }
            page = .loaded(Page(section: section, albums: try await model.groupAlbums(groupId)))
        } catch {
            if page.value == nil { page = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }

    private func shuffle() async {
        shuffling = true
        shuffleError = nil
        defer { shuffling = false }
        do {
            let songs = try await model.groupSongs(groupId)   // already shuffled
            if songs.isEmpty { shuffleError = model.isOffline ? OfflineCopy.notOnPhone : "No songs in this group." }
            model.play(songs, startAt: 0)
        } catch {
            shuffleError = BrowseErrorCopy.message(for: error)
        }
    }
}
