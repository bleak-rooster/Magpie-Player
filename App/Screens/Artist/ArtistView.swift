import DesignSystem
import MagpieCore
import Playback
import Search
import SwiftUI

/// Artist: name, Play / Shuffle (every album), Popular (hidden when the server has no top songs, A13), Albums, then
/// "Not in your library" (Task 7.1c: the artist's other albums, from Lidarr when connected; information only, filled
/// in after the page and left out when there are none or they can't be read).
struct ArtistView: View {
    @Environment(AppModel.self) private var model
    let artistId: String
    @State private var page: Loadable<Page> = .loading
    /// Whether what is shown came from the phone (offline) or the server; a change of offline mode loads again.
    @State private var loadedOffline: Bool?
    @State private var topSongs: [Song] = []
    @State private var notYetAlbums: [NotYetAlbum] = []
    @State private var gathering = false
    @State private var playError: String?
    private let themed = Themed()

    struct Page {
        var artist: Artist
        var albums: [Album]
    }

    var body: some View {
        ScrollView {
            LoadableView(state: page, retry: load) { page in
                content(page)
            }
        }
        .navigationTitle(page.value?.artist.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        // Again when offline mode changes, and offline when songs land on or leave the phone (the store may be
        // unreadable before first unlock): the downloaded albums offline, the server's online.
        .task(id: model.offlinePageKey) {
            if page.value == nil || loadedOffline != model.isOffline || model.isOffline { await load() }
        }
    }

    private func content(_ page: Page) -> some View {
        let p = themed.palette
        let albums = page.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
            VStack(spacing: Tokens.Spacing.m) {
                Artwork(page.artist.coverArtId, side: 180) { image in
                    SleeveArt(image: image, placeholder: p.surfaceColor, side: 180)
                        .overlay { if image == nil { ArtistMonogram(name: page.artist.name) } }
                        .clipShape(Circle())
                }
                .reloadArtworkMenu(page.artist.coverArtId)
                Text(page.artist.name).magpieDisplay(.largeTitle).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                DownloadMarkLine(model.downloadIndex.mark(artistId: page.artist.id, albums: page.albums))
                CapsuleRow {
                    CapsuleButton(gathering ? "Loading…" : "Play", symbol: "play.fill") {
                        Task { await playAll(albums, shuffled: false) }
                    }
                    .frame(maxWidth: .infinity)
                    CapsuleButton("Shuffle", symbol: "shuffle") { Task { await playAll(albums, shuffled: true) } }
                        .frame(maxWidth: .infinity)
                }
                .disabled(albums.isEmpty || gathering)
                if let playError {
                    Label(playError, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(p.ink2Color)
                        .accessibilityIdentifier("artist-play-error")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Spacing.margin)

            if !topSongs.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    Text("Popular").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, Tokens.Spacing.margin)
                    ForEach(Array(topSongs.prefix(5).enumerated()), id: \.offset) { index, song in
                        Button { model.play(Array(topSongs.prefix(5)), startAt: index) } label: {
                            Artwork(song.coverArtId, side: 48) { image in
                                SongRow(song: song, state: .library, artwork: image)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                Text("Albums").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                AlbumGrid(albums: albums) { $0.year.map(String.init) ?? "" }
            }

            if !notYetAlbums.isEmpty { notYetSection }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    private var notYetSection: some View {
        let p = themed.palette
        return VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text("Not in your library").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                Text("To try one, search for a song from it.").font(.footnote).foregroundStyle(p.ink2Color)
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                ForEach(Array(notYetAlbums.enumerated()), id: \.offset) { index, album in
                    let kind = album.kind ?? "Album"
                    NotYetAlbumRow(title: album.title,
                                   detail: [kind, album.year.map(String.init)].compactMap { $0 }.joined(separator: " \u{00B7} "),
                                   label: [album.title, kind, album.year.map(String.init)].compactMap { $0 }.joined(separator: ", "))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("artist-notyet-album-\(index)")
                }
            }
            .padding(.horizontal, Tokens.Spacing.margin)
        }
        .accessibilityIdentifier("artist-notyet")
    }

    private func load() async {
        loadedOffline = model.isOffline
        // Offline (Task 14), or an artist the catalog grouped itself: their downloaded albums, from the phone.
        if model.isOffline || OfflineCatalog.isLocalId(artistId) {
            let catalog = await model.offlineCatalog
            topSongs = []
            notYetAlbums = []
            guard let artist = catalog.artists().first(where: { $0.id == artistId }) else {
                page = .failed(OfflineCopy.notOnPhone)
                return
            }
            page = .loaded(Page(artist: artist, albums: catalog.albums(byArtist: artistId)))
            return
        }
        do {
            let (artist, albums) = try await model.request { [artistId] in try await $0.artist(id: artistId) }
            page = .loaded(Page(artist: artist, albums: albums))
            model.noteAlbumSongCounts(albums)   // P1: backfills downloads saved without the album's count
            let name = artist.name
            // Both fill in after the page; neither waits for the other.
            async let popular: Void = loadTopSongs(name)
            async let notYet: Void = loadNotYetAlbums(artist, library: albums)
            _ = await (popular, notYet)
        } catch {
            page = .failed(BrowseErrorCopy.message(for: error))
        }
    }

    private func loadTopSongs(_ name: String) async {
        topSongs = (try? await model.request { try await $0.topSongs(artistName: name) }) ?? []
    }

    private func loadNotYetAlbums(_ artist: Artist, library: [Album]) async {
        notYetAlbums = await model.artistNotYetAlbums(artist, library: library)
    }

    /// Fetches every album's tracks (in parallel), then plays them in album order.
    private func playAll(_ albums: [Album], shuffled: Bool) async {
        gathering = true
        playError = nil
        defer { gathering = false }
        let ids = albums.map(\.id)
        let songs: [Song]
        do {
            songs = try await model.request({ client in
            try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
                for (i, id) in ids.enumerated() {
                    group.addTask { (i, try await client.album(id: id).songs ?? []) }
                }
                var byIndex: [Int: [Song]] = [:]
                for try await (i, songs) in group { byIndex[i] = songs }
                return ids.indices.flatMap { byIndex[$0] ?? [] }
            }
        })
        } catch {
            playError = BrowseErrorCopy.message(for: error)
            AccessibilityNotification.Announcement(playError ?? "").post()
            return
        }
        shuffled ? model.shuffle(songs) : model.play(songs, startAt: 0)
    }
}

/// An artist without a picture: their initials in the display face, or a person symbol when the name has no
/// letters (H3 M2). Decorative; the name is right below.
struct ArtistMonogram: View {
    let name: String
    @Environment(\.magpieTheme) private var theme
    private let themed = Themed()

    var body: some View {
        Group {
            if let initials = Self.initials(name) {
                // A fixed size: it fills a fixed 180 pt circle, and the name below carries Dynamic Type.
                Text(initials).font(.system(size: 64, weight: .semibold, design: theme.usesSerifDisplay ? .serif : .default))
            } else {
                Image(systemName: "person.fill").font(.system(size: 64))
            }
        }
        .foregroundStyle(themed.palette.ink2Color)
        .accessibilityHidden(true)
    }

    /// "The Midnight Cartographers" → "MC": the first letters of the first two words, a leading "The" skipped.
    nonisolated static func initials(_ name: String) -> String? {
        var words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1, words[0].lowercased() == "the" { words.removeFirst() }
        let letters = words.compactMap { $0.first(where: \.isLetter) }.prefix(2)
        return letters.isEmpty ? nil : String(letters).uppercased()
    }
}
