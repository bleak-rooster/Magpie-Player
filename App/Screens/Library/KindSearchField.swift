import DesignSystem
import MagpieCore
import NavidromeKit
import Playback
import Search
import SwiftUI

/// Round 24 (owner, 2026-11-08): Library › Artists, Albums and Songs each have a search field at the top that searches
/// only that kind (owner item 4; D224). Search's own machinery, nothing new on the wire: `search3` asking for that
/// kind alone (the other counts 0), Search's batches and load-more (`LibraryPager`, `SearchPageSize`), its pause before
/// asking and its stale-answer rules (`SearchModel`), and offline the offline catalogue's own filter (`OfflineCatalog`,
/// as `OfflineSearch`). Library only: nothing from outside the library.
enum KindSearchKind: String, Sendable {
    case artists, albums, songs

    var libraryKind: LibraryKind {
        switch self {
        case .artists: .artists
        case .albums: .albums
        case .songs: .songs
        }
    }

    var placeholder: String { "Search \(rawValue)" }

    /// A search that found nothing ("No songs match “x”.").
    func emptyTitle(_ query: String) -> String { "No \(rawValue) match \u{201C}\(query)\u{201D}." }
}

enum KindSearch {
    /// `query` asking for `kind` only: the other kinds' counts and offsets 0.
    static func only(_ query: LibraryQuery, _ kind: LibraryKind) -> LibraryQuery {
        var q = LibraryQuery(text: query.text, songCount: 0, albumCount: 0, artistCount: 0)
        switch kind {
        case .songs: q.songCount = query.songCount; q.songOffset = query.songOffset
        case .albums: q.albumCount = query.albumCount; q.albumOffset = query.albumOffset
        case .artists: q.artistCount = query.artistCount; q.artistOffset = query.artistOffset
        }
        return q
    }

    /// The rows of one kind, ranked as Search ranks them, without a Top result (the list is one kind).
    static func sections(_ found: LibrarySearchResult, query: String, kind: LibraryKind,
                         paging: SearchPaging?) -> SearchSections {
        let ranked = SearchSections.library(found, query: query)
        var out = SearchSections(paging: paging)
        switch kind {
        case .songs: out.songs = ranked.songs
        case .albums: out.albums = ranked.albums
        case .artists: out.artists = ranked.artists
        }
        return out
    }

    /// Offline: the catalogue's own filter (title, artist or album for songs; name or artist for albums; name for
    /// artists), that kind only. Nothing is asked of the server; no batches (it's all on the phone).
    static func offline(_ query: String, kind: LibraryKind, catalog: OfflineCatalog) -> SearchSections {
        sections(catalog.search(query), query: query, kind: kind, paging: nil)
    }

    /// The results are on screen (a query is on), not the letter list: the A–Z bar and the letter headers are hidden,
    /// and the letter list waits underneath, where it was, for the query to be cleared.
    @MainActor static func showsResults(_ search: SearchModel) -> Bool { search.phase != .idle }
}

extension AppModel {
    /// A kind's own search (D224): `SearchModel` over Search's library pager, asking `search3` for that kind only.
    /// - Parameter sleep: Search's pause before asking (tests pass one that doesn't wait).
    func kindSearchModel(_ kind: KindSearchKind,
                         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
        -> SearchModel {
        let libraryKind = kind.libraryKind
        let pager = LibraryPager(pageSize: SearchPageSize.override(appDefaults)) { [weak self] q in
            let asked = KindSearch.only(q, libraryKind)
            // A split asks no artists, so an artists search has nothing to ask of it.
            guard asked.songCount > 0 || asked.albumCount > 0 || asked.artistCount > 0 else { return LibrarySearchResult() }
            guard let self else { throw NavidromeError.noReachableServer }
            return try await self.request {
                try await $0.search(asked.text, songCount: asked.songCount, albumCount: asked.albumCount,
                                    artistCount: asked.artistCount, songOffset: asked.songOffset,
                                    albumOffset: asked.albumOffset, artistOffset: asked.artistOffset)
            }
        }
        return SearchModel(
            search: { [weak self] q, _ in
                guard let self else { throw NavidromeError.noReachableServer }
                if await self.isOffline {
                    return KindSearch.offline(q, kind: libraryKind, catalog: await self.offlineCatalog)
                }
                let (found, paging) = try await pager.first(q, deadline: MergedSearch.libraryTimeout)
                return KindSearch.sections(found, query: q, kind: libraryKind, paging: paging)
            },
            more: { kind, paging in try await pager.more(kind, paging: paging) },
            sleep: sleep,
            errorMessage: BrowseErrorCopy.message(for:))
    }
}

/// The field at the top of a kind's list: a magnifying glass, the field ("Search songs"), and a clear button once
/// there's text. 44 pt high; over a bar, so rows scroll under it as under Playlists' All / Yours.
struct KindSearchField: View {
    let kind: KindSearchKind
    let search: SearchModel
    @FocusState private var focused: Bool
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(p.ink2Color)
                .accessibilityHidden(true)
            TextField(kind.placeholder, text: Binding(get: { search.query }, set: { search.update(query: $0) }))
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel(kind.placeholder)
                .accessibilityIdentifier("kind-search-\(kind.rawValue)")
            if !search.query.isEmpty {
                Button {
                    search.update(query: "")
                    focused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(p.ink2Color)
                        .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("kind-search-clear")
            }
        }
        .padding(.leading, Tokens.Spacing.m)
        .frame(minHeight: Tokens.minHitSize)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Tokens.Spacing.m))
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.s)
        .background(.bar)   // the rows scroll under it
    }
}

