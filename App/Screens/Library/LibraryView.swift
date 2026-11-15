import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// Library (spec §3, Task 21): the owner's rows in the owner's order (Settings › Home & Library › Library): Playlists,
/// Artists, Albums, Songs, Genres, Favourites, Downloads, Finds (once a Finds library is chosen), Requests (with Lidarr
/// connected); then, when switched on, recently added albums. Offline (Task 14): "You're offline", then Downloads (and
/// Genres, read from the phone).
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var recent: Loadable<[Album]> = .loading
    @State private var showsSettings = false
    @State private var editsLibrary = false
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 28
    private let themed = Themed()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    if model.isOffline {   // Task 14 (kept by Task 21): only what's on the phone
                        OfflineNotice().padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    }
                    rows
                }
                if model.showsRecentlyAddedGrid { recentlyAdded }
            }
            .padding(.vertical, Tokens.Spacing.s)
        }
        .refreshable {
            await RefreshSafety.run {   // Round 13 Z2
                if model.isOffline { await model.checkReachability() } else if model.showsRecentlyAddedGrid { await load() }
            }
        }
        .magpieLargeTitle("Library")
        .toolbar {
            // Round 13 Z2 (item 13): the Library's layout editor, as a sheet; changes apply at once.
            ToolbarItem(placement: .topBarTrailing) {
                LayoutEditButton(title: "Edit Library") { editsLibrary = true }
                    .accessibilityIdentifier("library-edit-toolbar")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("open-settings")
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .sheet(isPresented: $editsLibrary) {
            LayoutEditorSheet(doneIdentifier: "library-edit-done") { LibraryLayoutView() }
        }
        .magpieScreen()
        .task(id: model.showsRecentlyAddedGrid) { if model.showsRecentlyAddedGrid, recent.value == nil { await load() } }
    }

    /// The rows `AppModel.libraryRows` names, in its order, with a separator between each.
    private var rows: some View {
        let rows = model.libraryRows
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { index, item in
                if index > 0 { Divider().overlay(themed.palette.sepColor).padding(.leading, 52) }
                row(item.title, symbol: Self.symbol(item), route: Self.route(item), detail: detail(item))
            }
        }
    }

    /// Where a row goes.
    static func route(_ row: LibraryRow) -> Route {
        switch row {
        case .playlists: .playlists
        case .artists: .artists
        case .albums: .albums
        case .songs: .songs
        case .genres: .genres
        case .favourites: .favourites
        case .downloads: .downloads
        case .finds: .finds
        case .requests: .requests
        case .discover: .discover
        case .trending: .trending   // round 14 A4
        case .recommended: .recommended
        }
    }

    /// A row's symbol: the shared one (CarPlay uses it too), except Finds, which keeps the Finds tab's record.
    static func symbol(_ row: LibraryRow) -> String { row == .finds ? "record.circle" : row.symbol }

    private func detail(_ row: LibraryRow) -> String? {
        switch row {
        case .finds: findsDetail
        case .requests: requestsDetail
        default: nil
        }
    }

    private var recentlyAdded: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text("Recently added").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("library-recently-added")
                .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            LoadableView(state: recent, retry: load) { albums in
                AlbumGrid(albums: albums) { $0.artist }
            }
        }
    }

    /// "2 new" while there are New finds.
    private var findsDetail: String? {
        let n = model.findsShelf().newFinds.count
        return n == 0 ? nil : "\(n) new"
    }

    /// "2 on their way" while requests are in progress (and releases Bring in more is bringing in: they share the
    /// limit of five, FL4).
    private var requestsDetail: String? {
        let n = model.onTheirWay
        return n == 0 ? nil : "\(n) on \(n == 1 ? "its" : "their") way"
    }

    private func row(_ title: String, symbol: String, route: Route, detail: String? = nil) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: Tokens.Spacing.m) {
                // Y7 audit: the icon column grows with the text, so large icons no longer run into the titles.
                Image(systemName: symbol).font(.title3).foregroundStyle(themed.palette.accentInkColor)
                    .frame(width: iconWidth).accessibilityHidden(true)
                Text(title).font(.title3)
                Spacer()
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(themed.palette.ink2Color)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(themed.palette.ink2Color).accessibilityHidden(true)
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(themed.palette.inkColor)
        .accessibilityIdentifier("library-\(title.lowercased())")
    }

    private func load() async {
        do {
            recent = .loaded(try await model.request { try await $0.albumList(.newest, size: 24, offset: 0) })
        } catch {
            recent = recent.failing(error, noticeTo: model)   // Round 13 Z2: also never for a load cut short
        }
    }
}

/// Album tiles in columns (two on a phone, more on wider screens; Round 27 H: three at least with Small covers, D296).
struct AlbumGrid: View {
    @Environment(AppModel.self) private var model
    let albums: [Album]
    let subtitle: (Album) -> String
    var onAppearLast: (() -> Void)?
    @State private var width: CGFloat = 350
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Columns of at least 150 pt (two at least); Y7 audit: at accessibility sizes tiles are at least
    /// `AlbumTile.accessibilityWidth` wide, so a phone shows one column instead of two overlapping ones.
    /// Round 27 H (owner, 2026-11-14): Small covers, columns of at least 100 pt, three at least (three on a 375 pt
    /// phone); accessibility sizes are the same either way (D296).
    static func columnCount(width: CGFloat, accessibility: Bool, size: AlbumCoverSize = .large) -> Int {
        if accessibility {
            return max(1, Int((width + Tokens.Spacing.l) / (AlbumTile.accessibilityWidth + Tokens.Spacing.l)))
        }
        let minimum: CGFloat = size == .small ? 100 : 150
        let fit = Int((width + Tokens.Spacing.l) / (minimum + Tokens.Spacing.l))
        return max(size == .small ? 3 : 2, fit)
    }

