import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// All artists, A–Z in Navidrome's order (its default articles dropped: "The Midnight Cartographers" under M), with
/// the A–Z bar (P2; round 11 R2: the custom bar, so the letter bubble shows here too). Round 11 R11: album artists
/// only, or every artist, from the toolbar's filter menu (the same preference as Settings › Library).
struct ArtistsListView: View {
    @Environment(AppModel.self) private var model
    @State private var artists: Loadable<[Artist]> = .loading
    @State private var sections: [LetterIndex.Section] = []
    /// The "Album artists only" value the list was read for: coming back to the list doesn't read it again (M1).
    @State private var loadedFor: Bool?
    private let themed = Themed()

    var body: some View {
        let albumArtistsOnly = model.preferences.layout.albumArtistsOnly
        ScrollViewReader { proxy in
            List {
                LoadableView(state: artists, retry: load) { artists in
                    ForEach(artists, id: \.id) { artist in row(artist) }
                }
                .listRowSeparatorTint(themed.palette.sepColor)
            }
            .listStyle(.plain)
            .letterIndex(available: Set(sections.map(\.key)), hidden: sections.isEmpty) { letter in
                guard let target = LetterIndex.target(letter, in: sections), let list = artists.value else { return }
                proxy.scrollTo(list[target.range.lowerBound].id, anchor: .top)
            }
        }
        .navigationTitle("Artists")
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
/// which drops Navidrome's default articles).
struct AlbumsListView: View {
    @Environment(AppModel.self) private var model
    @State private var list: PagedLetterList<Album>?
    /// The running letter jump (its seek reads the server), cancelled when the screen goes.
    @State private var jumpTask: Task<Void, Never>?

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
                        AlbumGrid(albums: albums, subtitle: { $0.artist }, onAppearLast: { Task { await list.loadMore() } })
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
            .onChange(of: list?.scrollRequest) { _, request in
                if let request { proxy.scrollTo(request.id, anchor: .top) }
            }
        }
        .navigationTitle("Albums")
        .magpieScreen()
        .onDisappear { jumpTask?.cancel() }
        .task {
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

/// All playlists, A–Z, with the A–Z bar (P2; round 11 R2: the custom bar, so the letter bubble shows here too).
/// Round 11 R8: "+" makes a new playlist (a name, then `createPlaylist`); the list reads again after any change.
/// Round 22 R22P (owner, 2026-11-06): All or Yours above the list, remembered per account (D179, D180).
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
                    ForEach(listed(playlists), id: \.id) { playlist in row(playlist) }
                }
                .listRowSeparatorTint(themed.palette.sepColor)
            }
            .listStyle(.plain)
            .letterIndex(available: Set(sections.map(\.key)), hidden: sections.isEmpty) { letter in
                guard let target = LetterIndex.target(letter, in: sections), let all = playlists.value else { return }
                proxy.scrollTo(listed(all)[target.range.lowerBound].id, anchor: .top)
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
        AppModel.shown(all, show, user: model.session?.username ?? "")
    }

    private func row(_ playlist: Playlist) -> some View {
        NavigationLink(value: Route.playlist(id: playlist.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(playlist.coverArtId, side: 56) { SleeveArt(image: $0, side: 56) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).font(.body)
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
