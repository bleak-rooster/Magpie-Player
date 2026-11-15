import DesignSystem
import MagpieCore
import Playback
import Search
import SwiftUI

/// Artist: name, Play / Shuffle (every album), Popular (hidden when the server has no top songs, A13), Albums, then
/// "Not in your library" (Task 7.1c: the artist's other albums, from Lidarr when connected; information only, filled
/// in after the page and left out when there are none or they can't be read).
/// Round 28 O3 (owner, 2026-11-15, item 1; D341): offline, the phone's page (O2's `artistPage`, for an album-artist or a
/// track-artist id): the albums with a song on the phone where they are the album artist, then "Songs on this phone"
/// (songs where they are only the track artist); Top songs per D268, Play top songs per D304, Automix hidden (D305), the
/// Lidarr line "You're offline"; Play and Shuffle play what's on the phone. Online, a read records the page (O2) and a
/// failed read shows the phone's copy with `PhoneCopyNote`.
struct ArtistView: View {
    @Environment(AppModel.self) private var model
    let artistId: String
    @State private var page: Loadable<Page> = .loading
    /// Whether what is shown came from the phone (offline) or the server; a change of offline mode loads again.
    @State private var loadedOffline: Bool?
    /// R3: Popular, from this account's saved list at once, then the server's when it differs.
    @State private var popular: PopularSongs?
    /// Round 14 A3: Top songs from the server or ListenBrainz (Settings › Home & Library › Artist top songs).
    @State private var outsideTop: TopSongsResult?
    /// Round 26 K2 (D263, D264): Top songs for an artist Lidarr has: the saved list at once, then the refreshed one.
    @State private var lidarrTop: LidarrTopSongsModel?
    /// A pull to refresh is under way: the Top songs refresh whatever the two-minute gap says (D264).
    @State private var pulling = false
    @State private var notYetAlbums: [NotYetAlbum] = []
    @State private var gathering = false
    @State private var playError: String?
    /// P3: where the artist stands in Lidarr (no line without Lidarr).
    @State private var lidarrLine: ArtistLidarrModel?
    /// R4: the artist download (its ⋯ items, confirmation and status line share it).
    @State private var artistDownload = ArtistDownloadState()
    @State private var monitoring = ArtistMonitoringState()   // Round 24 (D237, D242): Change what's monitored, Clean up
    /// Round 27 A (D305): the Automix sheet, seeded by this artist.
    @State private var automix: AutomixSeed?
    private let themed = Themed()

    struct Page {
        var artist: Artist
        var albums: [Album]
        /// Round 28 O3 (D341): on the phone's page, the songs where they are only the track artist.
        var songs: [Song] = []
        /// Round 28 O3 (D341): where the page came from.
        var source: PageSource = .server
    }

