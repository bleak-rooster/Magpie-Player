import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// Album: sleeve art, title in the display face, artist, year and hallmark, Play / Shuffle, tracks.
/// Round 28 O3 (owner, 2026-11-15, item 1: "an album should still open the album of the downloaded music"; D341):
/// offline, the phone's page (O2's `albumPage`): its header as recorded, only the songs on the phone, and when partial
/// "<n> of <m> songs on this phone"; Favourite, Add to playlist and Reload artwork hide, Remove download stays. Online, a
/// read records the page (O2) and a failed read shows the phone's copy with `PhoneCopyNote`.
struct AlbumView: View {
    @Environment(AppModel.self) private var model
    let albumId: String
    @State private var shown: Loadable<Shown> = .loading
    /// Whether what is shown came from the phone (offline) or the server; a change of offline mode loads again.
    @State private var loadedOffline: Bool?
    private let themed = Themed()

    /// Round 28 O3 (D341): the album as shown, where it came from, and how many of its songs are on the phone.
    struct Shown {
        var album: Album
        var source: PageSource
        var genre: String?
        var onPhone: Int
        var total: Int?
        /// Fix round 1 (review M1): the downloads the page loaded with; a download started here records into these,
        /// never another account's.
        var target: DownloadManager?

        init(album: Album, source: PageSource) {
            self.album = album; self.source = source; genre = nil
            onPhone = album.songs?.count ?? 0; total = nil
        }

        init(_ page: OfflineAlbumPage, source: PageSource) {
            album = page.album; self.source = source; genre = page.genre; onPhone = page.onPhone; total = page.total
        }
    }

    private var album: Album? { shown.value?.album }

