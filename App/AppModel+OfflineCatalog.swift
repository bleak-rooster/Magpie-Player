import AurralKit
import Foundation
import MagpieCore
import Playback

/// Round 28 O2 (owner, 2026-11-15): what's on the phone, moved here from `AppModel+Offline.swift` (plan §4).
extension AppModel {
    // MARK: - What's on the phone

    /// What's on the phone now (empty when signed out).
    var offlineCatalog: OfflineCatalog {
        get async {
            guard let store = downloads?.store else { return OfflineCatalog(entries: [], playlists: []) }
            return OfflineCatalog(entries: await store.entries(), playlists: await store.playlists(),
                                  records: await store.records())   // Round 28 O2: pages read online (D331)
        }
    }

    /// Where the cover saved with a download is (one per album or playlist), shown before asking the server. Not
    /// checked here: the caller reads it off the main actor, and a missing file reads as no image.
    func localCoverURL(_ coverArtId: String?) -> URL? {
        guard let coverArtId, let store = downloads?.store else { return nil }
        return store.coverPath(coverArtId: coverArtId)
    }

    /// The lock screen's artwork: offline only a cover saved on the phone (none if it isn't), online the server's.
    func nowPlayingArtworkURL(_ song: Song) -> URL? {
        isOffline ? localCoverURL(song.coverArtId) : coverArtURL(song.coverArtId, size: 600)
    }

    /// What offline pages load again on: the mode, and offline the songs on the phone (the store may only become
    /// readable after first unlock). Round 28 O2: and the records, so a page recorded meanwhile reloads (D331).
    var offlinePageKey: String {
        isOffline ? "offline|\(downloads?.localFiles.count ?? 0)|\(downloads?.recordsRevision ?? 0)" : "online"
    }
}

/// Round 28 O2 (owner, 2026-11-15, item 1: "anything that is downloaded should be cached and only updated when in
/// online mode. This should work for artists, albums, songs, playlists, flows, etc."; Q3, Q4; D331–D336).
///
/// - Records (D331, D333): each page read online (O3 calls these after a successful read, and when a download starts
///   from the page) records what it shows, only when one of its songs is a download, only when it differs, never while
///   offline (automatic or manual; a read that succeeded while only suspect may write). Songs on the page that are
///   downloads get their snapshot refreshed (D332). A download started from a page parks its record until its first
///   song lands.
/// - Flows (D335): offline, round 27's saved Discover file is read (never written) for the flows holding a download.
/// - A downloaded flow keeps in step with its flow when its page is read online (Q4).
/// - Lyrics (D336): what the pane shows for a downloaded song is kept on the phone and read offline.
extension AppModel {
    // MARK: - Records

    /// The downloads `target` may be written for now: still the signed-in account's own (fix round 1, security M3: the
    /// caller captured it before its read), signed in and online (never in automatic or manual offline).
    private func recordable(_ target: DownloadManager?) -> DownloadManager? {
        guard session != nil, !isOffline, let target, target === downloads else { return nil }
        return target
    }

    /// An album page read online with `songs` (its songs in the server's order). `target`: `downloads` as it was
    /// **before** the read (O3: `let target = model.downloads` first, then read, then
    /// `await model.recordAlbumPage(album, songs: songs, into: target)`), so a read that answers after a sign-out or
    /// another sign-in writes nothing.
    func recordAlbumPage(_ album: Album, songs: [Song], into target: DownloadManager?) async {
        guard let downloads = recordable(target) else { return }
        let record = OfflineRecords.AlbumRecord(album: album, songs: songs, savedAt: .now)
        await downloads.applyRecord(.album(record, songs: songs, albumArtist: album.artist, albumArtistId: album.artistId),
                                    isCurrent: { [weak self] in self?.recordable(downloads) != nil })
    }