    var body: some View {
        ScrollView {
            LoadableView(state: page, retry: load) { page in
                content(page)
            }
        }
        // Y3 (item 4): the page again, its saved Popular and cover colours forgotten, after a quick scan.
        // Round 13 Z2: in a task of its own, and a load cut short never shows an error (RefreshSafety).
        .refreshable {
            await RefreshSafety.run {
                pulling = true
                defer { pulling = false }
                await model.refreshPage(artistId: artistId, coverArtIds: [page.value?.artist.coverArtId]) {
                    popular = nil   // the saved list is gone: read the server's afresh
                    await load()
                }
            }
        }
        .navigationTitle(page.value?.artist.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // R7 (the UX appraisal's header): Favourite and ⋯ in the toolbar, not more capsules.
            // R4: the download's items are in the same ⋯; offline it stays for "Remove download" only.
            if let page = page.value {
                let artist = page.artist
                // Round 28 O3 (D341): the phone's copy of a failed read is no server page either.
                let online = !model.isOffline && !OfflineCatalog.isLocalId(artist.id) && page.source == .server
                if online || model.downloads?.artistStatus(artist.id) ?? .none != .none {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if online { FavouriteButton(target: .artist(artist.id)) }
                        PageMoreMenu(coverArtId: artist.coverArtId, identifier: "artist-more") {
                            ArtistDownloadMenuItems(state: artistDownload, artist: artist,
                                                    albums: page.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) })
                            ArtistMonitoringMenuItems(state: monitoring, line: lidarrLine)   // Round 24
                        }
                    }
                }
            }
        }
        .background { ArtBackdrop(coverArtId: page.value?.artist.coverArtId) }   // R13: tinted by the artist's art
        .magpieScreen()
        .immersiveArt(coverArtId: page.value?.artist.coverArtId)
        .findsKeepFlow(host: keepHost)
        .artistMonitoring(monitoring, line: lidarrLine)   // Round 24 (D237, D242)
        .sheet(item: $automix) { AutomixSheet(seed: $0) }   // Round 27 A (D305)
        // Again when offline mode changes, and offline when songs land on or leave the phone (the store may be
        // unreadable before first unlock): the downloaded albums offline, the server's online.
        .task(id: model.offlinePageKey) {
            if page.value == nil || loadedOffline != model.isOffline || model.isOffline { await load() }
        }
    }

    /// R18: this page runs the Keeps its Keep <artist> asks for.
    private var keepHost: String { "artist-\(artistId)" }

    /// The art, name, download mark and Lidarr / Finds lines, above the action bar.
    @ViewBuilder private func header(_ page: Page) -> some View {
        let p = themed.palette
        VStack(spacing: Tokens.Spacing.m) {
            Artwork(page.artist.coverArtId, side: 180) { image in
                SleeveArt(image: image, placeholder: p.surfaceColor, side: 180)
                    .overlay { if image == nil { ArtistMonogram(name: page.artist.name) } }
                    .clipShape(Circle())
            }
            .reloadArtworkMenu(page.source == .server ? page.artist.coverArtId : nil)
            Text(page.artist.name).magpieDisplay(.largeTitle).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            // Fix round 1 (design H1): on the phone's page everything shown is here; no mark to say so again.
            DownloadMarkLine(page.source.isPhone ? .none : model.downloadIndex.mark(artistId: page.artist.id, albums: page.albums))
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
        }
    }

    private func content(_ page: Page) -> some View {
        let p = themed.palette
        let albums = page.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        // Round 28 O3 (D341): the phone's page plays what's on the phone, its albums then its other songs.
        let phoneSongs = page.source.isPhone ? Self.phoneSongs(page) : []
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
            if page.source == .phoneCopy { PhoneCopyNote(retry: load) }
            VStack(spacing: Tokens.Spacing.m) {
                header(page).padding(.horizontal, Tokens.Spacing.margin)
                // Y7: the same ActionBar as Album and Playlist, keeping its own margins.
                ActionBar(pairsBeforeStacking: true) {   // fix round 1 (design M4): two and one before stacking
                    PlayShuffleActions(playTitle: gathering ? "Loading…" : "Play",
                                       disabled: (page.source.isPhone ? phoneSongs.isEmpty : albums.isEmpty) || gathering) {
                        if page.source.isPhone { Self.play(page, model: model, shuffled: false) } else { Task { await playAll(albums, shuffled: false) } }
                    } shuffle: {
                        if page.source.isPhone { Self.play(page, model: model, shuffled: true) } else { Task { await playAll(albums, shuffled: true) } }
                    }
                    // Round 27 A (owner item 17, D305): Automix beside Play and Shuffle, seeded by the artist.
                    if page.source == .server, model.automixAvailable(artistId: page.artist.id, albums: page.albums) {
                        ActionButton(AutomixCopy.actionBar, symbol: AutomixCopy.symbol) {
                            automix = AutomixSeed(.artist(id: page.artist.id, name: page.artist.name,
                                                          top: model.topSongsPlayable(topSongsRequest(page.artist).known),
                                                          albums: albums))
                        }
                        .accessibilityHint(AutomixCopy.artistHint)   // fix round 1 (design L2)
                        .accessibilityIdentifier("artist-automix")
                    }
                }
                if let playError {
                    Label(playError, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(p.ink2Color)
                        .padding(.horizontal, Tokens.Spacing.margin)
                        .accessibilityIdentifier("artist-play-error")
                }
            }
            .frame(maxWidth: .infinity)

            // Round 26 K2 (D263; fix round 1, design H2): for an artist Lidarr has, "Top songs" in the library row view
            // throughout (never "Popular" first); the ordinary list once Lidarr says it's theirs; without Lidarr, as before.
            // Round 27 A (D304): each with Play top songs under its heading when one of its songs is in the library.
            switch lidarrTop?.display(fallback: popular?.songs ?? []) ?? .ordinary {
            case .lidarr(let songs): LidarrTopSongsSection(songs: songs, playTopSongs: playTopSongsAction(page.artist))
            case .ordinary: ordinaryTopSongs(page.artist)
            case .nothing: EmptyView()
            }

            if !albums.isEmpty || page.source == .server {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    Text("Albums").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    AlbumGrid(albums: albums) { $0.year.map(String.init) ?? "" }
                }
            }

            if !page.songs.isEmpty { songsOnThisPhone(page.songs) }   // round 28 O3 (D341)

            if !notYetAlbums.isEmpty { notYetSection }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    /// The ordinary Top songs: D104's chosen source, or Popular when only the library can answer.
    @ViewBuilder private func ordinaryTopSongs(_ artist: Artist) -> some View {
        if let outsideTop {   // round 14 A3: Top songs from the chosen source (owner answer 6)
            TopSongsSection(result: outsideTop, playTopSongs: playTopSongsAction(artist))
        } else if let topSongs = popular?.songs, !topSongs.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Text("Popular").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Tokens.Spacing.margin)
                if let play = playTopSongsAction(artist) {   // Round 27 A (D304)
                    PlayTopSongsButton(action: play).padding(.horizontal, Tokens.Spacing.margin)
                }
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
    }

    /// Round 27 A (D304, D303): what Play top songs starts with, from what the page shows: an artist Lidarr has, their
    /// list of up to fifteen (nothing filled behind it); while it's read, Popular's songs; otherwise the shown D104 rows'
    /// library songs, or Popular's.
    private func topSongsRequest(_ artist: Artist) -> TopSongsPlayRequest {
        var request = TopSongsPlayRequest(name: artist.name, mbid: artist.mbid, known: [], complete: false, provider: nil)
        switch lidarrTop?.display(fallback: popular?.songs ?? []) ?? .ordinary {
        case .lidarr:
            if let lidarrTop, !lidarrTop.playable.isEmpty {
                request.known = lidarrTop.playable
                request.complete = lidarrTop.isWholeList   // fix round 1 (review M8)
            } else {
                request.known = popular?.songs ?? []
            }
        case .ordinary:
            if let outsideTop {
                request.known = outsideTop.rows.compactMap(\.library)
                request.provider = outsideTop.provider
            } else {
                request.known = popular?.songs ?? []
            }
        case .nothing:
            break
        }
        return request
    }

    /// Play top songs for the page, or nil when none of its top songs is a library song (no button).
    private func playTopSongsAction(_ artist: Artist) -> (() -> Void)? {
        let request = topSongsRequest(artist)
        guard !model.topSongsPlayable(request.known).isEmpty else { return nil }
        return { Task { await model.playTopSongs(request) } }
    }

    /// Round 28 O3 (D341): what Play and Shuffle start on the phone's page: its albums' songs on the phone (newest album
    /// first, as the grid), then the songs where they are only the track artist. Nothing is asked of the server.
    static func phoneSongs(_ page: Page) -> [Song] {
        page.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }.flatMap { $0.songs ?? [] } + page.songs
    }

    /// Round 28 O3 (D341; fix round 1, review M3): the phone's page's Play and Shuffle: what's on the phone, at once,
    /// with nothing asked of the server.
    static func play(_ page: Page, model: AppModel, shuffled: Bool) {
        let songs = phoneSongs(page)
        guard !songs.isEmpty else { return }
        shuffled ? model.shuffle(songs) : model.play(songs, startAt: 0)
    }

    /// Round 28 O3 (D341): "Also on this phone" (fix round 1, design M8): the artist's songs on albums that aren't theirs
    /// (a featured song, a compilation track), each playing from the phone; their menu only queues (no server items).
    private func songsOnThisPhone(_ songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(OfflinePageCopy.songsOnThisPhone).magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                Button { model.play(songs, startAt: index) } label: {
                    Artwork(song.coverArtId, side: 48) { image in
                        SongRow(song: song, state: .library, artwork: image)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("artist-phone-song-\(index)")
                .contextMenu { SongQueueMenuItems(song: song) }
                .songSwipeActions(song, in: .stack)
            }
        }
        .accessibilityIdentifier("artist-songs-on-phone")
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
        // R3: the saved Popular is ready the moment the page is, without waiting for the server's top songs.
        if !model.isOffline, !OfflineCatalog.isLocalId(artistId), popular?.artistId != artistId {
            popular = model.popularSongs(artistId: artistId)
        }
        var loaded: Page?
        await Self.load(model, artistId: artistId, onScreen: page.value?.source) { outcome in
            switch outcome {
            case .shown(let new):
                page = .loaded(new)
                loaded = new
            case .notOnPhone:
                page = .failed(OfflineCopy.notOnPhone)
            case .failed(let error):
                page = page.failing(error, noticeTo: model)   // Round 13 Z2: never for a load cut short; the page shown stays
            }
        }
        guard let loaded else { return }
        let artist = loaded.artist
        if loaded.source.isPhone {
            // Offline (Task 14), the phone's copy (round 28 O3), or an artist the catalog grouped itself.
            popular = nil
            outsideTop = nil   // Round 26 K2 (D268): offline, Top songs are only saved songs on the phone
            notYetAlbums = []
            lidarrTop = await model.lidarrTopSongs(name: artist.name, mbid: artist.mbid, artistId: artist.id)
            lidarrLine = ArtistLidarrModel(model: model, name: artist.name, mbid: artist.mbid)   // "You're offline"
            return
        }
        // Round 26 K2 (D263): the saved Top songs of an artist Lidarr has, ready with the page (kept on a reload, so a
        // pull never clears it first).
        if model.lidarr == nil || lidarrTop?.key != LidarrTopSongsCache.key(mbid: artist.mbid, artistId: artist.id)
            || lidarrTop?.offline != false {
            lidarrTop = await model.lidarrTopSongs(name: artist.name, mbid: artist.mbid, artistId: artist.id)
        }
        // Both fill in after the page; neither waits for the other.
        async let top: Void = loadTopSongsAndLidarrLine(artist)
        async let notYet: Void = loadNotYetAlbums(artist, library: loaded.albums)
        _ = await (top, notYet)
    }

    /// Round 28 O3 (D341): what one load of the page gives.
    enum Outcome {
        case shown(Page)
        /// Offline (or an artist the phone grouped itself) with nothing of theirs on the phone.
        case notOnPhone
        case failed(any Error)
    }

    /// Round 28 O3 (D341): one load of the artist page, handed to `show`, then (online) recorded for the phone. Offline
    /// (Task 14), or an artist the catalog grouped itself: the phone's page (O2's `artistPage`). Online: the server's; a
    /// failed read (but one cut short, D77) shows the phone's copy when it has one. The record goes into the downloads
    /// captured **before** the read (O2, security M3).
    static func load(_ model: AppModel, artistId: String, onScreen: PageSource? = nil, show: (Outcome) -> Void) async {
        if model.isOffline || OfflineCatalog.isLocalId(artistId) {
            show(await phonePage(model, artistId: artistId, source: .phone).map(Outcome.shown) ?? .notOnPhone)
            return
        }
        let target = model.downloads
        do {
            let (artist, read) = try await model.request { [artistId] in try await $0.artist(id: artistId) }
            let albums = model.hidingFlowDuplicates(read)   // Y6: not Aurral's copy of what the library has
            show(.shown(Page(artist: artist, albums: albums)))
            model.noteAlbumSongCounts(albums)   // P1: backfills downloads saved without the album's count
            model.noteFavourite(.artist(artist.id), artist.starred)   // R7
            await model.recordArtistPage(artist, albums: albums, into: target)   // round 28 O3 (O2's D333)
        } catch {
            if PageSource.fallsBack(after: error, onScreen: onScreen),
               let copy = await phonePage(model, artistId: artistId, source: .phoneCopy) {
                show(.shown(copy))
            } else {
                show(.failed(error))
            }
        }
    }

    /// Round 28 O3 (D341): the phone's page for an album-artist or a track-artist id.
    private static func phonePage(_ model: AppModel, artistId: String, source: PageSource) async -> Page? {
        guard let page = await model.offlineCatalog.artistPage(id: artistId) else { return nil }
        return Page(artist: page.artist, albums: page.albums, songs: page.songs, source: source)
    }

    private func loadTopSongs(_ name: String, mbid: MBID?) async {
        // Round 14 A3 (D104): only the library to ask (the setup or the setting): Popular as before. Otherwise the
        // chosen source with its fallback; the library's answer still goes through Popular (its saved list).
        guard model.topSongsProviders(mbid: mbid) != [.library] else {
            outsideTop = nil
            if let popular { await model.refreshPopular(popular, artistName: name) }
            return
        }
        let result = await model.artistTopSongs(name: name, mbid: mbid)
        guard !Task.isCancelled else { return }
        if let result, result.provider != .library {
            outsideTop = result
        } else {
            outsideTop = nil
            if let popular, let result { await popular.refresh { result.rows.compactMap(\.library) } }
        }
    }

    /// Round 26 K2 (D257, D264): without Lidarr, the Top songs and the Lidarr line load side by side as before. With it,
    /// the ordinary Top songs are read at once too (fix round 1, design H3: nothing waits for Lidarr), and the line's
    /// answer (waited for at most 10 s) decides which list shows: an artist Lidarr has gets their list refreshed; any
    /// other, or no list, the ordinary one.
    private func loadTopSongsAndLidarrLine(_ artist: Artist) async {
        guard let lidarrTop else {
            async let top: Void = loadTopSongs(artist.name, mbid: artist.mbid)
            async let inLidarr: Void = loadLidarrLine(artist)
            _ = await (top, inLidarr)
            return
        }
        await lidarrTop.load(fresh: pulling, lidarr: {
            await loadLidarrLine(artist)
            return lidarrLine?.state.map(LidarrTopSongsModel.LidarrAnswer.answered) ?? .unread
        }, ordinary: {
            await loadTopSongs(artist.name, mbid: artist.mbid)
        })
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
            // B1 fix round (D120): answers by album id, never by position.
            let byId = try await KeyedGather.values(ids) { id in try await client.album(id: id).songs ?? [] }
            return ids.flatMap { byId[$0] ?? [] }
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
