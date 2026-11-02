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
            if model.isOffline { await model.checkReachability() } else if model.showsRecentlyAddedGrid { await load() }
        }
        .magpieLargeTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("open-settings")
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
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
                Image(systemName: symbol).font(.title3).foregroundStyle(themed.palette.accentInkColor)
                    .frame(width: 28).accessibilityHidden(true)
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
            if recent.value == nil { recent = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }
}

/// Album tiles in columns (two on a phone, more on wider screens).
struct AlbumGrid: View {
    let albums: [Album]
    let subtitle: (Album) -> String
    var onAppearLast: (() -> Void)?
    @State private var width: CGFloat = 350

    private var columns: Int { max(2, Int((width + Tokens.Spacing.l) / (150 + Tokens.Spacing.l))) }
    private var tileWidth: CGFloat { max(100, (width - CGFloat(columns - 1) * Tokens.Spacing.l) / CGFloat(columns)) }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: Tokens.Spacing.l, alignment: .top),
                                 count: columns),
                  alignment: .leading, spacing: Tokens.Spacing.xl) {
            ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                NavigationLink(value: Route.album(id: album.id)) {
                    AlbumTileView(album: album, subtitle: subtitle(album), width: tileWidth)
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
