import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Home (spec §3, Task 20): the "Finish setting up" card pinned on top, then the owner's sections in the owner's order
/// (Settings › Home & Library › Home, or Edit Home at the bottom). Made for you shows only with a listening-history
/// token (Task 7.1c) and fills in after the library's shelves. Empty sections are left out. Offline (Task 14): "You're
/// offline", then the Downloaded shelf (albums on the phone).
/// Round 14 A6 (Spotify-style): the greeting, the filter chips and the quick grid lead by default; each
/// shelf has its own card size and count, and the provided sections (Recommended, Trending…) come from
/// `HomeAurralShelves`.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var editsHome = false
    /// The chip picked (not saved: Home opens on All).
    @State private var filter: HomeFilter = .all
    private let themed = Themed()

    private var key: HomeLoad.Key {
        .make(sections: model.homeSections, offline: model.isOffline, onPhone: model.downloads?.localFiles.count,
              genres: model.preferences.genres)
    }

    var body: some View {
        ScrollView {
            content
        }
        .refreshable {
            guard !model.isOffline else { return await model.checkReachability() }
            async let made: Void = model.refreshMadeForYou()
            await model.homeFeed.refresh(key)
            await made
        }
        .magpieLargeTitle("Home")
        // Round 13 Z2 (item 13): the layout editor from the top of Home too, as a sheet; changes apply at once.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LayoutEditButton(title: "Edit Home") { editsHome = true }
                    .accessibilityIdentifier("home-edit-toolbar")
            }
        }
        // H3 M7: a solid bar in the page colour once scrolled, so covers don't show through under the title and
        // the status bar.
        .toolbarBackground(themed.palette.bgColor, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        // Final fix 2 H3-M7: the bar's soft scroll-edge blur still let covers show behind the large title; a hard
        // edge keeps the title on the page colour.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .magpieScreen()
        // Reads what a change needs: a section turned on or one that failed, offline or back online (everything
        // again), a song that landed on or left the phone (Downloaded), the genre preferences (Genres). A reorder or a
        // section turned off reads nothing.
        // P5: Home's feed (saved shelves at once, retries by itself) does the reading; see `HomeFeed`. Foreground and
        // background reach it from `AppModel.isForeground`, sign-out and another account from the session.
        .task(id: key) { await model.homeFeed.show(key) }
        .onChange(of: model.serverAnsweredGeneration) { model.homeFeed.reconnected() }
        .onChange(of: model.network.status.isConnected) { _, connected in if connected { model.homeFeed.reconnected() } }
        // Its own task, so the library's shelves never wait for it. Read once (Refresh reads again), and again
        // whenever the token is saved, replaced or removed (which also clears the shelf).
        .task(id: model.listenBrainzTokenGeneration) {
            if model.madeForYouShelf.isEmpty, !model.isOffline { await model.refreshMadeForYou() }
        }
        .sheet(isPresented: $editsHome) {
            LayoutEditorSheet(doneIdentifier: "home-edit-done") { HomeLayoutView() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
            if model.isOffline {
                OfflineNotice()
                    .padding(.horizontal, Tokens.Spacing.margin)
            } else if model.showsFinishSettingUp {   // final fix 2 B-M2: only while a step is left
                FinishSettingUpCard()
                    .padding(.horizontal, Tokens.Spacing.margin)
            }
            SlskdOutageBanner().padding(.horizontal, Tokens.Spacing.margin)   // R24 (D219): slskd stayed disconnected
            HeldSongsBanner().padding(.horizontal, Tokens.Spacing.margin)   // R24C (D213): a song held for review
            LoadableView(state: model.homeFeed.state, retry: { await model.homeFeed.refresh(key) }) { read in
                let shown = model.homeSections
                let chips = HomeFilter.offered(for: shown.filter { shows($0, read) })
                let picked = chips.contains(filter) ? filter : .all
                let sections = picked.apply(shown).filter { shows($0, read, chips: chips) }
                if !sections.contains(where: { !$0.isChrome }) {
                    empty
                } else {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                        ForEach(sections, id: \.self) { section in
                            switch section {
                            case .madeForYou: madeForYouShelf
                            case .greeting: HomeGreeting()
                            case .filterChips: HomeFilterChips(chips: chips, picked: picked) { filter = $0 }
                            case .quickAccess: QuickAccessGrid(tiles: quickTiles(read))
                            default:
                                if let shelf = read.found[section] {
                                    ShelfView(shelf: shelf, style: model.preferences.layout.style(for: section),
                                              rows: model.preferences.layout.becauseYouLikeRows)
                                } else {
                                    failure(section)
                                }
                            }
                        }
                    }
                }
            }
            Button {
                editsHome = true
            } label: {
                Label("Edit Home", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: Tokens.minHitSize)
            }
            .foregroundStyle(themed.palette.accentInkColor)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("home-edit")
        }
        .padding(.vertical, Tokens.Spacing.l)
    }

    /// Whether `section` has something to show. The greeting always does; the chips when there is more than All to
    /// pick; the quick grid when it has a tile. A section never stands in for another (round 13).
    private func shows(_ section: HomeSection, _ read: HomeLoad, chips: [HomeFilter] = HomeFilter.allCases) -> Bool {
        switch section {
        case .greeting: true
        case .filterChips: chips.count > 1
        case .quickAccess: !quickTiles(read).isEmpty
        case .madeForYou: !model.madeForYouShelf.isEmpty
        default: read.found[section] != nil || model.homeFeed.showsFailure(section)
        }
    }

    /// The quick grid: this phone's plays first, then the server's recently played albums (round 14 A6).
    private func quickTiles(_ read: HomeLoad) -> [RecentPlay] {
        let albums = read.found[.quickAccess]?.items.compactMap { item -> Album? in
            if case .album(let album) = item { album } else { nil }
        } ?? []
        return model.quickAccessTiles(recentAlbums: albums)
    }

    /// A section that couldn't be read: its title, and a line saying so.
    private func failure(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(section.title).magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                .foregroundStyle(themed.palette.inkColor)
            Label(HomeCopy.couldNotLoad(section), systemImage: "wifi.exclamationmark")
                .font(.footnote).foregroundStyle(themed.palette.ink2Color)
        }
        .padding(.horizontal, Tokens.Spacing.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-failed-\(section.rawValue)")
    }

    @ViewBuilder private var empty: some View {
        if model.isOffline {
            ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                   description: Text("Albums and playlists you download play here without a connection."))
        } else if model.homeSections.isEmpty {
            ContentUnavailableView("Nothing on Home", systemImage: "square.grid.2x2",
                                   description: Text("Choose what shows here with Edit Home."))
        } else {
            ContentUnavailableView("No music yet", systemImage: "music.note",
                                   description: Text("Albums show up here once your server has some."))
        }
    }

    @ViewBuilder private var madeForYouShelf: some View {
        ShelfSection("Made for you") {
            ForEach(Array(model.madeForYouShelf.enumerated()), id: \.element.id) { index, playlist in
                NavigationLink(value: Route.madeForYou(playlist)) {
                    AlbumTile(title: playlist.title,
                              subtitle: playlist.date.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "Playlist")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("made-for-you-\(index)")
            }
        }
        .accessibilityIdentifier("home-made-for-you")
    }
}

