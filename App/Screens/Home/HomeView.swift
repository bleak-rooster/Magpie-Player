import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Home: the "Finish setting up" card, then Jump back in (recent), Made for you (only with a listening-history
/// token, Task 7.1c; fills in after the library's shelves and is left out when it can't be read), Recently added
/// (newest) and Most played (frequent). Empty shelves are left out.
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
                            madeForYouShelf
                            shelf("Recently added", s.newest)
                            shelf("Most played", s.frequent)
                        }
                    }
                }
            }
            .padding(.vertical, Tokens.Spacing.l)
        }
        .refreshable {
            async let made: Void = model.refreshMadeForYou()
            await load()
            await made
        }
        .magpieLargeTitle("Home")
        // H3 M7: a solid bar in the page colour once scrolled, so covers don't show through under the title and
        // the status bar.
        .toolbarBackground(themed.palette.bgColor, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .magpieScreen()
        .task { if shelves.value == nil { await load() } }
        // Its own task, so the library's shelves never wait for it. Read once (Refresh reads again), and again
        // whenever the token is saved, replaced or removed (which also clears the shelf).
        .task(id: model.listenBrainzTokenGeneration) {
            if model.madeForYouShelf.isEmpty { await model.refreshMadeForYou() }
        }
    }

    @ViewBuilder private var madeForYouShelf: some View {
        if !model.madeForYouShelf.isEmpty {
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

/// What Home's "Finish setting up" card says. About the music; it points to Settings without naming a service (§5).
enum HomeCopy {
    static func finishSettingUp(connected: Bool) -> String {
        connected
            ? "Search shows music that's not in your library. To bring songs home, finish the last steps in Settings."
            : "Let Magpie find songs you don't have yet and bring the ones you love home."
    }
}

/// D9: setup continues from Home. Opens the Lidarr connection sheet (also in Settings).
private struct FinishSettingUpCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsConnect = false
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        let connected = model.lidarr != nil
        // Symbol above the text at accessibility sizes, so the text keeps the card's full width (D15).
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Spacing.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Tokens.Spacing.m))
        Button { showsConnect = true } label: {
            layout {
                Image(systemName: connected ? "checkmark.circle" : "sparkles")
                    .font(.title2)
                    .foregroundStyle(p.accentInkColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("Finish setting up").font(.headline)
                    Text(HomeCopy.finishSettingUp(connected: connected))
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
