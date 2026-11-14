import AurralKit
import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// Round 14 A4 (plan "Screens", D91): Trending. The No. 1 song, Top songs (100) with Play previews and Add flow (follow
/// the chart as a daily-updated flow), Top albums, Top artists, Charts by genre, then Popular playlists. Each section on
/// its own: one Aurral hasn't loaded says "updating" while the others show. Shows the last copy at once.
/// Round 15 C2 (owner items 5 and 5b, D132–D134): Trending opens on the default chart; the chart button picks another
/// (Worldwide, a country, a genre) and **Make default** makes it the one Trending opens on. Each chart has its own
/// flow: Create flow… (Songs: N) or Edit flow (Songs: N, Refresh now, Remove flow).
struct TrendingView: View {
    @Environment(AppModel.self) private var model
    private let themed = Themed()
    /// The chart picked this visit (nil: the default, as the feed holds it).
    @State private var picked: TrendingChart?
    @State private var pickedPage: ChartPage?
    @State private var pickedFailed = false
    @State private var choosing = false
    @State private var makingDefault = false
    /// Fix round M5: Make default on Automatic pinned a fixed country: say so.
    @State private var pinnedNote: String?
    /// Round 27 D2: bumped by a pull to refresh, so the chart flow's songs are read again (D317).
    @State private var reloads = 0
    /// Round 27 D2 fix round 1 (I1): the song list's rows as last read, and for which songs.
    @State private var listed: ListedRows?

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
        .refreshable {
            await RefreshSafety.run {
                if picked == nil { await feeds.refresh(.trending, force: true) } else { await loadPicked(fresh: true) }
            }
            reloads += 1
        }
        .navigationTitle(DiscoverPagesCopy.trending)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task {
            await feeds.refresh(.trending)
            await feeds.refresh(.editorial)
        }
    }

    /// The chart the feed holds (the default, or the server's when the default couldn't be read).
    private func feedChart(_ t: TrendingSnapshot) -> TrendingChart? { t.chart }

    /// The chart on screen: the one picked this visit, else the feed's.
    private func shownChart(_ t: TrendingSnapshot) -> TrendingChart? { picked ?? t.chart }

    /// The default chart as set (Make default shows unless the chart on screen is it).
    private func defaultChart(_ t: TrendingSnapshot) -> TrendingChart? {
        model.preferences.layout.chartsCountry.chart(phoneRegion: feeds.phoneRegion(), serverRegion: t.region,
                                                    countriesWithCharts: Set(AurralFeeds.chartPlaylists.keys))
    }

    @ViewBuilder private func content(_ t: TrendingSnapshot) -> some View {
        chartBar(t)
        if let picked, picked != t.chart {
            if let page = pickedPage, page.chart == picked, let first = page.songs.first {
                topSongs(page: page, first: first, days: nil, subtitle: nil)
            } else {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    PageSectionTitle(title: DiscoverPagesCopy.topSongs(chart: model.chartTitle(picked)))
                    if pickedFailed { UpdatingCard(text: DiscoverPagesCopy.notReady) } else { UpdatingCard() }
                }
            }
        } else if let songs = t.songs, let first = songs.first {
            let page = ChartPage(chart: t.chart ?? .worldwide, name: t.chartName ?? "", songs: songs, playlistId: t.chartPlaylistId,
                                 libraryPlaylistId: t.libraryPlaylistId)
            topSongs(page: page, first: first, days: t.daysAtTop,
                     subtitle: t.showingServerInstead.map { DiscoverPagesCopy.showingServer(region: $0) },
                     title: t.chart == nil ? DiscoverPagesCopy.topSongs(region: t.songsRegion) : nil,
                     hasChart: t.chart != nil)
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

    /// The chart button ("Chart: Worldwide") and Make default (or "Default" when the chart on screen is it).
    @ViewBuilder private func chartBar(_ t: TrendingSnapshot) -> some View {
        let shown = shownChart(t)
        let isDefault = shown != nil && shown == defaultChart(t)
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
        HStack(spacing: Tokens.Spacing.s) {
            Button { choosing = true } label: {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(DiscoverPagesCopy.chooseChart(shown.map(model.chartTitle) ?? DiscoverPagesCopy.topSongs))
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).accessibilityHidden(true)
                }
                .frame(minHeight: Tokens.minHitSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("trending-chart-picker")
            Spacer(minLength: Tokens.Spacing.s)
            if let shown {
                if isDefault {
                    Label(DiscoverPagesCopy.defaultChart, systemImage: "pin.fill")
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        .accessibilityIdentifier("trending-default-badge")
                } else {
                    Button(DiscoverPagesCopy.makeDefault) {
                        makingDefault = true
                        Task {
                            pinnedNote = await model.makeDefaultChart(shown)
                            if feeds.trending?.chart == shown { picked = nil }
                            makingDefault = false
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: Tokens.minHitSize)
                    .disabled(makingDefault)
                    .accessibilityIdentifier("trending-make-default")
                }
            }
        }
        if let pinnedNote {
            Text(pinnedNote)
                .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                .accessibilityIdentifier("trending-pinned-note")
        }
        }
        .padding(.horizontal, Tokens.Spacing.margin)
        .sheet(isPresented: $choosing) {
            ChartPickerSheet(shown: shown, defaultChart: defaultChart(t)) { chart in
                picked = chart == t.chart ? nil : chart
            }
        }
        .task(id: picked) { await loadPicked() }
    }

    private func loadPicked(fresh: Bool = false) async {
        guard let picked else { pickedPage = nil; return }
        pickedFailed = false
        do {
            let page = try await model.chartPage(picked, fresh: fresh)
            if self.picked == picked { pickedPage = page }
            // Round 27 D2 (D319): a chart read keeps its flow up, once a day; fix round 1 (I2): in its own task, so
            // switching charts or leaving never cancels a send half way.
            model.keepChartFlowUpInBackground(page)
        } catch {
            if self.picked == picked { pickedFailed = true }
        }
    }

    /// The No. 1, then Top songs with Play previews, the chart's flow and the songs.
    @ViewBuilder private func topSongs(page: ChartPage, first: ChartSong, days: Int?, subtitle: String?, title: String? = nil,
                                       hasChart: Bool = true) -> some View {
        let rows = listed?.songs == page.songs ? listed?.rows ?? ChartRows() : ChartRows()
        spotlight(first, days: days, rows: rows)
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            PageSectionTitle(title: title ?? DiscoverPagesCopy.topSongs(chart: model.chartTitle(page.chart)), subtitle: subtitle)
                .accessibilityIdentifier("trending-top-songs")
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                ChartPlayButtons(songs: page.songs, rows: rows)
                if hasChart { ChartFlowControl(page: page) }
                // Round 14's Add flow (the whole chart, synced by the server), when one was made: its state only.
                if let id = page.playlistId, let legacy = feeds.added[id] ?? page.libraryPlaylistId {
                    AddFlowControl(deezerPlaylistId: id, libraryPlaylistId: legacy)
                }
            }
            .padding(.horizontal, Tokens.Spacing.margin)
            ChartSongList(songs: page.songs, showsPosition: true, identifier: "trending-song", chart: hasChart ? page.chart : nil,
                          reload: reloads) { found in listed = ListedRows(songs: page.songs, rows: found) }
        }
    }

    private func spotlight(_ song: ChartSong, days: Int?, rows: ChartRows) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            AurralArt(image: song.artwork, side: 96)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(DiscoverPagesCopy.numberOne).font(.caption.weight(.bold)).foregroundStyle(themed.palette.accentInkColor)
                Text(song.title).magpieDisplay(.title3)
                Text(song.artist).font(.subheadline).foregroundStyle(themed.palette.ink2Color)
                if let days, days > 0 {
                    Text(DiscoverPagesCopy.daysAtTop(days)).font(.caption).foregroundStyle(themed.palette.ink2Color)
                }
                // Fix round 1 (I1): the No. 1 plays in full when the list has it (the library's or the chart flow's).
                if let order = rows.playOrder(from: 0) {
                    CapsuleButton(ChartFlowRowCopy.play, symbol: "play.fill") { model.play(order.songs, startAt: order.start) }
                        .accessibilityLabel("\(ChartFlowRowCopy.play) \(song.title)")
                        .accessibilityIdentifier("trending-spotlight-play")
                } else {
                    PreviewControl(item: model.previewItem(for: song))
                }
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
                            // Round 15 C3 (review M8): where it stands, once asked for.
                            if let status = model.libraryStatus(forAlbumTitled: album.name, artist: album.artist) {
                                Text(status).font(.caption).foregroundStyle(themed.palette.accentInkColor).lineLimit(1)
                            }
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
    @State private var reloads = 0
    @State private var listed: ListedRows?

    private var feeds: AurralFeeds { model.aurralFeeds }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                PageSectionTitle(title: name, subtitle: DiscoverPagesCopy.worldwide)
                if let songs = feeds.genreCharts[genreId], !songs.isEmpty {
                    ChartPlayButtons(songs: songs, rows: listed?.songs == songs ? listed?.rows ?? ChartRows() : ChartRows())
                        .padding(.horizontal, Tokens.Spacing.margin)
                    ChartSongList(songs: songs, showsPosition: true, identifier: "genre-song", chart: .genre(genreId),
                                  reload: reloads) { found in listed = ListedRows(songs: songs, rows: found) }
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
        .refreshable {
            await RefreshSafety.run { await feeds.refreshGenre(genreId) }
            reloads += 1
            keepUp()   // fix round 2 (m1): a pull to refresh is a read too
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task {
            await feeds.refreshGenre(genreId)
            loaded = true
            keepUp()
        }
    }

    /// Round 27 D2 fix round 1 (M5, D319): a genre chart read keeps its flow up too, in its own task.
    private func keepUp() {
        guard let songs = feeds.genreCharts[genreId], !songs.isEmpty else { return }
        model.keepChartFlowUpInBackground(ChartPage(chart: .genre(genreId), name: name, songs: songs, playlistId: nil,
                                                    libraryPlaylistId: nil))
    }
}