    /// A tile's width for `columns` in `width`: at least 100 pt with Large covers (as before); with Small, whatever
    /// three columns leave on the narrowest phone (about 83 pt on a 320 pt one), so they never run off the screen.
    static func tileWidth(width: CGFloat, columns: Int, size: AlbumCoverSize) -> CGFloat {
        let count = CGFloat(max(1, columns))
        return max(size == .small ? 60 : 100, (width - (count - 1) * Tokens.Spacing.l) / count)
    }

    /// Small covers have their own tile (title and subtitle on one line each); at accessibility sizes the large tile,
    /// as the columns are the same there.
    static func usesSmallTiles(_ size: AlbumCoverSize, accessibility: Bool) -> Bool { size == .small && !accessibility }

    private var size: AlbumCoverSize { model.preferences.layout.albumCovers }
    private var columns: Int { Self.columnCount(width: width, accessibility: typeSize.isAccessibilitySize, size: size) }
    private var tileWidth: CGFloat { Self.tileWidth(width: width, columns: columns, size: size) }

    var body: some View {
        let small = Self.usesSmallTiles(size, accessibility: typeSize.isAccessibilitySize)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: Tokens.Spacing.l, alignment: .top),
                                 count: columns),
                  alignment: .leading, spacing: small ? Tokens.Spacing.l : Tokens.Spacing.xl) {
            ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                NavigationLink(value: Route.album(id: album.id)) {
                    AlbumGridTile(album: album, subtitle: subtitle(album), width: tileWidth, small: small)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("album-\(index)")
                .onAppear { if index == albums.count - 1 { onAppearLast?() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
    }
}

/// Round 27 H (D296): one album grid tile, large (`AlbumTileView`, as before) or small (`SmallAlbumTile`), with the
/// album's long-press menu and download mark either way.
struct AlbumGridTile: View {
    @Environment(AppModel.self) private var model
    let album: Album
    let subtitle: String
    let width: CGFloat
    let small: Bool

    var body: some View {
        if small {
            Artwork(album.coverArtId, side: width) { image in
                SmallAlbumTile(title: album.name, subtitle: subtitle, artwork: image, width: width,
                               mark: model.downloadIndex.mark(album: album))   // P1
            }
            .albumMenu(album)   // R7 Favourite, R8 Add to playlist…, P4 Reload artwork
        } else {
            AlbumTileView(album: album, subtitle: subtitle, width: width)
        }
    }
}

/// Round 27 H (owner, 2026-11-14): "an option to view albums as smaller icons" (D296). A small cover with its title and
/// subtitle on one line each (truncated; fix round 1: the title two lines from xLarge text up), at least 44 pt high; VoiceOver reads both, and the download mark, as the
/// large tile does.
struct SmallAlbumTile: View {
    let title: String
    let subtitle: String
    let artwork: Image?
    let width: CGFloat
    var mark: DownloadMark = .none
    @Environment(\.dynamicTypeSize) private var typeSize
    private let themed = Themed()

    static func accessibilityLabel(title: String, subtitle: String) -> String { "\(title), \(subtitle)" }

    /// Fix round 1 (design M1): from xLarge text up a title may take two lines, so it isn't cut to a few letters.
    static func titleLines(_ typeSize: DynamicTypeSize) -> Int { typeSize >= .xLarge ? 2 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            SleeveArt(image: artwork, side: width)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.semibold)).lineLimit(Self.titleLines(typeSize))
                HStack(spacing: 2) {
                    Text(subtitle).font(.caption2).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                    DownloadMarkView(mark)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(minHeight: Tokens.minHitSize)
        .foregroundStyle(themed.palette.inkColor)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(title: title, subtitle: subtitle))
        .accessibilityValue(mark.joined(to: nil))
    }
}

/// Round 27 H (D296): the words for album covers (Settings › Home & Library, Library › Albums' toolbar).
enum AlbumCoversCopy {
    static let setting = "Album covers"
    /// Fix round 1 (design H1): why the choice does nothing at the largest text sizes.
    static let accessibilityNote = "At the largest text sizes, covers stay large so titles can be read."
    /// Fix round 1 (design L1): said by VoiceOver after the toolbar's tap.
    static func announcement(_ size: AlbumCoverSize) -> String { size == .small ? "Small covers" : "Large covers" }

    static func title(_ size: AlbumCoverSize) -> String {
        switch size {
        case .large: "Large"
        case .small: "Small"
        }
    }

    /// The toolbar button says what a tap does.
    static func toolbarLabel(_ size: AlbumCoverSize) -> String { size == .large ? "Smaller covers" : "Larger covers" }

    static func toolbarSymbol(_ size: AlbumCoverSize) -> String { size == .large ? "square.grid.3x3" : "square.grid.2x2" }
}
