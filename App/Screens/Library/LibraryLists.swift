import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// All artists, A–Z in Navidrome's order (its default articles dropped: "The Midnight Cartographers" under M), with
/// the A–Z bar (P2; round 11 R2: the custom bar, so the letter bubble shows here too). Round 11 R11: album artists
/// only, or every artist, from the toolbar's filter menu (the same preference as Settings › Library).
/// Round 24 (owner, 2026-11-08): a "Search artists" field at the top (D224), and a header per letter past 25 artists
/// (D225).
/// Round 28 O3 (owner, 2026-11-15; D340): offline, the artists on the phone (album artists only, or every artist, as
/// the filter says), with the A–Z bar and headers; nothing on the phone says "Nothing downloaded yet".
struct ArtistsListView: View {
    @Environment(AppModel.self) private var model
    @State private var artists: Loadable<[Artist]> = .loading
    @State private var sections: [LetterIndex.Section] = []
    /// The "Album artists only" value (round 28 O3: and the offline key) the list was read for: coming back to the list
    /// doesn't read it again (M1).
    @State private var loadedFor: String?
    /// Round 24 (D224): the list's own search, artists only.
    @State private var search: SearchModel?
    /// Round 28 O3 fix round 1 (design H3): offline, nothing at all is on the phone.
    @State private var phoneEmpty = false
    private let themed = Themed()

