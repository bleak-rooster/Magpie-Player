import DesignSystem
import MagpieCore
import Requests
import Search
import SwiftUI

/// Search tab: type to search. Recent searches when the field is empty; otherwise the library's Top
/// result, Songs, Artists and Albums, then a "Not in your library" band (D4: library first). Offline (Task 14) it
/// searches what's on the phone instead: "Downloads", then "Recently played on this phone".
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SearchModel?
    @State private var scope = SearchScope.all
    /// The tab's stack (R10 pushes onto it); a stack of its own where there is no tab bar (tests).
    @Environment(TabNavigator.self) private var navigator: TabNavigator?
    @State private var ownPath = NavigationPath()

    var body: some View {
        NavigationStack(path: Binding(get: { navigator?.search ?? ownPath },
                                      set: { if let navigator { navigator.search = $0 } else { ownPath = $0 } })) {
            Group {
                if let model {
                    SearchContent(model: model, scope: scope, depth: navigator?.search.count ?? ownPath.count)
                } else {
                    Color.clear
                }
            }
            .magpieRoutes()
        }
        // On the stack itself, which is where a Search-role tab looks for its field.
        .searchable(text: Binding(get: { model?.query ?? "" }, set: { model?.update(query: $0) }),
                    placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists and albums")
        .searchScopes($scope) {
            ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .onSubmit(of: .search) { if let model { RecentSearches().add(model.query) } }
        .task {
            guard model == nil else { return }
            let app = app
            model = SearchModel(search: { q, early in
                                    if await app.isOffline { return await OfflineSearch(catalog: app.offlineCatalog).sections(q) }
                                    return try await app.mergedSearch().runReportingLibraryFailure(q, libraryFirst: early)
                                },
                                // Round 12 (Y1): the next batch of a section, at its end.
                                more: { kind, paging in try await app.mergedSearch().more(kind, paging: paging) },
                                errorMessage: BrowseErrorCopy.message(for:))
            model?.outsideArt = app.makeOutsideArt()   // R15
        }
        // R15: search closed; outside artwork goes with it (fetched again next time).
        .onDisappear { model?.outsideArt?.reset() }
        // The same query again from the other source when offline mode changes.
        .onChange(of: app.isOffline) { if let model { model.update(query: model.query) } }
    }
}

private enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All", songs = "Songs", artists = "Artists", albums = "Albums"
    var id: String { rawValue }
}

private struct SearchContent: View {
    @Environment(AppModel.self) private var app
    let model: SearchModel
    let scope: SearchScope
    /// How deep the tab's stack is: a row that opens a page remembers the search (R19: no gesture on the rows, which
    /// took their taps).
    let depth: Int
    @State private var recents = RecentSearches().items
    @State private var trying: TryTarget?
    @State private var removing: Song?
    private let themed = Themed()

    var body: some View {
        let sections = model.results
        List {
            if app.isOffline {
                OfflineNotice().listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            switch model.phase {
            case .idle:
                recentSection
            case .searching where sections.isEmpty:
                ProgressView().frame(maxWidth: .infinity, minHeight: 160).listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't search", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { model.update(query: model.query) }
                }
                .listRowBackground(Color.clear)
            case .done where sections.isEmpty:
                ContentUnavailableView(app.isOffline ? "Nothing on this phone for \u{201C}\(model.query)\u{201D}"
                                                     : "Nothing in your library for \u{201C}\(model.query)\u{201D}",
                                       systemImage: "magnifyingglass",
                                       description: Text("Check the spelling, or try an artist or album."))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("search-empty")
            default:
                if app.isOffline { offlineResults(sections) } else { results(sections) }
            }
        }
        .listStyle(.plain)
        .listRowSeparatorTint(themed.palette.sepColor)
        .navigationTitle("Search")
        .magpieScreen()
        .scrollDismissesKeyboard(.interactively)
        // Fix round 1 (I1): a load-more needs the user's own scroll. The list always bounces, so a pull at the end of
        // a short list counts too.
        .scrollBounceBehavior(.always, axes: .vertical)
        .onScrollPhaseChange { _, phase in if phase == .interacting { model.userScrolled() } }
        .sheet(item: $trying) { TrySheet(target: $0) }
        .songRemovalDialog($removing)
        .onChange(of: depth) { old, new in if new > old, !model.query.isEmpty { remember(model.query) } }
    }

