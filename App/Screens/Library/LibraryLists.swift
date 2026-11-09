import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// All artists, A–Z in Navidrome's order (its default articles dropped: "The Midnight Cartographers" under M), with
/// the A–Z bar (P2; round 11 R2: the custom bar, so the letter bubble shows here too). Round 11 R11: album artists
/// only, or every artist, from the toolbar's filter menu (the same preference as Settings › Library).
/// Round 24 (owner, 2026-11-08): a "Search artists" field at the top (D224), and a header per letter past 25 artists
/// (D225).
struct ArtistsListView: View {
    @Environment(AppModel.self) private var model
    @State private var artists: Loadable<[Artist]> = .loading
    @State private var sections: [LetterIndex.Section] = []
    /// The "Album artists only" value the list was read for: coming back to the list doesn't read it again (M1).
    @State private var loadedFor: Bool?
    /// Round 24 (D224): the list's own search, artists only.
    @State private var search: SearchModel?
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
        // Again when "Album artists only" changes (here or in Settings).
        .task(id: albumArtistsOnly) {
            guard loadedFor != albumArtistsOnly || artists.value == nil else { return }
            loadedFor = albumArtistsOnly
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
            let sorted = Self.sorted(try await model.libraryArtists())
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
struct AlbumsListView: View {
    @Environment(AppModel.self) private var model
    @State private var list: PagedLetterList<Album>?
    /// The running letter jump (its seek reads the server), cancelled when the screen goes.
    @State private var jumpTask: Task<Void, Never>?
    /// Round 24 (D224): the list's own search, albums only.
    @State private var search: SearchModel?

    var body: some View {
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
    @Environment(\.letterIndexShown) private var barShown
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 350

    private var columns: Int { AlbumGrid.columnCount(width: width, accessibility: typeSize.isAccessibilitySize) }
    private var tileWidth: CGFloat { max(100, (width - CGFloat(columns - 1) * Tokens.Spacing.l) / CGFloat(columns)) }

    var body: some View {
        let runs = LetterSectionHeader.runs(sections, itemCount: albums.count, barShown: barShown)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: Tokens.Spacing.l, alignment: .top),
                                 count: columns),
                  alignment: .leading, spacing: Tokens.Spacing.xl, pinnedViews: [.sectionHeaders]) {
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
                AlbumTileView(album: album, subtitle: album.artist, width: tileWidth)
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
struct PlaylistsListView: View {
    @Environment(AppModel.self) private var model
    /// Every playlist but Discover's, A–Z; `show` picks what is listed from it.
    @State private var playlists: Loadable<[Playlist]> = .loading
    @State private var show: PlaylistShow = .all
    @State private var sections: [LetterIndex.Section] = []
    @State private var naming = false
    @State private var newName = ""
    @State private var createError: String?
    /// The playlists revision the list was read for (M1).
    @State private var loadedRevision: Int?
    private let themed = Themed()

    var body: some View {
        ScrollViewReader { proxy in
            List {
                LoadableView(state: playlists, retry: load) { playlists in
                    let shown = listed(playlists)
                    LetterSectionedRows(items: shown, sections: sections, id: \.id) { playlist in row(playlist) }
                    // Round 24 (D223): what All is: everything this account may see (Navidrome's own rule).
                    if let footer = show.footer, !shown.isEmpty {
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
        .overlay {
            if let all = playlists.value, listed(all).isEmpty {
                ContentUnavailableView(show.emptyTitle, systemImage: "music.note.list")
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""
                    naming = true
                } label: {
                    Image(systemName: "plus").frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                }
                .accessibilityLabel("New playlist")
                .disabled(model.isOffline)
                .accessibilityIdentifier("new-playlist")
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
        .task(id: model.libraryEdits.playlistsRevision) {
            // Once per change, not each time the list comes back into view (M1).
            guard loadedRevision != model.libraryEdits.playlistsRevision || playlists.value == nil else { return }
            loadedRevision = model.libraryEdits.playlistsRevision
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
            // A–Z for the letter index (P2); Discover's are under Discover (Y6).
            let sorted = try await model.libraryPlaylists()
            sections = LetterIndex.sections(listed(sorted), name: \.name)
            playlists = .loaded(sorted)
        } catch {
            if playlists.value == nil { playlists = .failed(BrowseErrorCopy.message(for: error)) }
        }
    }
}
