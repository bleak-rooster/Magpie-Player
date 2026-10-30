import DesignSystem
import MagpieCore
import SwiftUI

/// All artists, A–Z.
struct ArtistsListView: View {
    @Environment(AppModel.self) private var model
    @State private var artists: Loadable<[Artist]> = .loading
    private let themed = Themed()

    var body: some View {
        List {
            LoadableView(state: artists, retry: load) { artists in
                ForEach(artists, id: \.id) { artist in
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
                    .reloadArtworkMenu(artist.coverArtId)   // P4
                    .listRowBackground(Color.clear)
                }
            }
            .listRowSeparatorTint(themed.palette.sepColor)
        }
        .listStyle(.plain)
        .navigationTitle("Artists")
        .magpieScreen()
        .task { if artists.value == nil { await load() } }
    }

    private func load() async {
        do {
            artists = .loaded(try await model.request { try await $0.artists() }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        } catch {
            artists = .failed(BrowseErrorCopy.message(for: error))
        }
    }
}

/// All albums, A–Z, a page at a time.
struct AlbumsListView: View {
    @Environment(AppModel.self) private var model
    @State private var albums: Loadable<[Album]> = .loading
    @State private var exhausted = false
    @State private var loadingMore = false
    @State private var moreError: String?
    private static let page = 60

    var body: some View {
        ScrollView {
            LoadableView(state: albums, retry: { await loadFirst() }) { albums in
                AlbumGrid(albums: albums, subtitle: { $0.artist }, onAppearLast: { Task { await loadMore() } })
                    .padding(.vertical, Tokens.Spacing.l)
                if let moreError {
                    VStack(spacing: Tokens.Spacing.s) {
                        Text(moreError).font(.footnote).multilineTextAlignment(.center)
                        Button("Try again") { Task { await loadMore() } }
                            .frame(minHeight: Tokens.minHitSize)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Tokens.Spacing.xxl)
                    .accessibilityIdentifier("albums-more-error")
                } else if loadingMore {
                    ProgressView().padding(.bottom, Tokens.Spacing.xxl)
                }
            }
        }
        .navigationTitle("Albums")
        .magpieScreen()
        .task { if albums.value == nil { await loadFirst() } }
    }

    private func loadFirst() async {
        do {
            let first = try await model.request { try await $0.albumList(.alphabeticalByName, size: Self.page, offset: 0) }
            exhausted = first.count < Self.page
            albums = .loaded(first)
        } catch {
            albums = .failed(BrowseErrorCopy.message(for: error))
        }
    }

    private func loadMore() async {
        guard !exhausted, !loadingMore, let current = albums.value else { return }
        loadingMore = true
        moreError = nil
        defer { loadingMore = false }
        let offset = current.count
        let more: [Album]
        do {
            more = try await model.request { try await $0.albumList(.alphabeticalByName, size: Self.page, offset: offset) }
        } catch {
            moreError = BrowseErrorCopy.message(for: error)
            return
        }
        exhausted = more.count < Self.page
        let known = Set(current.map(\.id))
        albums = .loaded(current + more.filter { !known.contains($0.id) })
    }
}

/// All playlists.
struct PlaylistsListView: View {
    @Environment(AppModel.self) private var model
    @State private var playlists: Loadable<[Playlist]> = .loading
    private let themed = Themed()

    var body: some View {
        List {
            LoadableView(state: playlists, retry: load) { playlists in
                ForEach(playlists, id: \.id) { playlist in
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
                    .reloadArtworkMenu(playlist.coverArtId)   // P4
                    .listRowBackground(Color.clear)
                }
            }
            .listRowSeparatorTint(themed.palette.sepColor)
        }
        .listStyle(.plain)
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
            playlists = .loaded(try await model.request { try await $0.playlists() })
        } catch {
            playlists = .failed(BrowseErrorCopy.message(for: error))
        }
    }
}