/// Round 27 D2 fix round 1: a chart list's rows as read, and for which songs (a newer list never shows older rows).
struct ListedRows: Equatable {
    var songs: [ChartSong]
    var rows: ChartRows
}

/// Round 27 D2 fix round 1 (I1, design M3; plan §8 amendment "Play"): above a chart's songs, **Play** when any row plays
/// in full (the playable rows in chart order), and **Play previews** for the rows that only have a preview (hidden
/// when every row plays in full).
struct ChartPlayButtons: View {
    @Environment(AppModel.self) private var model
    let songs: [ChartSong]
    let rows: ChartRows

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            if let order = Self.playOrder(rows) {
                CapsuleButton(ChartFlowRowCopy.play, symbol: "play.fill", style: .fill) { model.play(order.songs, startAt: 0) }
                    .accessibilityIdentifier("chart-play")
            }
            PlayPreviewsButton(items: Self.previewSongs(songs, rows).map(model.previewItem(for:)))
        }
    }

    /// The songs Play plays: every playable row, in chart order (nil: none).
    static func playOrder(_ rows: ChartRows) -> (songs: [Song], start: Int)? {
        rows.copies.keys.min().flatMap { rows.playOrder(from: $0) }
    }

    /// The songs Play previews plays: the rows with no song to play in full.
    static func previewSongs(_ songs: [ChartSong], _ rows: ChartRows) -> [ChartSong] {
        rows.previewOnly(songs.count).map { songs[$0] }
    }
}
