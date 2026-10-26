import DesignSystem
import MagpieCore
import SwiftUI

/// Home: the "Finish setting up" card, then Jump back in (recent), Recently added (newest) and
/// Most played (frequent). Empty shelves are left out.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var shelves: Loadable<Shelves> = .loading
    private let themed = Themed()

    struct Shelves {
        var recent: [Album]
        var newest: [Album]
        var frequent: [Album]
        var isEmpty: Bool { recent.isEmpty && newest.isEmpty && frequent.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                FinishSettingUpCard()
                    .padding(.horizontal, Tokens.Spacing.margin)
                LoadableView(state: shelves, retry: load) { s in
                    if s.isEmpty {
                        ContentUnavailableView("No music yet", systemImage: "music.note",
                                               description: Text("Albums show up here once your server has some."))
                    } else {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                            shelf("Jump back in", s.recent)
                            shelf("Recently added", s.newest)
                            shelf("Most played", s.frequent)
                        }
                    }
                }
            }
            .padding(.vertical, Tokens.Spacing.l)
        }
        .refreshable { await load() }
        .magpieLargeTitle("Home")
        .magpieScreen()
        .task { if shelves.value == nil { await load() } }
    }

    @ViewBuilder private func shelf(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            ShelfSection(title) {
                ForEach(albums, id: \.id) { album in
                    NavigationLink(value: Route.album(id: album.id)) {
                        AlbumTileView(album: album, subtitle: album.artist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() async {
        do {
            async let recent = model.request { try await $0.albumList(.recent, size: 12, offset: 0) }
            async let newest = model.request { try await $0.albumList(.newest, size: 12, offset: 0) }
            async let frequent = model.request { try await $0.albumList(.frequent, size: 12, offset: 0) }
            shelves = .loaded(Shelves(recent: try await recent, newest: try await newest, frequent: try await frequent))
        } catch {
            if shelves.value == nil { shelves = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }
}

/// D9: setup continues from Home. Opens the Lidarr connection sheet (Settings reuses it in M5).
private struct FinishSettingUpCard: View {
    @Environment(AppModel.self) private var model
    @State private var showsConnect = false
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        let connected = model.lidarr != nil
        Button { showsConnect = true } label: {
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                Image(systemName: connected ? "checkmark.circle" : "sparkles")
                    .font(.title2)
                    .foregroundStyle(p.accentInkColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("Finish setting up").font(.headline)
                    Text(connected
                         ? "Search now shows music that's not in your library. Bringing songs home comes next."
                         : "Let Magpie find songs you don't have yet and bring the ones you love home.")
                        .font(.subheadline)
                        .foregroundStyle(p.ink2Color)
                    Text(connected ? "Review" : "Continue")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(p.accentInkColor)
                        .padding(.top, Tokens.Spacing.xs)
                }
                Spacer(minLength: 0)
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
    }
}

/// An `AlbumTile` with its cover loaded.
struct AlbumTileView: View {
    let album: Album
    let subtitle: String
    var width: CGFloat = 140

    var body: some View {
        Artwork(album.coverArtId, side: width) { image in
            AlbumTile(title: album.name, subtitle: subtitle, artwork: image, width: width)
        }
    }
}