    // MARK: - Start

    @ViewBuilder private var recentSection: some View {
        if recents.isEmpty {
            ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                   description: Text("Find songs, artists and albums by name, in your library and beyond."))
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(recents, id: \.self) { q in
                    Button { model.update(query: q) } label: {
                        Label(q, systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            } header: {
                HStack {
                    Text("Recent").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Clear") {
                        RecentSearches().clear()
                        recents = []
                    }
                    .font(.subheadline)
                    .accessibilityLabel("Clear recent searches")
                }
                .textCase(nil)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder private func results(_ sections: SearchSections) -> some View {
        if scope == .all, let top = sections.top {
            Section {
                header("Top result")
                topRow(top, in: sections)
            }
        }
        if scope == .all || scope == .songs, !sections.songs.isEmpty {
            Section {
                header("Songs")
                ForEach(Array(sections.songs.enumerated()), id: \.element.id) { index, song in
                    songRow(song, index: index, in: sections.songs)
                }
                moreFooter(.songs, in: sections, count: sections.songs.count)
            }
        }
        if scope == .all || scope == .artists, !sections.artists.isEmpty {
            Section {
                header("Artists")
                ForEach(Array(sections.artists.enumerated()), id: \.element.id) { i, a in
                    artistRow(a).accessibilityIdentifier("search-artist-\(i)")
                }
                moreFooter(.artists, in: sections, count: sections.artists.count)
            }
        }
        if scope == .all || scope == .albums, !sections.albums.isEmpty {
            Section {
                header("Albums")
                ForEach(Array(sections.albums.enumerated()), id: \.element.id) { i, a in
                    albumRow(a).accessibilityIdentifier("search-album-\(i)")
                }
                moreFooter(.albums, in: sections, count: sections.albums.count)
            }
        }
        notYetBand(sections.notYet)
    }

    /// Round 12 (Y1, plan item 3): the end of a library section. While it has more, a spinner that loads the next
    /// batch when the user scrolls it into view (one batch per scroll; never on its own); "No more results" once a
    /// batch comes back short (in All, only after something more loaded, so a short list doesn't end every section
    /// with it).
    @ViewBuilder private func moreFooter(_ kind: LibraryKind, in sections: SearchSections, count: Int) -> some View {
        if sections.paging != nil, model.phase == .done {
            if sections.hasMore(kind) {
                if model.moreState(kind) == .failed {
                    Button { model.loadMore(kind) } label: {
                        Label("Couldn't load more. Try again", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(themed.palette.ink2Color)
                    .accessibilityIdentifier("search-more-\(kind.rawValue)")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                        .accessibilityLabel("Loading more")
                        .accessibilityIdentifier("search-more-\(kind.rawValue)")
                        // Fix round 1 (I1): loads only when the user scrolled it into view (SearchModel.footerAppeared).
                        .onAppear { model.footerAppeared(kind) }
                        .onDisappear { model.footerDisappeared(kind) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if scope != .all || sections.loadedMore(kind) {
                Label("No more results", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(themed.palette.ink2Color)
                    .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("search-end-\(kind.rawValue)")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    // MARK: - Offline

    /// What's on the phone (Task 14): the downloads under one heading, by kind, then the cached songs that played.
    @ViewBuilder private func offlineResults(_ sections: SearchSections) -> some View {
        let songs = scope == .all || scope == .songs ? sections.songs : []
        let artists = scope == .all || scope == .artists ? sections.artists : []
        let albums = scope == .all || scope == .albums ? sections.albums : []
        let kinds = [songs.isEmpty, artists.isEmpty, albums.isEmpty].filter { !$0 }.count
        if kinds > 0 {
            Section {
                header("Downloads")
                if !songs.isEmpty {
                    if kinds > 1 { subheader("Songs") }
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        songRow(song, index: index, in: songs)
                    }
                }
                if !artists.isEmpty {
                    if kinds > 1 { subheader("Artists") }
                    ForEach(artists, id: \.id) { artistRow($0) }
                }
                if !albums.isEmpty {
                    if kinds > 1 { subheader("Albums") }
                    ForEach(albums, id: \.id) { albumRow($0) }
                }
            }
        }
        let recent = scope == .all || scope == .songs ? sections.recentlyPlayed : []
        if !recent.isEmpty {
            Section {
                header("Recently played on this phone")
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, song in
                    songRow(song, index: index, in: recent, id: "search-recent-\(index)")
                }
            }
        }
    }

    // MARK: - Not in your library

    /// Below every library row, never interleaved (D4). Each row says "Not in your library" in text
    /// with a symbol, not by its round art alone (D3).
    @ViewBuilder private func notYetBand(_ band: NotYetSections) -> some View {
        let songs = scope == .all || scope == .songs ? band.songs : []
        let artists = scope == .all || scope == .artists ? band.artists : []
        let albums = scope == .all || scope == .albums ? band.albums : []
        let kinds = [songs.isEmpty, artists.isEmpty, albums.isEmpty].filter { !$0 }.count
        if kinds > 0 {
            Section {
                header("Not in your library").accessibilityIdentifier("search-notyet-header")
                if !songs.isEmpty {
                    if kinds > 1 { subheader("Songs") }
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, recording in
                        notYetSongRow(recording, index: index)
                    }
                }
                if !artists.isEmpty {
                    if kinds > 1 { subheader("Artists") }
                    ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                        notYetArtistRow(artist).accessibilityIdentifier("search-notyet-artist-\(index)")
                    }
                }
                if !albums.isEmpty {
                    if kinds > 1 { subheader("Albums") }
                    ForEach(Array(albums.enumerated()), id: \.offset) { index, album in
                        notYetAlbumRow(album).accessibilityIdentifier("search-notyet-album-\(index)")
                    }
                }
            }
        }
    }

    private func subheader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(themed.palette.ink2Color)
            .accessibilityAddTraits(.isHeader)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// R17: a song already asked for opens its request (or, once Ready, is the library song, in place).
    private func notYetSongRow(_ recording: ExternalRecording, index: Int) -> some View {
        let song = Song(id: "notyet-\(index)", title: recording.title, artist: recording.artist,
                        album: recording.releaseTitle ?? "", duration: recording.duration ?? 0)
        return NotYetSongLink(recording: recording, play: { song in
            remember(model.query)
            app.play([song], startAt: 0)
        }) {
            // R15: the release's cover from outside, never cached.
            OutsideArtwork(model.outsideArt, key: .cover(releaseGroup: nil, release: recording.releaseMBID)) { art in
                SongRow(song: song, state: RequestCopy.rowState(for: recording, in: app.requests), artwork: art,
                        tryTitle: RequestCopy.tryTitle(app.tryAvailability),
                        onTry: { trying = TryTarget(recording: recording) })
            }
        }
            .accessibilityIdentifier("search-notyet-song-\(index)")
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }

    @ViewBuilder private func notYetArtistRow(_ artist: NotYetArtist) -> some View {
        if let request = RequestLinks.request(artist: artist.mbid, in: app.requests) {   // R17
            RequestedItemRow(title: artist.name, detail: "Artist", request: request).listRowBackground(Color.clear)
        } else if artist.mbid != nil {
            // R19: opens the outside artist page.
            NavigationLink(value: Route.outsideArtist(artist)) { plainNotYetArtistRow(artist) }
                .listRowBackground(Color.clear)
        } else {
            plainNotYetArtistRow(artist)
        }
    }

    @ViewBuilder private func notYetAlbumRow(_ album: NotYetAlbum) -> some View {
        if let request = RequestLinks.request(releaseGroup: album.mbid, in: app.requests) {   // R17
            RequestedItemRow(title: album.title,
                             detail: [album.kind ?? "Album", album.artist].joined(separator: " \u{00B7} "), request: request)
                .listRowBackground(Color.clear)
        } else if album.mbid != nil {
            // R19: opens the outside album page.
            NavigationLink(value: Route.outsideAlbum(album)) { plainNotYetAlbumRow(album) }
                .listRowBackground(Color.clear)
        } else {
            plainNotYetAlbumRow(album)
        }
    }

    private func plainNotYetArtistRow(_ artist: NotYetArtist) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            // A plain circle: the groove ring is invisible at this size (review of D3). R15: the artist's picture from
            // Lidarr's lookup when there is one, never cached.
            OutsideArtwork(model.outsideArt, key: artist.mbid.map(OutsideArtKey.artist)) { art in
                Circle().fill(themed.palette.surfaceColor).frame(width: 48, height: 48)
                    .overlay {
                        if let art {
                            art.resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.fill").foregroundStyle(themed.palette.ink2Color)
                        }
                    }
                    .clipShape(Circle())
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(artist.name).font(.body)
                StatusLine(.notYet)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(artist.name), artist")
        .accessibilityValue(RowState.notYet.voiceOverValue ?? "")
        .listRowBackground(Color.clear)
    }

    private func plainNotYetAlbumRow(_ album: NotYetAlbum) -> some View {
        OutsideArtwork(model.outsideArt, key: album.mbid.map(OutsideArtKey.releaseGroup)) { art in   // R15
            NotYetAlbumRow(title: album.title, detail: [album.kind ?? "Album", album.artist].joined(separator: " \u{00B7} "),
                           label: "\(album.title), \(album.kind ?? "Album") by \(album.artist)", artwork: art)
        }
        .listRowBackground(Color.clear)
    }

    /// A section's title as its first row, not a List header: plain-list headers pin while scrolling and slid
    /// over the status bar under the search field (H3 I1).
    private func header(_ title: String) -> some View {
        Text(title).magpieDisplay(.title3).foregroundStyle(themed.palette.inkColor)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, Tokens.Spacing.m)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder private func topRow(_ item: SearchItem, in sections: SearchSections) -> some View {
        switch item {
        case .song(let song):
            songRow(song, index: sections.songs.firstIndex(of: song) ?? 0, in: sections.songs, id: "search-top")
        case .artist(let artist):
            artistRow(artist).accessibilityIdentifier("search-top")
        case .album(let album):
            albumRow(album).accessibilityIdentifier("search-top")
        }
    }

    private func songRow(_ song: Song, index: Int, in songs: [Song], id: String? = nil) -> some View {
        Button {
            remember(model.query)
            app.play(songs, startAt: index)
        } label: {
            Artwork(song.coverArtId, side: 48) { SongRow(song: song, state: .library, artwork: $0) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id ?? "search-song-\(index)")
        .contextMenu {
            SongQueueMenuItems(song: song)
            FindsLibraryMenuItem(songId: song.id, artist: song.artist, host: FindsLibraryMenuItem.main)   // R18/R20: Keep
            SongDownloadMenuItem(song: song, removing: $removing)
        }
        .songSwipeActions(song, in: .list)   // R12
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private func artistRow(_ artist: Artist) -> some View {
        NavigationLink(value: Route.artist(id: artist.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(artist.coverArtId, side: 48) { SleeveArt(image: $0, side: 48).clipShape(Circle()) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(artist.name).font(.body)
                    HStack(spacing: 4) {
                        // A song's own artist (Y1, plan item 1.3) comes without an album count: just "Artist".
                        Text(artist.albumCount == 0 ? "Artist"
                             : artist.albumCount == 1 ? "Artist \u{00B7} 1 album" : "Artist \u{00B7} \(artist.albumCount) albums")
                            .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        DownloadMarkView(app.downloadIndex.listMark(artist: artist))   // P1
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        .artistMenu(artist)   // R12, R7 Favourite, P4 Reload artwork
        .collectionSwipeActions(.artist(artist.id), in: .list)   // R12
        .listRowBackground(Color.clear)
    }

    private func albumRow(_ album: Album) -> some View {
        NavigationLink(value: Route.album(id: album.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(album.coverArtId, side: 48) { SleeveArt(image: $0, side: 48) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.name).font(.body).lineLimit(2)
                    HStack(spacing: 4) {
                        Text(["Album", album.artist].joined(separator: " \u{00B7} "))
                            .font(.footnote).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                        DownloadMarkView(app.downloadIndex.mark(album: album))   // P1
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        .albumMenu(album)   // R12, R7 Favourite, R8 Add to playlist…, P4 Reload artwork
        .collectionSwipeActions(.album(album.id), in: .list)   // R12
        .listRowBackground(Color.clear)
    }

    private func remember(_ query: String) {
        RecentSearches().add(query)
        recents = RecentSearches().items
    }
}

/// The not-yet song a Try sheet is open for.
struct TryTarget: Identifiable {
    let id = UUID()
    let recording: ExternalRecording
    /// R19 "Try this album": the album, and its release group as the target (`recording` is its first track).
    var album: NotYetAlbum? = nil
    var albumGroup: MBID? = nil
    /// R19: a track of an outside album: a live request for that album is this Try (R20).
    var releaseGroup: MBID? = nil
}