    /// An artist page read online with `albums` (in the server's order). A recorded artist's picture is saved at 300 px.
    /// `target` as for `recordAlbumPage`.
    func recordArtistPage(_ artist: Artist, albums: [Album], into target: DownloadManager?) async {
        guard let downloads = recordable(target) else { return }
        let record = OfflineRecords.ArtistRecord(artist: artist, albums: albums, savedAt: .now)
        await downloads.applyRecord(.artist(record), isCurrent: { [weak self] in self?.recordable(downloads) != nil })
    }

    /// A playlist (or flow) page read online with `songs` (its order). Per Q3, recorded whether or not it is
    /// downloaded, as long as it holds a download. `target` as for `recordAlbumPage`.
    func recordPlaylistPage(_ playlist: Playlist, songs: [Song], kind: OfflinePlaylistKind,
                            into target: DownloadManager?) async {
        guard let downloads = recordable(target) else { return }
        let record = OfflineRecords.playlistRecord(playlist, songs: songs, kind: kind, savedAt: .now)
        await downloads.applyRecord(.playlist(record, songs: songs),
                                    isCurrent: { [weak self] in self?.recordable(downloads) != nil })
    }

    // MARK: - Flows on the phone (D335)

    /// The saved Discover file for this account and Aurral user, read (never written); nil without Aurral.
    private func savedDiscoverSnapshot() async -> DiscoverSnapshot? {
        guard aurralSetUp, let feeds = aurralFeedsScope else { return nil }
        await prewarmDiscoverSnapshot()
        guard aurralFeedsScope == feeds else { return nil }
        return discoverSnapshots.snapshot(root: dataDirectory, scope: feeds)
    }

    /// Whether a saved Discover row is listed: not hidden (D273), and another user's only with "Show everyone's flows"
    /// on (D189, D190), exactly as the last read saved them.
    private func isListedOffline(_ row: DiscoverSnapshot.Row, in snapshot: DiscoverSnapshot) -> Bool {
        let id = row.playlist.id
        return !snapshot.hiddenPlaylistIds.contains(id) && (showEveryonesFlows || !snapshot.othersPlaylistIds.contains(id))
    }

    /// The saved flows (Discover's playlists, D185) holding at least one download (a song or its library copy), in
    /// Discover's order, each with its songs on the phone counted and its owner from the saved caption (D205: shown by
    /// `OwnerCaption`, which leaves the user's own out). None without Aurral (a downloaded Discover playlist is then an
    /// ordinary playlist, D75), or signed out.
    func offlineFlows() async -> [Playlist] {
        guard let snapshot = await savedDiscoverSnapshot(), let store = downloads?.store else { return [] }
        let onPhone = Set(await store.entries().filter { $0.kind == .download }.map(\.songId))
        return snapshot.rows.compactMap { row -> Playlist? in
            guard isListedOffline(row, in: snapshot), let page = snapshot.pages[row.playlist.id] else { return nil }
            let count = Self.onPhoneIds(page, onPhone).count
            guard count > 0 else { return nil }
            var playlist = row.playlist.playlist
            playlist.songCount = count
            playlist.owner = row.caption
            return playlist
        }
    }

    /// A flow's page from the phone: its songs on the phone in the flow's order (the library copy where it's the one
    /// downloaded), with how many the flow has. Nil when it isn't listed by `offlineFlows`.
    func offlineFlowPage(id: String) async -> OfflinePlaylistPage? {
        guard let snapshot = await savedDiscoverSnapshot(),
              let row = snapshot.rows.first(where: { $0.playlist.id == id }), isListedOffline(row, in: snapshot),
              let page = snapshot.pages[id] else { return nil }
        let catalog = await offlineCatalog
        let onPhone = Set(catalog.songs().map(\.id))
        let songs = Self.onPhoneIds(page, onPhone).compactMap { catalog.song(id: $0) }
        guard !songs.isEmpty else { return nil }
        var playlist = row.playlist.playlist
        playlist.songCount = songs.count
        playlist.duration = songs.reduce(0) { $0 + $1.duration }
        playlist.owner = row.caption
        return OfflinePlaylistPage(playlist: playlist, kind: row.item.kind == .playlist ? .sharedPlaylist : .flow,
                                   songs: songs, onPhone: songs.count, total: max(page.songIds.count, songs.count))
    }