/// One shelf; each tile opens what it is (an album, a playlist, a genre group, a provided tile). Y3: Recently
/// downloaded has "See all" (Downloads), and its playlists open the phone's copy. Round 14 A6: the owner's card size
/// and count (`style`); Because you like is one row per seed artist, up to `rows`.
private struct ShelfView: View {
    @Environment(AppModel.self) private var model
    @Environment(TabNavigator.self) private var navigator: TabNavigator?
    let shelf: HomeShelf
    let style: HomeSectionStyle
    let rows: Int

    var body: some View {
        if shelf.section == .becauseYouLike {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                ForEach(HomeShelfLayout.becauseYouLikeRows(shelf.items, rows: rows), id: \.seed) { row in
                    ShelfSection(HomeCopy.becauseYouLike(row.seed)) {
                        ForEach(row.items.prefix(style.count)) { tile($0) }
                    }
                }
            }
            .accessibilityIdentifier("home-\(shelf.section.rawValue)")
        } else {
            ShelfSection(shelf.section == .trending ? model.homeTrendingTitle : shelf.section.title, onSeeAll: seeAll) {
                ForEach(shelf.items.prefix(style.count)) { item in
                    tile(item)
                }
            }
            .accessibilityIdentifier("home-\(shelf.section.rawValue)")
        }
    }

    private var width: CGFloat { HomeShelfLayout.width(style.size) }

    private var seeAll: (() -> Void)? {
        guard shelf.section == .downloaded, let navigator else { return nil }
        return { navigator.push(.downloads) }
    }

    @ViewBuilder private func tile(_ item: HomeShelf.Item) -> some View {
        switch item {
        case .album(let album), .downloadedAlbum(let album):
            NavigationLink(value: Route.album(id: album.id)) {
                AlbumTileView(album: album, subtitle: album.artist, width: width)
            }
            .buttonStyle(.plain)
        case .playlist(let playlist):
            // Y3: a playlist looks like one (stacked frame, "Playlist · N songs"), not like another album.
            NavigationLink(value: shelf.section == .downloaded ? Route.downloadedPlaylist(id: playlist.id)
                                                               : Route.playlist(id: playlist.id)) {
                Artwork(playlist.coverArtId, side: width) { image in
                    PlaylistTile(playlist: playlist, artwork: image, width: width,
                                 mark: model.downloadIndex.mark(playlistId: playlist.id))
                }
                .collectionMenu(.playlist(playlist.id), coverArtId: playlist.coverArtId)   // R12, P4
            }
            .buttonStyle(.plain)
        case .genreGroup(let section):
            NavigationLink(value: Route.genreGroup(id: section.group.id)) {
                AlbumTile(title: section.group.name,
                          subtitle: section.albumCount == 1 ? "1 album" : "\(section.albumCount) albums", width: width)
            }
            .buttonStyle(.plain)
        case .outside(let outside):
            OutsideTile(item: outside, section: shelf.section, size: style.size)
        }
    }
}