/// A kind's search results, in Search's ranked order (not the library's A–Z, so no letter bar or headers): the rows,
/// Search's load-more at the end (one batch per scroll, D-Y1), and what an empty or failed search says.
struct KindSearchResults: View {
    @Environment(AppModel.self) private var model
    let kind: KindSearchKind
    let search: SearchModel
    @State private var removing: Song?
    private let themed = Themed()

    var body: some View {
        let sections = search.results
        List {
            switch search.phase {
            case .idle:
                EmptyView()
            case .searching where isEmpty(sections):
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't search", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { search.update(query: search.query) }
                }
                .listRowBackground(Color.clear)
            case .done where isEmpty(sections):
                ContentUnavailableView(kind.emptyTitle(search.query), systemImage: "magnifyingglass")
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("kind-search-empty")
            default:
                rows(sections)
                footer(sections)
            }
        }
        .listStyle(.plain)
        .listRowSeparatorTint(themed.palette.sepColor)
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.always, axes: .vertical)
        .onScrollPhaseChange { _, phase in if phase == .interacting { search.userScrolled() } }
        .songRemovalDialog($removing)
    }

    private func isEmpty(_ sections: SearchSections) -> Bool {
        switch kind {
        case .songs: sections.songs.isEmpty
        case .albums: sections.albums.isEmpty
        case .artists: sections.artists.isEmpty
        }
    }

    @ViewBuilder private func rows(_ sections: SearchSections) -> some View {
        switch kind {
        case .songs:
            ForEach(Array(sections.songs.enumerated()), id: \.element.id) { index, song in
                Button { model.play(sections.songs, startAt: index) } label: {
                    Artwork(song.coverArtId, side: 48) { SongRow(song: song, state: .library, artwork: $0) }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("kind-result-song-\(index)")
                .contextMenu { SongQueueMenuItems(song: song); SongDownloadMenuItem(song: song, removing: $removing) }
                .songSwipeActions(song, in: .list)   // R12
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        case .artists:
            ForEach(Array(sections.artists.enumerated()), id: \.element.id) { index, artist in
                NavigationLink(value: Route.artist(id: artist.id)) {
                    HStack(spacing: Tokens.Spacing.m) {
                        Artwork(artist.coverArtId, side: 44) { SleeveArt(image: $0, side: 44).clipShape(Circle()) }
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
                .artistMenu(artist)
                .collectionSwipeActions(.artist(artist.id), in: .list)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("kind-result-artist-\(index)")
            }
        case .albums:
            ForEach(Array(sections.albums.enumerated()), id: \.element.id) { index, album in
                NavigationLink(value: Route.album(id: album.id)) {
                    HStack(spacing: Tokens.Spacing.m) {
                        Artwork(album.coverArtId, side: 56) { SleeveArt(image: $0, side: 56) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(album.name).font(.body).lineLimit(2)
                            HStack(spacing: 4) {
                                Text(album.artist).font(.footnote).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                                DownloadMarkView(model.downloadIndex.mark(album: album))   // P1
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .albumMenu(album)
                .collectionSwipeActions(.album(album.id), in: .list)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("kind-result-album-\(index)")
            }
        }
    }

    /// Search's section end (round 12, Y1): a spinner that loads the next batch once the user scrolls it into view,
    /// "Couldn't load more. Try again" after a failure, "No more results" once a batch after the first came back short.
    @ViewBuilder private func footer(_ sections: SearchSections) -> some View {
        let lk = kind.libraryKind
        if sections.paging != nil, search.phase == .done {
            if sections.hasMore(lk) {
                if search.moreState(lk) == .failed {
                    Button { search.loadMore(lk) } label: {
                        Label("Couldn't load more. Try again", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(themed.palette.ink2Color)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                        .accessibilityLabel("Loading more")
                        .onAppear { search.footerAppeared(lk) }
                        .onDisappear { search.footerDisappeared(lk) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if sections.loadedMore(lk) {
                Label("No more results", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(themed.palette.ink2Color)
                    .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                    .accessibilityElement(children: .combine)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }
}

extension View {
    /// A kind's list with its search field on top (D224): while a query is on, the results cover the letter list,
    /// which stays underneath untouched (hidden from touch and VoiceOver), so clearing the query shows it again at the
    /// same place. `search` is nil until the screen has made it.
    func kindSearch(_ kind: KindSearchKind, _ search: SearchModel?) -> some View {
        modifier(KindSearchOverlay(kind: kind, search: search))
    }
}

private struct KindSearchOverlay: ViewModifier {
    @Environment(AppModel.self) private var model
    let kind: KindSearchKind
    let search: SearchModel?

    func body(content: Content) -> some View {
        let searching = search.map(KindSearch.showsResults) ?? false
        ZStack {
            content
                .opacity(searching ? 0 : 1)
                .allowsHitTesting(!searching)
                .accessibilityHidden(searching)
            if searching, let search { KindSearchResults(kind: kind, search: search) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let search { KindSearchField(kind: kind, search: search) }
        }
        // The same query again from the other source when offline mode changes (as Search does).
        .onChange(of: model.isOffline) { if let search, !search.query.isEmpty { search.update(query: search.query) } }
    }
}