    var body: some View {
        let albumArtistsOnly = model.preferences.layout.albumArtistsOnly
        ScrollViewReader { proxy in
            List {
                LoadableView(state: artists, retry: load) { artists in
                    LetterSectionedRows(items: artists, sections: sections, id: \.id) { artist in row(artist) }
                }
                .listRowSeparatorTint(themed.palette.sepColor)
            }
            .listStyle(.plain)
            .letterIndex(available: Set(sections.map(\.key)), hidden: sections.isEmpty) { letter in
                guard let target = LetterIndex.target(letter, in: sections), let list = artists.value else { return }
                proxy.scrollToLetter(index: target.range.lowerBound, sections: sections, itemCount: list.count) { list[$0].id }
            }
        }
        // Round 28 O3 (D340): offline with nothing on the phone, today's Home copy.
        // Fix round 1 (design H3): with songs on the phone, the list is empty only through "Album artists only".
        .overlay {
            if model.isOffline, artists.value?.isEmpty == true {
                let empty = OfflineLists.empty(.albumArtists, phoneEmpty: phoneEmpty)
                NothingDownloadedView(title: empty.title, detail: empty.detail)
            }
        }
        // Fix round 1 (M4): no field over an empty or failed list.
        .kindSearch(.artists, search, available: artists.value?.isEmpty == false)
        .task { if search == nil { search = model.kindSearchModel(.artists) } }
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)   // the field sits where a large title would
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Album artists only", isOn: Binding(
                        get: { model.preferences.layout.albumArtistsOnly },
                        set: { on in model.updatePreferences { $0.layout.albumArtistsOnly = on } }))
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                }
                .accessibilityLabel("Filter")
                .accessibilityValue(albumArtistsOnly ? "Album artists only" : "All artists")
                .accessibilityIdentifier("artists-filter")
            }
        }
        .magpieScreen()
        // Again when "Album artists only" changes (here or in Settings). Round 28 O3 (D340): and offline or back online,
        // and offline when what's on the phone changes.
        .task(id: "\(albumArtistsOnly)|\(model.offlinePageKey)") {
            let key = "\(albumArtistsOnly)|\(model.offlinePageKey)"
            guard loadedFor != key || artists.value == nil else { return }
            loadedFor = key
            await load()
        }
    }

    private func row(_ artist: Artist) -> some View {
        NavigationLink(value: Route.artist(id: artist.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(artist.coverArtId, side: 44) { image in
                    SleeveArt(image: image, side: 44).clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(artist.name).font(.body)
                    HStack(spacing: 4) {
                        Text(artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums")
                            .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        DownloadMarkView(model.downloadIndex.listMark(artist: artist))   // P1
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        .artistMenu(artist)   // R12 Play next · Add to queue, R7 Favourite, P4 Reload artwork
        .collectionSwipeActions(.artist(artist.id), in: .list)   // R12
        .listRowBackground(Color.clear)
        .id(artist.id)
    }

    private func load() async {
        do {
            // Round 28 O3 (D340): offline, the artists on the phone (the same filter), nothing asked of the server.
            let read = model.isOffline
                ? await OfflineLists.artists(model, albumArtistsOnly: model.preferences.layout.albumArtistsOnly)
                : try await model.libraryArtists()
            if model.isOffline { phoneEmpty = await OfflineLists.phoneEmpty(model) }
            let sorted = Self.sorted(read)
            sections = LetterIndex.sections(sorted, ignoringArticles: LetterIndex.navidromeArticles, name: \.name)
            artists = .loaded(sorted)
        } catch {
            if artists.value == nil { artists = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }

    /// By name without a leading article, as Navidrome sorts them, so each letter is one run.
    nonisolated static func sorted(_ artists: [Artist]) -> [Artist] {
        let articles = LetterIndex.navidromeArticles
        return artists.map { (String(LetterIndex.sortName($0.name, ignoringArticles: articles)), $0) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .map(\.1)
    }
}

/// All albums, A–Z, a page at a time, with the letter index (P2: `PagedLetterList` jumps over the server's order,
/// which drops Navidrome's default articles). Round 24 (owner, 2026-11-08): a "Search albums" field at the top (D224),
/// and a header per loaded letter run past 25 albums (D225).
/// Round 28 O3 (owner, 2026-11-15; D340): offline, the albums on the phone (`OfflineAlbumsList`), nothing asked of the
/// server.
struct AlbumsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var list: PagedLetterList<Album>?
    /// The running letter jump (its seek reads the server), cancelled when the screen goes.
    @State private var jumpTask: Task<Void, Never>?
    /// Round 24 (D224): the list's own search, albums only.
    @State private var search: SearchModel?

    var body: some View {
        if model.isOffline { OfflineAlbumsList() } else { online }
    }

    private var online: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let list {
                    LoadableView(state: list.items, retry: { await list.load() }) { albums in
                        if list.windowStart > 0 {
                            Button(list.loadingEarlier ? "Loading…" : "Show earlier albums") {
                                Task { await list.loadEarlier() }
                            }
                            .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                            .padding(.top, Tokens.Spacing.s)
                            .accessibilityIdentifier("albums-earlier")
                        }
                        AlbumLetterGrid(albums: albums, sections: list.sections,
                                        onAppearLast: { Task { await list.loadMore() } },
                                        scrollRequest: list.scrollRequest, proxy: proxy)
                            .padding(.vertical, Tokens.Spacing.l)
                        if let moreError = list.moreError {
                            VStack(spacing: Tokens.Spacing.s) {
                                Text(moreError).font(.footnote).multilineTextAlignment(.center)
                                Button("Try again") { Task { await list.loadMore() } }
                                    .frame(minHeight: Tokens.minHitSize)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, Tokens.Spacing.xxl)
                            .accessibilityIdentifier("albums-more-error")
                        } else if list.loadingMore {
                            ProgressView().padding(.bottom, Tokens.Spacing.xxl)
                        }
                    }
                }
            }
            .letterIndex(available: list?.availableLetters ?? [], hidden: list?.items.value?.isEmpty != false) { letter in
                pick(letter)
            }
            .overlay { if list?.seeking == true { ProgressView().accessibilityLabel("Finding albums") } }
            // The grid takes the list's scroll requests: it knows its headers and columns (fix round 1, I2).
        }
        .kindSearch(.albums, search, available: list?.items.value?.isEmpty == false)   // fix round 1 (M4)
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)   // the field sits where a large title would
        .toolbar {
            // Round 27 H (owner, 2026-11-14): smaller or larger covers, the same setting as Settings › Home & Library
            // (D296). The label says what a tap does.
            // Fix round 1 (design H1, L1): hidden at accessibility sizes, where covers stay large (no dead control); a
            // Label, so Large Content Viewer and Voice Control get its name; VoiceOver hears the new size.
            if Self.showsCoverToggle(accessibility: typeSize.isAccessibilitySize) {
                ToolbarItem(placement: .topBarTrailing) {
                    let covers = model.preferences.layout.albumCovers
                    Button {
                        Self.toggleCovers(model)
                        AccessibilityNotification.Announcement(
                            AlbumCoversCopy.announcement(model.preferences.layout.albumCovers)).post()
                    } label: {
                        Label(AlbumCoversCopy.toolbarLabel(covers), systemImage: AlbumCoversCopy.toolbarSymbol(covers))
                            .labelStyle(.iconOnly)
                            .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                    }
                    .accessibilityIdentifier("albums-cover-size")
                }
            }
        }
        .magpieScreen()
        .onDisappear { jumpTask?.cancel() }
        .task {
            if search == nil { search = model.kindSearchModel(.albums) }
            if list == nil {
                let model = model
                list = PagedLetterList(pageSize: AppModel.albumsPageSize, articles: LetterIndex.navidromeArticles,
                                       name: \.name, id: \.id,
                                       read: { try await model.albumsWindow(from: $0) },
                                       seek: { try await model.albumOffset(forLetter: $0) })
            }
            if list?.items.value == nil { await list?.load() }
        }
    }

    /// Fix round 1 (design H1): the toolbar button only where the choice changes the grid.
    static func showsCoverToggle(accessibility: Bool) -> Bool { !accessibility }

    /// Round 27 H (D296): the toolbar's tap, Large to Small and back.
    static func toggleCovers(_ model: AppModel) {
        model.updatePreferences { $0.layout.albumCovers = $0.layout.albumCovers == .large ? .small : .large }
    }

    /// A letter picked while a jump runs joins it (the latest wins); otherwise a new jump, kept so leaving cancels it.
    private func pick(_ letter: String) {
        guard let list else { return }
        if let task = list.startJump(to: letter) { jumpTask = task }   // nil: it joined the running jump
    }
}

/// Albums as tiles in columns, A–Z: one grid, and (D225: more than 25 and the A–Z bar on screen) a pinned header per
/// letter run in it (fix round 1, I1: one `LazyVGrid` with sections, one width, so a jump reaches any loaded run). Tiles
/// keep their place in the whole list ("album-N"). It takes the list's scroll requests itself, since it knows whether
/// headers show and how many tiles a row holds: a jump lands on the letter's header, never under it (I2).
struct AlbumLetterGrid: View {
    let albums: [Album]
    let sections: [LetterIndex.Section]
    var onAppearLast: (() -> Void)?
    var scrollRequest: PagedLetterList<Album>.ScrollRequest?
    var proxy: ScrollViewProxy?
    @Environment(AppModel.self) private var model
    @Environment(\.letterIndexShown) private var barShown
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 350

    /// Round 27 H (D296): the one album covers setting, as every `AlbumGrid`; the letter jump's row length follows it.
    private var size: AlbumCoverSize { model.preferences.layout.albumCovers }
    private var small: Bool { AlbumGrid.usesSmallTiles(size, accessibility: typeSize.isAccessibilitySize) }
    private var columns: Int { AlbumGrid.columnCount(width: width, accessibility: typeSize.isAccessibilitySize, size: size) }
    private var tileWidth: CGFloat { AlbumGrid.tileWidth(width: width, columns: columns, size: size) }

    var body: some View {
        let runs = LetterSectionHeader.runs(sections, itemCount: albums.count, barShown: barShown)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: Tokens.Spacing.l, alignment: .top),
                                 count: columns),
                  alignment: .leading, spacing: small ? Tokens.Spacing.l : Tokens.Spacing.xl,
                  pinnedViews: [.sectionHeaders]) {
            if runs.isEmpty {
                tiles(albums.indices)
            } else {
                ForEach(runs, id: \.range.lowerBound) { run in
                    Section {
                        tiles(run.range)
                    } header: {
                        // The grid sits on the page's margins; its header bar runs edge to edge.
                        LetterSectionHeader(run: run, pinned: true)
                            .padding(.horizontal, -Tokens.Spacing.largeTitleMargin)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
        .onChange(of: scrollRequest) { _, request in
            guard let request, let proxy else { return }
            guard let index = albums.firstIndex(where: { $0.id == request.id }) else {
                return proxy.scrollTo(request.id, anchor: .top)
            }
            proxy.scrollToLetter(index: index, sections: sections, itemCount: albums.count, barShown: barShown,
                                 rowLength: columns) { albums[$0].id }
        }
    }

    private func tiles(_ indices: Range<Int>) -> some View {
        ForEach(Array(zip(indices, albums[indices])), id: \.1.id) { index, album in
            NavigationLink(value: Route.album(id: album.id)) {
                AlbumGridTile(album: album, subtitle: album.artist, width: tileWidth, small: small)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("album-\(index)")
            .onAppear { if index == albums.count - 1 { onAppearLast?() } }
        }
    }
}

/// All playlists, A–Z, with the A–Z bar (P2; round 11 R2: the custom bar, so the letter bubble shows here too).
/// Round 11 R8: "+" makes a new playlist (a name, then `createPlaylist`); the list reads again after any change.
/// Round 22 R22P (owner, 2026-11-06): All or Yours above the list, remembered per account (D179, D180).
/// Round 24 (owner, 2026-11-08): in All, who made each playlist under its name and what All covers at the end (D223); a
/// header per letter past 25 playlists (D225).
/// Round 28 O3 (owner, 2026-11-15; D340): offline, the playlists on the phone (downloaded, and per Q3 the ones read
/// online since this build that hold a download), with no "+"; nothing on the phone says "Nothing downloaded yet".
struct PlaylistsListView: View {
    @Environment(AppModel.self) private var model
    /// Every playlist but Discover's, A–Z; `show` picks what is listed from it.
    @State private var playlists: Loadable<[Playlist]> = .loading
    @State private var show: PlaylistShow = .all
    @State private var sections: [LetterIndex.Section] = []
    @State private var naming = false
    @State private var newName = ""
    @State private var createError: String?
    /// The playlists revision (round 28 O3: and the offline key) the list was read for (M1).
    @State private var loadedRevision: String?
    /// Round 28 O3 fix round 1 (design H3): offline, nothing at all is on the phone (the empty list says so).
    @State private var phoneEmpty = false
    private let themed = Themed()

    var body: some View {
        ScrollViewReader { proxy in
            List {
                LoadableView(state: playlists, retry: load) { playlists in
                    let shown = listed(playlists)
                    LetterSectionedRows(items: shown, sections: sections, id: \.id) { playlist in row(playlist) }
                    // Round 24 (D223): what All is: everything this account may see (Navidrome's own rule).
                    if let footer = show.footer(offline: model.isOffline), !shown.isEmpty {   // round 28 O3 fix round 1
                        Section {
                            Text(footer)
                                .font(.footnote)
                                .foregroundStyle(themed.palette.ink2Color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .accessibilityIdentifier("playlist-show-footer")
                        }
                    }
                }
                .listRowSeparatorTint(themed.palette.sepColor)
            }
            .listStyle(.plain)
            .letterIndex(available: Set(sections.map(\.key)), hidden: sections.isEmpty) { letter in
                guard let target = LetterIndex.target(letter, in: sections), let all = playlists.value else { return }
                let shown = listed(all)
                guard shown.indices.contains(target.range.lowerBound) else { return }
                proxy.scrollToLetter(index: target.range.lowerBound, sections: sections, itemCount: shown.count) {
                    shown[$0].id
                }
            }
        }
        // Over the list, not a row in it, so no separators frame it (H3 M8). An empty Yours says so (D179).
        // Round 28 O3 (D340; fix round 1, design H3): offline, "Nothing downloaded yet" only with nothing on the phone;
        // otherwise what this list lacks (Yours with only others' playlists here says so too).
        .overlay {
            if let all = playlists.value, listed(all).isEmpty {
                if model.isOffline, all.isEmpty {
                    let empty = OfflineLists.empty(.playlists, phoneEmpty: phoneEmpty)
                    NothingDownloadedView(title: empty.title, detail: empty.detail)
                } else {
                    ContentUnavailableView(show.emptyTitle(offline: model.isOffline), systemImage: "music.note.list")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { showPicker }
        .onAppear { show = model.playlistShow }
        .onChange(of: show) {
            model.playlistShow = show
            if let all = playlists.value { sections = LetterIndex.sections(listed(all), name: \.name) }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)   // as with rows; an empty list would otherwise show a large title
        .toolbar {
            // Round 28 O3 (D345): offline a new playlist can't be made, so "+" hides rather than sitting greyed.
            if !model.isOffline {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newName = ""
                        naming = true
                    } label: {
                        Image(systemName: "plus").frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                    }
                    .accessibilityLabel("New playlist")
                    .accessibilityIdentifier("new-playlist")
                }
            }
        }
        .alert(PlaylistCopy.newPlaylistTitle, isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                Task {
                    do { try await model.createPlaylist(named: newName, songIds: []) } catch {
                        createError = PlaylistEditError.message(for: error)
                    }
                }
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't make the playlist", isPresented: Binding(get: { createError != nil },
                                                                 set: { if !$0 { createError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(createError ?? "")
        }
        .magpieScreen()
        // Round 28 O3 (D340): and offline or back online, and offline when what's on the phone changes.
        .task(id: "\(model.libraryEdits.playlistsRevision)|\(model.offlinePageKey)") {
            // Once per change, not each time the list comes back into view (M1).
            let key = "\(model.libraryEdits.playlistsRevision)|\(model.offlinePageKey)"
            guard loadedRevision != key || playlists.value == nil else { return }
            loadedRevision = key
            await load()
        }
    }

    /// All / Yours (D179): text in each segment, read by VoiceOver as "Show playlists", 44 pt high at least.
    private var showPicker: some View {
        Picker("Show playlists", selection: $show) {
            ForEach(PlaylistShow.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: Tokens.minHitSize)
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.s)
        .background(.bar)   // the rows scroll under it
        .accessibilityIdentifier("playlist-show")
    }

    /// What `show` lists of `all` (Yours: Save to playlist's owner rule, D101).
    private func listed(_ all: [Playlist]) -> [Playlist] {
        AppModel.shown(all, show, user: model.session?.username ?? "", isDiscover: model.isDiscoverPlaylist)
    }

    /// Round 28 O3 fix round 1 (review I3): offline too, every row's long press and swipes queue its songs on the phone.
    private func row(_ playlist: Playlist) -> some View {
        NavigationLink(value: Route.playlist(id: playlist.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(playlist.coverArtId, side: 56) { SleeveArt(image: $0, side: 56) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).font(.body)
                    // Round 24 (D223): who made it, in All only; nothing for your own or an unknown owner.
                    if show == .all { OwnerCaption(owner: playlist.owner, signedInUser: model.session?.username) }
                    HStack(spacing: 4) {
                        Text(playlist.songCount == 1 ? "1 song" : "\(playlist.songCount) songs")
                            .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        DownloadMarkView(model.downloadIndex.mark(playlistId: playlist.id))   // P1
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        .collectionMenu(.playlist(playlist.id), coverArtId: playlist.coverArtId)   // R12, P4
        .collectionSwipeActions(.playlist(playlist.id), in: .list)   // R12
        .listRowBackground(Color.clear)
        .id(playlist.id)
    }

    private func load() async {
        do {
            // A–Z for the letter index (P2); Discover's are under Discover (Y6). Round 28 O3 (D340): offline, the
            // playlists on the phone (downloaded, and recorded per Q3; Discover's kept out, D185).
            let sorted: [Playlist]
            if model.isOffline {
                sorted = await OfflineLists.playlists(model)
                phoneEmpty = await OfflineLists.phoneEmpty(model)
            } else {
                sorted = try await model.libraryPlaylists()
            }
            sections = LetterIndex.sections(listed(sorted), name: \.name)
            playlists = .loaded(sorted)
        } catch {
            if playlists.value == nil { playlists = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }
}

/// Round 28 O3 (owner, 2026-11-15, item 1: "In offline mode, only downloaded songs are visible within albums, artists,
/// songs, etc."; D340): what Library's lists show offline, read from the phone's catalogue (O2), never the server.
enum OfflineLists {
    /// Playlists: the downloaded ones and (Q3) the recorded ones holding a download, A–Z; flows and Discover's shared
    /// playlists stay out (D185: Discover lists them).
    static func playlists(_ model: AppModel) async -> [Playlist] {
        await model.offlineCatalog.playlists(includingRecorded: true)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The albums on the phone, A–Z.
    static func albums(_ model: AppModel) async -> [Album] { await model.offlineCatalog.albums() }

    /// The downloaded songs, A–Z by title (cached songs never, per Q2).
    static func songs(_ model: AppModel) async -> [Song] { await model.offlineCatalog.songs() }

    /// The artists on the phone; with "Album artists only" (R11) those with an album on the phone they are the album
    /// artist of (worked out off the main actor).
    static func artists(_ model: AppModel, albumArtistsOnly: Bool) async -> [Artist] {
        let catalog = await model.offlineCatalog
        let all = catalog.artists()
        guard albumArtistsOnly else { return all }
        return await Task.detached { all.filter { catalog.artistPage(id: $0.id)?.albums.isEmpty == false } }.value
    }

    /// Fix round 1 (design H3): nothing at all downloaded.
    static func phoneEmpty(_ model: AppModel) async -> Bool { await model.offlineCatalog.songs().isEmpty }

    /// Fix round 1 (design H3): the lists that can be empty with songs on the phone.
    enum Kind { case playlists, flows, albumArtists }

    /// What an empty offline list says: "Nothing downloaded yet" only when nothing is; otherwise what this list lacks.
    static func empty(_ kind: Kind, phoneEmpty: Bool) -> (title: String, detail: String?) {
        if phoneEmpty { return (OfflinePageCopy.nothingDownloaded, OfflinePageCopy.nothingDownloadedDetail) }
        switch kind {
        case .playlists: return ("No playlists on this phone", "Download a playlist and it plays here without a connection.")
        case .flows: return ("No flows on this phone", nil)
        case .albumArtists: return ("No album artists on this phone. Turn off Album artists only to see everyone.", nil)
        }
    }
}

/// Round 28 O3 (D340): Library › Albums offline: the albums on the phone as the same lettered grid (A–Z bar, headers past
/// 25, D225), each opening its phone page; nothing on the phone says "Nothing downloaded yet".
struct OfflineAlbumsList: View {
    @Environment(AppModel.self) private var model
    @State private var albums: [Album]?
    @State private var search: SearchModel?
    @State private var sections: [LetterIndex.Section] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let albums, !albums.isEmpty {
                    AlbumLetterGrid(albums: albums, sections: sections, proxy: proxy)
                        .padding(.vertical, Tokens.Spacing.l)
                }
            }
            .letterIndex(available: Set(sections.map(\.key)), hidden: sections.isEmpty) { letter in
                guard let target = LetterIndex.target(letter, in: sections), let albums,
                      albums.indices.contains(target.range.lowerBound) else { return }
                proxy.scrollToLetter(index: target.range.lowerBound, sections: sections, itemCount: albums.count) {
                    albums[$0].id
                }
            }
        }
        .overlay {
            if albums == nil { ProgressView() } else if albums?.isEmpty == true { NothingDownloadedView() }
        }
        // Fix round 1 (design M6): "Search albums" offline too (it searches the phone, KindSearchField).
        .kindSearch(.albums, search, available: albums?.isEmpty == false)
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task { if search == nil { search = model.kindSearchModel(.albums) } }
        .task(id: model.offlinePageKey) {
            let read = await OfflineLists.albums(model)
            sections = LetterIndex.sections(read, name: \.name)
            albums = read
        }
    }
}

/// Round 28 O3 (D340): Library › Songs offline: the downloaded songs A–Z with the A–Z bar and pinned headers (D225); a
/// row plays the list from that song; Remove download asks first. Nothing on the phone says "Nothing downloaded yet".
struct OfflineSongsList: View {
    @Environment(AppModel.self) private var model
    @State private var songs: [Song]?
    @State private var sections: [LetterIndex.Section] = []
    @State private var removing: Song?
    @State private var search: SearchModel?
    private let themed = Themed()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let songs, !songs.isEmpty {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        LetterSectionedRows(items: Array(songs.enumerated()), sections: sections, id: \.element.id,
                                            pinned: true) { index, song in
                            row(song, index: index, in: songs).id(song.id)
                            Divider().overlay(themed.palette.sepColor).padding(.leading, 76)
                        }
                    }
                }
            }
            .letterIndex(available: Set(sections.map(\.key)), hidden: sections.isEmpty) { letter in
                guard let target = LetterIndex.target(letter, in: sections), let songs,
                      songs.indices.contains(target.range.lowerBound) else { return }
                proxy.scrollToLetter(index: target.range.lowerBound, sections: sections, itemCount: songs.count) {
                    songs[$0].id
                }
            }
        }
        .overlay {
            if songs == nil { ProgressView() } else if songs?.isEmpty == true { NothingDownloadedView() }
        }
        // Fix round 1 (design M6): "Search songs" offline too (it searches the phone, KindSearchField).
        .kindSearch(.songs, search, available: songs?.isEmpty == false)
        .task { if search == nil { search = model.kindSearchModel(.songs) } }
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .songRemovalDialog($removing)
        .task(id: model.offlinePageKey) {
            let read = await OfflineLists.songs(model)
            sections = LetterIndex.sections(read, name: \.title)
            songs = read
        }
    }

    private func row(_ song: Song, index: Int, in songs: [Song]) -> some View {
        Button { model.play(songs, startAt: index) } label: {
            Artwork(song.coverArtId, side: 48) { SongRow(song: song, state: .library, artwork: $0) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("offline-song-\(index)")
        .contextMenu {
            SongQueueMenuItems(song: song)
            SongDownloadMenuItem(song: song, removing: $removing)
        }
        .songSwipeActions(song, in: .stack,
                          destructive: RowDestructiveAction(title: SongDownloadMenuItem.removeTitle, symbol: "trash") {
                              removing = song
                          })
    }
}