/// What Home's "Finish setting up" card says. About the music; it points to Settings without naming a service (§5).
enum HomeCopy {
    /// Under a section's title when it couldn't be read (Task 21).
    static func couldNotLoad(_ section: HomeSection) -> String { "Couldn't load \(section.title). Pull to refresh." }

    /// Try works; only Finds is left (B-M2).
    static let finishFinds = "Your Finds folder needs one more step in Settings."

    static func finishSettingUp(connected: Bool) -> String {
        connected
            ? "Search shows music that's not in your library. To bring songs home, finish the last steps in Settings."
            : "Let Magpie find songs you don't have yet and bring the ones you love home."
    }
}

/// D9: setup continues from Home. Opens the Lidarr connection sheet until one is connected; then Review opens
/// Settings › Requests, where the steps left are, or Finds set-up when that is all that is left (final fix 2 B-M2, T21b).
private struct FinishSettingUpCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsConnect = false
    @State private var showsSettings = false
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        let connected = model.lidarr != nil
        // Symbol above the text at accessibility sizes, so the text keeps the card's full width (D15).
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Spacing.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Tokens.Spacing.m))
        Button { if connected { showsSettings = true } else { showsConnect = true } } label: {
            layout {
                Image(systemName: connected ? "checkmark.circle" : "sparkles")
                    .font(.title2)
                    .foregroundStyle(p.accentInkColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("Finish setting up").font(.headline)
                    Text(model.tryAvailability.message == nil ? HomeCopy.finishFinds : HomeCopy.finishSettingUp(connected: connected))
                        .font(.subheadline)
                        .foregroundStyle(p.ink2Color)
                    Text(connected ? "Review" : "Continue")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(p.accentInkColor)
                        .padding(.top, Tokens.Spacing.xs)
                }
            }
            .padding(Tokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surfaceColor, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("finish-setting-up")
        .sheet(isPresented: $showsConnect) { ConnectLidarrView() }
        .sheet(isPresented: $showsSettings) { SettingsView(opening: SettingsPage.finishSettingUp(model.tryAvailability)) }
    }
}

/// An `AlbumTile` with its cover loaded.
struct AlbumTileView: View {
    @Environment(AppModel.self) private var model
    let album: Album
    let subtitle: String
    var width: CGFloat = 140

    var body: some View {
        Artwork(album.coverArtId, side: width) { image in
            AlbumTile(title: album.name, subtitle: subtitle, artwork: image, width: width,
                      mark: model.downloadIndex.mark(album: album))   // P1
        }
        .albumMenu(album)   // R7 Favourite, R8 Add to playlist…, P4 Reload artwork
    }
}
