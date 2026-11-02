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
    /// R3: Popular, from this account's saved list at once, then the server's when it differs.
    @State private var popular: PopularSongs?
    @State private var notYetAlbums: [NotYetAlbum] = []
    @State private var gathering = false
    @State private var playError: String?
    /// P3: where the artist stands in Lidarr (no line without Lidarr).
    @State private var lidarrLine: ArtistLidarrModel?
    /// R4: the artist download (its ⋯ items, confirmation and status line share it).
    @State private var artistDownload = ArtistDownloadState()
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
        // Y3 (item 4): the page again, its saved Popular and cover colours forgotten, after a quick scan.
        .refreshable {
            await model.refreshPage(artistId: artistId, coverArtIds: [page.value?.artist.coverArtId]) {
                popular = nil   // the saved list is gone: read the server's afresh
                await load()
            }
        }
        .navigationTitle(page.value?.artist.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // R7 (the UX appraisal's header): Favourite and ⋯ in the toolbar, not more capsules.
            // R4: the download's items are in the same ⋯; offline it stays for "Remove download" only.
            if let page = page.value {
                let artist = page.artist
                let online = !model.isOffline && !OfflineCatalog.isLocalId(artist.id)
                if online || model.downloads?.artistStatus(artist.id) ?? .none != .none {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if online { FavouriteButton(target: .artist(artist.id)) }
                        PageMoreMenu(coverArtId: artist.coverArtId, identifier: "artist-more") {
                            ArtistDownloadMenuItems(state: artistDownload, artist: artist,
                                                    albums: page.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) })
                        }
                    }
                }
            }
        }
        .background { ArtBackdrop(coverArtId: page.value?.artist.coverArtId) }   // R13: tinted by the artist's art
        .magpieScreen()
        .immersiveArt(coverArtId: page.value?.artist.coverArtId)
        .findsKeepFlow(host: keepHost)
        // Again when offline mode changes, and offline when songs land on or leave the phone (the store may be
        // unreadable before first unlock): the downloaded albums offline, the server's online.
        .task(id: model.offlinePageKey) {
            if page.value == nil || loadedOffline != model.isOffline || model.isOffline { await load() }
        }
    }

    /// R18: this page runs the Keeps its Keep <artist> asks for.
    private var keepHost: String { "artist-\(artistId)" }

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
                    .artistDownload(artistDownload, artist: page.artist)   // R4: its confirmation and status line
                // R18 + R20: an artist only in your Finds offers Keep <artist> as the page's one capsule; the Lidarr
                // status line stays visible (R20).
                let onlyInFinds = model.isOnlyInFinds(albums: page.albums)
                if let lidarrLine, let presentation = lidarrLine.presentation {
                    ArtistLidarrLine(line: lidarrLine, presentation: presentation, showsAction: !onlyInFinds)
                }
                if onlyInFinds {
                    OnlyInFindsLine(artist: page.artist.name, albums: page.albums, host: keepHost)
                }
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

            if let topSongs = popular?.songs, !topSongs.isEmpty {
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
                        .contextMenu { SongQueueMenuItems(song: song); SongLibraryMenuItems(song: song) }   // R12, R7, R8
                        .songSwipeActions(song, in: .stack)   // R12
                    }
                }
                .transaction { $0.animation = nil }   // R3: a refreshed list swaps in place, no animation storm
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
                Text("Open one to try it, or a song from it.").font(.footnote).foregroundStyle(p.ink2Color)
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                ForEach(Array(notYetAlbums.enumerated()), id: \.offset) { index, album in
                    let kind = album.kind ?? "Album"
                    let row = NotYetAlbumRow(title: album.title,
                                             detail: [kind, album.year.map(String.init)].compactMap { $0 }.joined(separator: " \u{00B7} "),
                                             label: [album.title, kind, album.year.map(String.init)].compactMap { $0 }.joined(separator: ", "))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if album.mbid != nil {   // R19: its outside page (Try this album, the tracklist)
                            NavigationLink(value: Route.outsideAlbum(album)) { row.contentShape(Rectangle()) }.buttonStyle(.plain)
                        } else {
                            row
                        }
                    }
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
            popular = nil
            notYetAlbums = []
            guard let artist = catalog.artists().first(where: { $0.id == artistId }) else {
                page = .failed(OfflineCopy.notOnPhone)
                return
            }
            page = .loaded(Page(artist: artist, albums: catalog.albums(byArtist: artistId)))
            lidarrLine = ArtistLidarrModel(model: model, name: artist.name, mbid: artist.mbid)   // "You're offline"
            return
        }
        // R3: the saved Popular is ready the moment the page is, without waiting for the server's top songs.
        if popular?.artistId != artistId { popular = model.popularSongs(artistId: artistId) }
        do {
            let (artist, albums) = try await model.request { [artistId] in try await $0.artist(id: artistId) }
            page = .loaded(Page(artist: artist, albums: albums))
            model.noteAlbumSongCounts(albums)   // P1: backfills downloads saved without the album's count
            model.noteFavourite(.artist(artist.id), artist.starred)   // R7
            let name = artist.name
            // Both fill in after the page; neither waits for the other.
            async let top: Void = loadTopSongs(name)
            async let notYet: Void = loadNotYetAlbums(artist, library: albums)
            async let inLidarr: Void = loadLidarrLine(artist)
            _ = await (top, notYet, inLidarr)
        } catch {
            page = .failed(BrowseErrorCopy.message(for: error))
        }
    }

    private func loadTopSongs(_ name: String) async {
        if let popular { await model.refreshPopular(popular, artistName: name) }
    }

    private func loadLidarrLine(_ artist: Artist) async {
        let line = lidarrLine.flatMap { $0.name == artist.name ? $0 : nil }
            ?? ArtistLidarrModel(model: model, name: artist.name, mbid: artist.mbid)
        lidarrLine = line
        await line.refresh()
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
