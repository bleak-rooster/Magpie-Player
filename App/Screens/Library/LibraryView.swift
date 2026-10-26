import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// Library: Playlists, Artists, Albums, Requests, then recently added albums. (Finds arrive in M6.)
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var recent: Loadable<[Album]> = .loading
    @State private var showsSettings = false
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                VStack(spacing: 0) {
                    row("Playlists", symbol: "music.note.list", route: .playlists)
                    Divider().overlay(p.sepColor).padding(.leading, 52)
                    row("Artists", symbol: "music.mic", route: .artists)
                    Divider().overlay(p.sepColor).padding(.leading, 52)
                    row("Albums", symbol: "square.stack", route: .albums)
                    Divider().overlay(p.sepColor).padding(.leading, 52)
                    row("Requests", symbol: "arrow.down.circle", route: .requests, detail: requestsDetail)
                }
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    Text("Recently added").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    LoadableView(state: recent, retry: load) { albums in
                        AlbumGrid(albums: albums) { $0.artist }
                    }
                }
            }
            .padding(.vertical, Tokens.Spacing.s)
        }
        .refreshable { await load() }
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
        .task { if recent.value == nil { await load() } }
    }

    /// "2 on their way" while requests are in progress.
    private var requestsDetail: String? {
        let n = model.requests.filter(\.isActive).count
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