    /// Each saved entry's id on the phone: its library copy's, else its own.
    private static func onPhoneIds(_ page: DiscoverSnapshot.Page, _ onPhone: Set<String>) -> [String] {
        page.entries.compactMap { entry in
            if let copy = entry.copy?.id, onPhone.contains(copy) { return copy }
            return onPhone.contains(entry.song.id) ? entry.song.id : nil
        }
    }

    /// Hook from `openDiscoverPage` (Q4): a flow downloaded as a whole follows its refreshed page (library copies where
    /// known): new songs download under today's rules (Wi-Fi unless mobile data is allowed), songs that left lose the
    /// flow's reason (and leave the phone unless something else keeps them). Never offline; a flow not downloaded is
    /// left be.
    ///
    /// Fix round 1 (security M1): only a page whose lookups all finished (`complete`) is followed, and each song is
    /// matched by its original id: whichever of its copies is already on the phone (the page's, the original, or the
    /// `earlier` page's copy) stays, so a lookup that found nothing this time never swaps a library copy for Aurral's.
    /// Security M3: the downloads are captured here and the work is the manager's (tracked; a sign-out drops it).
    func followDownloadedFlow(_ page: DiscoverPage, earlier: DiscoverPage? = nil, complete: Bool = true) {
        guard complete, !isOffline, session != nil, let downloads else { return }
        let earlierCopies = Dictionary((earlier?.entries ?? []).map { ($0.original.id, $0.song) }, uniquingKeysWith: { a, _ in a })
        let songs = page.entries.map { entry -> Song in
            let candidates = [entry.song, entry.original, earlierCopies[entry.original.id]].compactMap { $0 }
            return candidates.first { downloads.kind(of: $0.id) == .download } ?? entry.song
        }
        downloads.track { [weak self, weak downloads] gen in
            guard let self, let downloads, downloads.isLive(gen) else { return }
            await self.refreshDownloadedPlaylist(page.playlist, songs: songs, in: downloads, asFlow: true)
        }
    }

    // MARK: - Lyrics (D336)

    /// What the pane shows for `songId` from the lyrics kept on the phone; the ones found online only while Find
    /// lyrics online is on (as the session's, L fix round 1 M4). Nil when none are kept.
    func savedLyrics(songId: String) async -> ShownLyrics? {
        guard let store = downloads?.store, let kept = await store.savedLyrics(songId: songId) else { return nil }
        let source: LyricsSource = kept.source == .library ? .library : .online
        if source == .online, !lyricsKeeper.findOnline { return nil }
        guard let lyrics = kept.lyrics else { return .instrumental(source) }
        return lyrics.lines.isEmpty ? nil : .lines(lyrics, source)
    }

    /// Keeps what the pane would show for a downloaded song (lines or the instrumental note); anything else, and
    /// songs that aren't downloads, stay in memory only (D310).
    func keepLyricsOnPhone(_ songId: String, _ shown: ShownLyrics?) {
        guard let shown, let downloads, downloads.kind(of: songId) == .download else { return }
        let kept: OfflineLyrics
        switch shown {
        case .lines(let lyrics, let source):
            kept = OfflineLyrics(songId: songId, source: source == .library ? .library : .online, lyrics: lyrics, savedAt: .now)
        case .instrumental(let source):
            kept = OfflineLyrics(songId: songId, source: source == .library ? .library : .online, lyrics: nil, savedAt: .now)
        }
        downloads.keepLyrics(kept)   // fix round 1 (security L5): tracked by the manager
    }

    /// Fix round 1 (security L4, D336 amended): hook from Find lyrics online turned off: the kept lyrics found online go.
    func findLyricsOnlineTurnedOff() {
        downloads?.forgetLyricsFoundOnline()
    }
}
