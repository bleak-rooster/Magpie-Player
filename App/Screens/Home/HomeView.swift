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
            if model.isOffline {
                OfflineHome()   // Task 14: only what's on the phone
            } else {
                online
            }
        }
        .refreshable {
            guard !model.isOffline else { return await model.checkReachability() }
            async let made: Void = model.refreshMadeForYou()
            await load()
            await made
        }
        .magpieLargeTitle("Home")
        // H3 M7: a solid bar in the page colour once scrolled, so covers don't show through under the title and
        // the status bar.
        .toolbarBackground(themed.palette.bgColor, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        // Final fix 2 H3-M7: the bar's soft scroll-edge blur still let covers show behind the large title; a hard
        // edge keeps the title on the page colour.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .magpieScreen()
        // Again when back online: what failed while offline loads now.
        .task(id: model.isOffline) { if !model.isOffline, shelves.value == nil { await load() } }
        // Its own task, so the library's shelves never wait for it. Read once (Refresh reads again), and again
        // whenever the token is saved, replaced or removed (which also clears the shelf).
        .task(id: model.listenBrainzTokenGeneration) {
            if model.madeForYouShelf.isEmpty, !model.isOffline { await model.refreshMadeForYou() }
        }
    }

    private var online: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
            if model.showsFinishSettingUp {   // final fix 2 B-M2: only while a step is left
                FinishSettingUpCard()
                    .padding(.horizontal, Tokens.Spacing.margin)
            }
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

/// Home offline (Task 14): "You're offline", then the Downloaded shelf (albums on the phone, at most 12). Task 20
/// keeps this line and this shelf's source.
private struct OfflineHome: View {
    @Environment(AppModel.self) private var model
    @State private var albums: [Album]?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
            OfflineNotice()
                .padding(.horizontal, Tokens.Spacing.margin)
            if let albums {
                if albums.isEmpty {
                    ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                           description: Text("Albums and playlists you download play here without a connection."))
                } else {
                    ShelfSection("Downloaded") {
                        ForEach(albums, id: \.id) { album in
                            NavigationLink(value: Route.album(id: album.id)) {
                                AlbumTileView(album: album, subtitle: album.artist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .accessibilityIdentifier("home-downloaded")
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        // Again whenever a song lands on or leaves the phone.
        .task(id: model.downloads?.localFiles.count) { albums = Array(await model.offlineCatalog.albums().prefix(12)) }
    }
}

/// What Home's "Finish setting up" card says. About the music; it points to Settings without naming a service (§5).
enum HomeCopy {
    /// Try works; only Finds is left (B-M2).
    static let finishFinds = "Your Finds folder needs one more step in Settings."

    static func finishSettingUp(connected: Bool) -> String {
        connected
            ? "Search shows music that's not in your library. To bring songs home, finish the last steps in Settings."
            : "Let Magpie find songs you don't have yet and bring the ones you love home."
    }
}

/// D9: setup continues from Home. Opens the Lidarr connection sheet until one is connected; then Review opens
/// Settings, where the steps left are (final fix 2 B-M2).
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
        .sheet(isPresented: $showsSettings) { SettingsView() }
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