    var body: some View {
        ScrollView {
            LoadableView(state: shown, retry: load) { shown in
                content(shown)
            }
        }
        // Y3 (item 4): the album again, its cover colours forgotten, after a quick scan picks up new downloads.
        // Round 13 Z2: in a task of its own, and a load cut short never shows an error (RefreshSafety).
        .refreshable {
            await RefreshSafety.run { await model.refreshPage(coverArtIds: [album?.coverArtId]) { await load() } }
        }
        .navigationTitle(album?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // R7, R8 (the UX appraisal's header): Favourite and ⋯ in the toolbar; Download stays the capsule.
            // Round 28 O3 (D341): not on the phone's page (offline, or the phone's copy of a failed read).
            if let shown = shown.value, Self.showsServerActions(shown.source, offline: model.isOffline, id: shown.album.id) {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    FavouriteButton(target: .album(shown.album.id))
                    AlbumMoreMenu(album: shown.album)
                }
            }
        }
        .background { ArtBackdrop(coverArtId: album?.coverArtId) }
        .magpieScreen()
        .immersiveArt(coverArtId: album?.coverArtId)   // R13
        // Again when offline mode changes, and offline when songs land on or leave the phone (the store may be
        // unreadable before first unlock): the phone's copy offline, the server's online.
        .task(id: model.offlinePageKey) {
            if shown.value == nil || loadedOffline != model.isOffline || model.isOffline { await load() }
        }
        // Round 28 O3 (D341): a download started here (the album, or one of its songs) records the page (O2 parks it
        // until a song lands), so offline it says "<n> of <m>".
        .onChange(of: startedDownload) { _, started in
            guard started, let shown = shown.value else { return }
            Task { await Self.recordStartedDownload(shown, model: model) }
        }
    }

    /// Round 28 O3 (D341; fix round 1, review M1): a download started from the server's page records it into the
    /// downloads the page loaded with (`Shown.target`), so a page left open across a sign-out never writes into the next
    /// account's store.
    static func recordStartedDownload(_ shown: Shown, model: AppModel) async {
        guard shown.source == .server else { return }
        await model.recordAlbumPage(shown.album, songs: shown.album.songs ?? [], into: shown.target)
    }

    /// Round 28 O3: whether a download of this album's songs has started from the page (the album's or one song's).
    private var startedDownload: Bool {
        guard let album, shown.value?.source == .server else { return false }
        return model.downloadStatus((album.songs ?? []).map(\.id)) != .none
    }

    /// Round 28 O3 (D341): Favourite, Add to playlist and Reload artwork need the server: only on the server's page,
    /// online, for an album the server knows.
    static func showsServerActions(_ source: PageSource, offline: Bool, id: String) -> Bool {
        source == .server && !offline && !OfflineCatalog.isLocalId(id)
    }

    /// Round 28 O3 (D341): the Download capsule on the phone's page only once there is a download to remove (Download
    /// itself needs the server).
    static func showsDownload(_ source: PageSource, status: DownloadStatus) -> Bool {
        source == .server || status != .none
    }

    private func content(_ shown: Shown) -> some View {
        let p = themed.palette
        let album = shown.album
        let songs = album.songs ?? []
        return VStack(spacing: Tokens.Spacing.l) {
            if shown.source == .phoneCopy { PhoneCopyNote(retry: load) }
            VStack(spacing: Tokens.Spacing.s) {
                Artwork(album.coverArtId, side: 260) { SleeveArt(image: $0, side: 260) }
                    .reloadArtworkMenu(shown.source == .server ? album.coverArtId : nil)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .padding(.bottom, Tokens.Spacing.s)
                Text(album.name)
                    .magpieDisplay(.title)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let artistId = album.artistId {
                    NavigationLink(value: Route.artist(id: artistId)) {
                        Text(album.artist).font(.title3).foregroundStyle(p.accentInkColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("album-artist")
                } else {
                    Text(album.artist).font(.title3).foregroundStyle(p.ink2Color)
                }
                HStack(spacing: Tokens.Spacing.s) {
                    if let year = album.year { Text(String(year)).font(theme.numberFont(.footnote)) }
                    if let genre = shown.genre { Text(genre).font(.footnote) }   // round 28 O3: recorded (D341)
                    if let quality = Self.quality(of: songs) { Hallmark(quality) }
                }
                .foregroundStyle(p.ink2Color)
                // Fix round 1 (design H1): one answer: the count line where it shows, else the mark.
                if OfflinePageCopy.showsMark(shown.source, onPhone: shown.onPhone, total: shown.total) {
                    DownloadMarkLine(model.downloadIndex.mark(album: album))
                }
                if shown.source.isPhone { OnPhoneCountLine(onPhone: shown.onPhone, total: shown.total) }   // D341
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)

            VStack(spacing: Tokens.Spacing.s) {
                ActionBar {
                    PlayShuffleButtons(songs: songs, recent: .album(album))
                    if Self.showsDownload(shown.source, status: model.downloadStatus(songs.map(\.id), reason: .album(album.id))) {
                        DownloadButton(reason: .album(album.id), songs: songs, coverArtId: album.coverArtId)
                    }
                }
                DownloadNote(reason: .album(album.id), songs: songs)
            }

            TrackList(songs: songs, recent: .album(album),
                      serverMenus: OfflinePageCopy.serverRowMenus(shown.source, offline: model.isOffline))

            if !songs.isEmpty {
                let minutes = DurationText.minutes(album.duration > 0 ? album.duration : songs.reduce(0) { $0 + $1.duration })
                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs"), \(minutes) \(minutes == 1 ? "minute" : "minutes")")
                    .font(theme.numberFont(.footnote))
                    .foregroundStyle(p.ink2Color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Spacing.margin)
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    @Environment(\.magpieTheme) private var theme

    /// The album's hallmark when every track shares one (e.g. all FLAC → Lossless).
    static func quality(of songs: [Song]) -> Quality? {
        let all = Set(songs.map { Quality.from(suffix: $0.suffix, bitRate: $0.bitRate) })
        guard all.count == 1, let q = all.first, q != .standard else { return nil }
        return q
    }

    private func load() async {
        loadedOffline = model.isOffline
        await Self.load(model, albumId: albumId, onScreen: shown.value?.source) { outcome in
            switch outcome {
            case .shown(let new): shown = .loaded(new)
            case .notOnPhone: shown = .failed(OfflineCopy.notOnPhone)
            // Round 13 Z2: never for a load cut short; the album shown stays.
            case .failed(let error): shown = shown.failing(error, noticeTo: model)
            }
        }
    }

    /// Round 28 O3 (D341): what one load of the page gives.
    enum Outcome {
        case shown(Shown)
        /// Offline (or a page the phone grouped itself) with none of its songs on the phone.
        case notOnPhone
        case failed(any Error)
    }

    /// Round 28 O3 (D341): one load of the album page, handed to `show`, then (online) recorded for the phone. Offline
    /// (Task 14), or an album the catalog grouped itself: the phone's page. Online: the server's; a read that got no
    /// answer shows the phone's copy when it has one and nothing from the server is on screen (`onScreen`, fix round 1
    /// I1, I2). The record goes into the downloads captured **before** the read (O2, security M3).
    static func load(_ model: AppModel, albumId: String, onScreen: PageSource? = nil, show: (Outcome) -> Void) async {
        if model.isOffline || OfflineCatalog.isLocalId(albumId) {
            let page = await model.offlineCatalog.albumPage(id: albumId)
            show(page.map { .shown(Shown($0, source: .phone)) } ?? .notOnPhone)
            return
        }
        let target = model.downloads
        do {
            var loaded = try await model.request { [albumId] in try await $0.album(id: albumId) }
            loaded.songs = loaded.songs.map(model.swappingFlowCopies)   // Y6: an Aurral copy plays as the library's
            var server = Shown(album: loaded, source: .server)
            server.target = target   // fix round 1 (review M1)
            show(.shown(server))
            model.noteAlbumSongCounts([loaded])   // P1: backfills downloads saved without the album's count
            model.noteFavourite(.album(loaded.id), loaded.starred)   // R7
            await model.recordAlbumPage(loaded, songs: loaded.songs ?? [], into: target)   // round 28 O3 (O2's D333)
        } catch {
            if PageSource.fallsBack(after: error, onScreen: onScreen),
               let page = await model.offlineCatalog.albumPage(id: albumId) {
                show(.shown(Shown(page, source: .phoneCopy)))
            } else {
                show(.failed(error))
            }
        }
    }
}

/// Play (filled) and Shuffle (tinted): two ActionBar items, so use it inside an `ActionBar` (Y7).
struct PlayShuffleButtons: View {
    @Environment(AppModel.self) private var model
    let songs: [Song]
    /// Round 14 A6: the album, playlist or flow this plays, for Home's quick grid.
    var recent: RecentPlay?

    var body: some View {
        PlayShuffleActions(disabled: songs.isEmpty) {
            model.noteRecentlyPlayed(recent)
            model.play(songs, startAt: 0)
        } shuffle: {
            model.noteRecentlyPlayed(recent)
            model.shuffle(songs)
        }
    }
}

/// Play and Shuffle as ActionBar items, with their identifiers ("play", "shuffle"); `playTitle` lets the artist page
/// say "Loading…" while it gathers songs.
struct PlayShuffleActions: View {
    var playTitle = "Play"
    var disabled = false
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        ActionButton(playTitle, symbol: "play.fill", prominence: .primary, action: play)
            .disabled(disabled)
            .accessibilityIdentifier("play")
        ActionButton("Shuffle", symbol: "shuffle", action: shuffle)
            .disabled(disabled)
            .accessibilityIdentifier("shuffle")
    }
}

/// Numbered tracks with durations; the playing one shows a speaker instead of its number.
/// Disc headings appear when the album has more than one disc.
private struct TrackList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    let songs: [Song]
    /// Round 14 A6: the album, for Home's quick grid.
    var recent: RecentPlay?
    /// Round 28 O3 fix round 1 (design M10): the server's page, online; otherwise row menus like offline.
    var serverMenus = true
    @State private var removing: Song?
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        let discs = Set(songs.compactMap(\.disc))
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                if discs.count > 1, song.disc != nil, index == 0 || songs[index - 1].disc != song.disc {
                    Text("Disc \(song.disc ?? 1)")
                        .font(.footnote.weight(.semibold)).foregroundStyle(p.ink2Color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Spacing.margin).padding(.top, Tokens.Spacing.l)
                        .accessibilityAddTraits(.isHeader)
                }
                row(index, song)
                Divider().overlay(p.sepColor).padding(.leading, 52)
            }
        }
        .songRemovalDialog($removing)
    }

    private func row(_ index: Int, _ song: Song) -> some View {
        let p = themed.palette
        let isCurrent = model.player.queue.current?.song.id == song.id
        let mark: DownloadMark = model.downloadIndex.isDownloaded(song.id) ? .downloaded : .none
        return Button {
            model.noteRecentlyPlayed(recent)
            model.play(songs, startAt: index)
        } label: {
            HStack(spacing: Tokens.Spacing.m) {
                Group {
                    if isCurrent {
                        Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(p.accentInkColor)
                    } else {
                        Text(song.track.map(String.init) ?? "").font(theme.numberFont(.callout))
                            .foregroundStyle(p.ink2Color)
                    }
                }
                .frame(width: 24)
                Text(song.title).font(.body).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DownloadMarkView(mark)
                Text(DurationText.clock(song.duration)).font(theme.numberFont(.footnote))
                    .foregroundStyle(p.ink2Color)
            }
            .padding(.horizontal, Tokens.Spacing.margin)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(song.title)
        .accessibilityValue(mark.joined(to: isCurrent ? "Now playing, \(DurationText.spoken(song.duration))"
                                                      : DurationText.spoken(song.duration)))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("track-\(index)")
        .contextMenu {
            if serverMenus {
                SongQueueMenuItems(song: song)
                FindsLibraryMenuItem(songId: song.id, artist: song.artist, host: FindsLibraryMenuItem.main)   // R18/R20: Keep
                SongDownloadMenuItem(song: song, removing: $removing)
            } else {
                PhoneSongMenuItems(song: song, removing: $removing)   // round 28 O3 fix round 1 (design M10)
            }
        }
        .songSwipeActions(song, in: .stack)   // R12
    }
}
