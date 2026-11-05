import AurralKit
import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// Round 14 A4 (plan "Screens", D91): Trending. The No. 1 song, Top songs (100) with Play previews and Add flow (follow
/// the chart as a daily-updated flow), Top albums, Top artists, Charts by genre, then Popular playlists. Each section on
/// its own: one Aurral hasn't loaded says "updating" while the others show. Shows the last copy at once.
struct TrendingView: View {
    @Environment(AppModel.self) private var model
    private let themed = Themed()

    private var feeds: AurralFeeds { model.aurralFeeds }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                if let trending = feeds.trending {
                    if feeds.failed.contains(.trending) {
                        Text(DiscoverPagesCopy.couldntUpdate).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                            .padding(.horizontal, Tokens.Spacing.margin)
                    }
                    content(trending)
                } else {
                    UpdatingCard()
                }
            }
            .padding(.vertical, Tokens.Spacing.l)
        }
        .refreshable { await RefreshSafety.run { await feeds.refresh(.trending, force: true) } }
        .navigationTitle(DiscoverPagesCopy.trending)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task {
            await feeds.refresh(.trending)
            await feeds.refresh(.editorial)
        }
    }

    @ViewBuilder private func content(_ t: TrendingSnapshot) -> some View {
        if let songs = t.songs, let first = songs.first {
            spotlight(first, days: t.daysAtTop)
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                PageSectionTitle(title: DiscoverPagesCopy.topSongs(region: t.songsRegion),
                                 subtitle: t.showingServerInstead.map { DiscoverPagesCopy.showingServer(region: $0) })
                    .accessibilityIdentifier("trending-top-songs")
                HStack(spacing: Tokens.Spacing.s) {
                    PlayPreviewsButton(items: songs.map(model.previewItem(for:)))
                    if let chart = t.chartPlaylistId {
                        AddFlowControl(deezerPlaylistId: chart, libraryPlaylistId: feeds.added[chart] ?? t.libraryPlaylistId)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.margin)
                ChartSongList(songs: songs, showsPosition: true, identifier: "trending-song")
            }
        } else {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                PageSectionTitle(title: DiscoverPagesCopy.topSongs)
                UpdatingCard()
            }
        }
        albums(t.albums, region: t.albumsRegion)
        artists(t.artists)
        genres(t.genres)
        popularPlaylists
    }

    private func spotlight(_ song: ChartSong, days: Int?) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            AurralArt(image: song.artwork, side: 96)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(DiscoverPagesCopy.numberOne).font(.caption.weight(.bold)).foregroundStyle(themed.palette.accentInkColor)
                Text(song.title).magpieDisplay(.title3)
                Text(song.artist).font(.subheadline).foregroundStyle(themed.palette.ink2Color)
                if let days, days > 0 {
                    Text(DiscoverPagesCopy.daysAtTop(days)).font(.caption).foregroundStyle(themed.palette.ink2Color)
                }
                PreviewControl(item: model.previewItem(for: song))
            }
        }
        .padding(.horizontal, Tokens.Spacing.margin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trending-spotlight")
    }

    @ViewBuilder private func albums(_ albums: [ChartAlbum]?, region: String?) -> some View {
        if let albums {
            if !albums.isEmpty {
                ShelfSection(DiscoverPagesCopy.topAlbums(region: region)) {
                    ForEach(Array(albums.enumerated()), id: \.offset) { index, album in
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            AurralArt(image: album.artwork, side: 140)
                            Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(album.artist).font(.footnote).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                        }
                        .frame(width: 140, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        // Round 15 C3: Try / Add to library (a long press).
                        .contextMenu { OutsideAlbumMenu(album: OutsideAlbumRef(title: album.name, artist: album.artist)) }
                        .accessibilityIdentifier("trending-album-\(index)")
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                PageSectionTitle(title: DiscoverPagesCopy.topAlbums)
                UpdatingCard()
            }
        }
    }

    @ViewBuilder private func artists(_ artists: [ChartArtist]?) -> some View {
        if let artists, !artists.isEmpty {
            ShelfSection(DiscoverPagesCopy.topArtists) {
                ForEach(Array(artists.enumerated()), id: \.offset) { _, artist in
                    NavigationLink(value: Route.outsideArtist(.init(name: artist.name, mbid: artist.mbid.flatMap(MBID.init)))) {
                        VStack(spacing: Tokens.Spacing.xs) {
                            AurralArt(image: artist.image, side: 110, circle: true)
                            Text(artist.name).font(.subheadline).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .frame(width: 110)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if artists == nil {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                PageSectionTitle(title: DiscoverPagesCopy.topArtists)
                UpdatingCard()
            }
        }
    }

    @ViewBuilder private func genres(_ genres: [GenreTile]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            PageSectionTitle(title: DiscoverPagesCopy.chartsByGenre, subtitle: DiscoverPagesCopy.worldwide)
            if genres.isEmpty {
                UpdatingCard()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Tokens.Spacing.m)], spacing: Tokens.Spacing.m) {
                    ForEach(genres, id: \.id) { genre in
                        NavigationLink(value: Route.genreChart(id: genre.id, name: genre.name)) {
                            HStack(spacing: Tokens.Spacing.s) {
                                AurralArt(image: genre.cover, side: 48)
                                Text(genre.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(Tokens.Spacing.s)
                            .background(themed.palette.ink2Color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("genre-chart-\(genre.id)")
                    }
                }
                .padding(.horizontal, Tokens.Spacing.margin)
            }
        }
    }

    /// Popular playlists: the Discover playlists' Popular shelf.
    @ViewBuilder private var popularPlaylists: some View {
        if let popular = feeds.editorial?.genres.first(where: { $0.id == 0 }) ?? feeds.editorial?.genres.first {
            ShelfSection(DiscoverPagesCopy.popularPlaylists) {
                ForEach(popular.playlists, id: \.id) { PlaylistCard(playlist: $0) }
            }
        }
    }
}

/// One genre's chart (50 songs, worldwide): Play previews and the songs; "not ready yet" when Aurral says so.
struct GenreChartView: View {
    @Environment(AppModel.self) private var model
    let genreId: Int
    let name: String
    @State private var loaded = false

    private var feeds: AurralFeeds { model.aurralFeeds }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                PageSectionTitle(title: name, subtitle: DiscoverPagesCopy.worldwide)
                if let songs = feeds.genreCharts[genreId], !songs.isEmpty {
                    PlayPreviewsButton(items: songs.map(model.previewItem(for:)))
                        .padding(.horizontal, Tokens.Spacing.margin)
                    ChartSongList(songs: songs, showsPosition: true, identifier: "genre-song")
                } else if feeds.notReadyGenres.contains(genreId) {
                    UpdatingCard(text: DiscoverPagesCopy.notReady)
                } else if loaded {
                    UpdatingCard()
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.vertical, Tokens.Spacing.l)
        }
        .refreshable { await RefreshSafety.run { await feeds.refreshGenre(genreId) } }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task {
            await feeds.refreshGenre(genreId)
            loaded = true
        }
    }
}
