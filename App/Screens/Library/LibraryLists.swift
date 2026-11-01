import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// All artists, A–Z in Navidrome's order (its default articles dropped: "The Midnight Cartographers" under M), with
/// the system's section index (P2).
struct ArtistsListView: View {
    @Environment(AppModel.self) private var model
    @State private var artists: Loadable<[Artist]> = .loading
    private let themed = Themed()

    var body: some View {
        List {
            LoadableView(state: artists, retry: load) { artists in
                ForEach(LetterIndex.sections(artists, ignoringArticles: LetterIndex.navidromeArticles, name: \.name),
                        id: \.range.lowerBound) { section in
                    Section {
                        ForEach(artists[section.range], id: \.id) { artist in
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
                            .collectionMenu(.artist(artist.id), coverArtId: artist.coverArtId)   // R12, P4
                            .collectionSwipeActions(.artist(artist.id), in: .list)   // R12
                            .listRowBackground(Color.clear)
                        }
                    }
                    .sectionIndexLabel(section.isFirstOfKey ? section.key : String?.none)
                }
            }
            .listRowSeparatorTint(themed.palette.sepColor)
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .navigationTitle("Artists")
        .magpieScreen()
        .task { if artists.value == nil { await load() } }
    }

    private func load() async {
        do {
            artists = .loaded(Self.sorted(try await model.request { try await $0.artists() }))
        } catch {
            artists = .failed(BrowseErrorCopy.message(for: error))
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

/// All playlists, A–Z, with the system's section index (P2).
struct PlaylistsListView: View {
    @Environment(AppModel.self) private var model
    @State private var playlists: Loadable<[Playlist]> = .loading
    private let themed = Themed()

    var body: some View {
        List {
            LoadableView(state: playlists, retry: load) { playlists in
                ForEach(LetterIndex.sections(playlists, name: \.name), id: \.range.lowerBound) { section in
                    Section {
                        ForEach(playlists[section.range], id: \.id) { playlist in
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
                        }
                    }
                    .sectionIndexLabel(section.isFirstOfKey ? section.key : String?.none)
                }
            }
            .listRowSeparatorTint(themed.palette.sepColor)
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        // Over the list, not a row in it, so no separators frame it (H3 M8).
        .overlay {
            if playlists.value?.isEmpty == true {
                ContentUnavailableView("No playlists yet", systemImage: "music.note.list")
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)   // as with rows; an empty list would otherwise show a large title
        .magpieScreen()
        .task { if playlists.value == nil { await load() } }
    }

    private func load() async {
        do {
            // A–Z for the letter index (P2).
            playlists = .loaded(try await model.request { try await $0.playlists() }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        } catch {
            playlists = .failed(BrowseErrorCopy.message(for: error))
        }
    }
}
