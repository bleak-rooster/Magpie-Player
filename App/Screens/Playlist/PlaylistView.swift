import DesignSystem
import MagpieCore
import SwiftUI

/// Playlist: cover, name in the display face, song count and length, Play / Shuffle, songs.
struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    let playlistId: String
    @State private var page: Loadable<Page> = .loading
    private let themed = Themed()

    struct Page {
        var playlist: Playlist
        var songs: [Song]
    }

    var body: some View {
        ScrollView {
            LoadableView(state: page, retry: load) { page in
                content(page)
            }
        }
        .navigationTitle(page.value?.playlist.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task { if page.value == nil { await load() } }
    }

    private func content(_ page: Page) -> some View {
        let p = themed.palette
        let songs = page.songs
        let minutes = DurationText.minutes(page.playlist.duration > 0 ? page.playlist.duration
                                                                       : songs.reduce(0) { $0 + $1.duration })
        return VStack(spacing: Tokens.Spacing.l) {
            VStack(spacing: Tokens.Spacing.s) {
                Artwork(page.playlist.coverArtId, side: 220) { SleeveArt(image: $0, side: 220) }
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .padding(.bottom, Tokens.Spacing.s)
                Text(page.playlist.name).magpieDisplay(.title).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs") · \(minutes) min")
                    .font(theme.numberFont(.footnote)).foregroundStyle(p.ink2Color)
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)

            PlayShuffleButtons(songs: songs)

            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    Button { model.play(songs, startAt: index) } label: {
                        Artwork(song.coverArtId, side: 48) { image in
                            SongRow(song: song, state: .library, artwork: image)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("track-\(index)")
                    Divider().overlay(p.sepColor).padding(.leading, 76)
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    private func load() async {
        do {
            let (playlist, songs) = try await model.request { [playlistId] in try await $0.playlist(id: playlistId) }
            page = .loaded(Page(playlist: playlist, songs: songs))
        } catch {
            page = .failed(BrowseErrorCopy.message(for: error))
        }
    }
}
