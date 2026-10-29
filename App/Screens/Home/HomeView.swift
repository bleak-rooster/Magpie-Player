import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Home (spec §3, Task 20): the "Finish setting up" card pinned on top, then the owner's sections in the owner's order
/// (Settings › Home & Library › Home, or Edit Home at the bottom). Made for you shows only with a listening-history
/// token (Task 7.1c) and fills in after the library's shelves. Empty sections are left out. Offline (Task 14): "You're
/// offline", then the Downloaded shelf (albums on the phone).
struct HomeView: View {
    @Environment(AppModel.self) private var model
    /// What has been read so far (`HomeLoad`); failed until the first read answers.
    @State private var shelves: Loadable<HomeLoad> = .loading
    @State private var editsHome = false
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
            await load(fresh: true)
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
        // Reads what a change needs: a section turned on or one that failed, offline or back online (everything
        // again), a song that landed on or left the phone (Downloaded), the genre preferences (Genres). A reorder or a
        // section turned off reads nothing.
        .task(id: key) { await load(fresh: false) }
        // Its own task, so the library's shelves never wait for it. Read once (Refresh reads again), and again
        // whenever the token is saved, replaced or removed (which also clears the shelf).
        .task(id: model.listenBrainzTokenGeneration) {
            if model.madeForYouShelf.isEmpty, !model.isOffline { await model.refreshMadeForYou() }
        }
        .sheet(isPresented: $editsHome) {
            NavigationStack {
                HomeLayoutView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { editsHome = false }.accessibilityIdentifier("home-edit-done")
                        }
                    }
                    .magpieScreen()   // Task 21: the app's theme in the sheet too
            }
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
            LoadableView(state: shelves, retry: { await load(fresh: true) }) { read in
                let sections = model.homeSections.filter { shows($0, read) }
                if sections.isEmpty {
                    empty
                } else {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                        ForEach(sections, id: \.self) { section in
                            if section == .madeForYou {
                                madeForYouShelf
                            } else if let shelf = read.found[section] {
                                ShelfView(shelf: shelf)
                            } else {
                                failure(section)
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

    private func shows(_ section: HomeSection, _ read: HomeLoad) -> Bool {
        section == .madeForYou ? !model.madeForYouShelf.isEmpty : read.found[section] != nil || read.showsFailure(section)
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

    /// Reads what `HomeLoad` says the change needs (everything when `fresh`). What was read stays on screen if a read
    /// fails; a section that failed is read again on the next change, and says so until then.
    private func load(fresh: Bool) async {
        let want = key
        var state = shelves.value ?? HomeLoad()
        let read = state.read(for: want, fresh: fresh)
        do {
            let result = read.sections.isEmpty ? AppModel.HomeRead(shelves: [], failed: [])
                                               : try await model.homeRead(for: read.sections)
            guard !Task.isCancelled else { return }
            state.record(read, for: want, shelves: result.shelves, failed: result.failed)
            shelves = .loaded(state)
        } catch {
            guard !Task.isCancelled else { return }
            if shelves.value == nil {
                shelves = .failed(BrowseErrorCopy.message(for: error))
            } else {
                state.record(read, for: want, shelves: [], failed: Set(read.sections))
                shelves = .loaded(state)
            }
        }
    }
}

/// One shelf; each tile opens what it is (an album, a playlist, a genre group).
private struct ShelfView: View {
    let shelf: HomeShelf

    var body: some View {
        ShelfSection(shelf.section.title) {
            ForEach(shelf.items) { item in
                tile(item)
            }
        }
        .accessibilityIdentifier("home-\(shelf.section.rawValue)")
    }

    @ViewBuilder private func tile(_ item: HomeShelf.Item) -> some View {
        switch item {
        case .album(let album), .downloadedAlbum(let album):
            NavigationLink(value: Route.album(id: album.id)) {
                AlbumTileView(album: album, subtitle: album.artist)
            }
            .buttonStyle(.plain)
        case .playlist(let playlist):
            NavigationLink(value: Route.playlist(id: playlist.id)) {
                Artwork(playlist.coverArtId, side: 140) { image in
                    AlbumTile(title: playlist.name, subtitle: playlist.songCount == 1 ? "1 song" : "\(playlist.songCount) songs",
                              artwork: image)
                }
            }
            .buttonStyle(.plain)
        case .genreGroup(let section):
            NavigationLink(value: Route.genreGroup(id: section.group.id)) {
                AlbumTile(title: section.group.name,
                          subtitle: section.albumCount == 1 ? "1 album" : "\(section.albumCount) albums")
            }
            .buttonStyle(.plain)
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
