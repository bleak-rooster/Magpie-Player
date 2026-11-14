import AurralKit
import Foundation
import MagpieCore
import MatchIndex
import NavidromeKit

/// Round 27 D1 (owner, 2026-11-14, items 2 and 3): "When you open discover, it should have all of the flows and aurral
/// playlists loaded then saved … In the background it checks for any changes and then reloads it when it has updated",
/// and "the time it takes to load one of the aurral playlist/flow especially when filled with more songs takes too long.
/// Find a much more efficient way of doing this" (D283–D286).
///
/// Root causes found (reproduced in `DiscoverPageSpeedTests` and `DiscoverSnapshotAppTests`):
/// 1. A flow's page opened soon after launch waited, with no bound, for the whole Discover read: status, every
///    playlist, the jobs, each candidate playlist one after another, the item proofs and Aurral's library.
/// 2. The page showed nothing until every song's library copy had been looked up (up to two reads a song, four at a
///    time): a 100-song flow was up to ~200 requests in front of the owner.
/// 3. The lookups lived only in memory for 30 minutes, so every launch asked them all again.
/// 4. Songs of the main library that Aurral's playlist only refers to were looked up as if they were Aurral's copies.
///
/// Now (all reads, nothing written anywhere):
/// - Discover's rows and each playlist's page are saved per account and Aurral user (`DiscoverSnapshotFile`) and shown
///   at once; the ordinary read runs behind and only a real difference replaces them, in place (D283, D284);
/// - a page waits at most `discoverWait` for the Discover read, shows its songs after one `getPlaylist`, and fills the
///   library copies in row by row; a main-library song needs no lookup; lookups are kept with the page (a copy for a
///   week while the match index holds it, none for a day); a copy found after Play replaces that song where it is still
///   to come in the queue (D59's swap) (D285);
/// - after Library › Discover shows, every shown page is read and saved in the background, bounded (D284).
/// Which playlists are Aurral's and whose they are is still decided only by the read (D286): the saved rows are only
/// what the last read decided, used before the next one.
extension AppModel {
    /// D284: the background pass's bounds: playlists, songs looked up, and the gap between passes (two pages at once).
    nonisolated static let discoverPassPlaylists = 40
    nonisolated static let discoverPassLookups = 400
    nonisolated static let discoverPassGap: TimeInterval = 10 * 60

    // MARK: - Rows

    /// D283: the saved rows, used while nothing has been read this session (launch, Aurral slow): `discover.playlists`
    /// and what the last read decided about them (whose, the captions, the item rows, the hidden ones). Never without
    /// Aurral, offline, or while Aurral refuses this user its flows; never when the saved rows don't hold every playlist
    /// kept out of Playlists, nor without those ids at all (D185: the saved ids stand alone then; none: nothing known).
    func restoreSavedDiscover() {
        guard aurralSetUp, !isOffline, !discover.flowsNotPermitted, discover.playlists.isEmpty, discover.statusReadAt == nil,
              let scope = navidromeScope, let feeds = aurralFeedsScope else { return }
        let snapshot = discoverSnapshots.snapshot(root: dataDirectory, scope: feeds)
        guard !snapshot.rows.isEmpty else { return }
        let playlists = snapshot.rows.map(\.discoverPlaylist)
        guard let keptOut = appDefaults.stringArray(forKey: Self.discoverPlaylistsKey(scope)).map(Set.init),
              keptOut.isSubset(of: Set(playlists.map(\.playlist.id))) else { return }
        discover.playlists = playlists
        discover.othersPlaylistIds = Set(snapshot.othersPlaylistIds)
        discover.playlistOwners = Dictionary(snapshot.rows.compactMap { row in row.caption.map { (row.playlist.id, $0) } },
                                             uniquingKeysWith: { a, _ in a })
        // The user's own flows wait for the read: one may be Your flows' row (round 16), never a second one here.
        discover.itemRows = snapshot.itemRows.filter { !($0.mine && $0.item.kind == .flow) }
            .map { DiscoverItemRow(item: $0.item.flow, mine: $0.mine) }
        if !discover.hiddenRead { discover.hiddenPlaylistIds = Set(snapshot.hiddenPlaylistIds) }
        discover.savedSharedItemIds = Set(snapshot.rows.filter { $0.item.kind == .playlist }.map(\.item.id))
    }

    /// Hook from `performDiscoverRead`, after it decided Discover's playlists: they are saved when they differ from the
    /// saved ones, and Library › Discover (and, unless the read already told it, Home's Discover shelf) swaps them in.
    func saveDiscoverRows(announced: Bool) {
        guard let feeds = aurralFeedsScope else { return }
        let rows = discover.playlists.prefix(DiscoverSnapshot.maxPlaylists).map {
            DiscoverSnapshot.Row($0, shared: isSyncedPlaylist(flowId: $0.flow.id), caption: discover.playlistOwners[$0.playlist.id])
        }
        let items = discover.itemRows.prefix(DiscoverSnapshot.maxPlaylists).map {
            DiscoverSnapshot.ItemRow(item: .init($0.item, kind: isSyncedPlaylist(flowId: $0.item.id) ? .playlist : .flow),
                                     mine: $0.mine)
        }
        let hidden = hiddenDiscoverPlaylistIds.sorted(), others = discover.othersPlaylistIds.sorted()
        var changed = false
        discoverSnapshots.update(root: dataDirectory, scope: feeds) { snapshot in
            changed = snapshot.rows != rows || snapshot.itemRows != items || snapshot.hiddenPlaylistIds != hidden
                || snapshot.othersPlaylistIds != others
            guard changed else { return false }
            snapshot.rows = rows
            snapshot.itemRows = items
            snapshot.hiddenPlaylistIds = hidden
            snapshot.othersPlaylistIds = others
            let kept = Set(discover.playlists.map(\.playlist.id))
            snapshot.pages = snapshot.pages.filter { kept.contains($0.key) }   // a playlist no longer Aurral's: its page goes
            return true
        }
        guard changed else { return }
        discover.rowsRevision += 1
        if !announced { homeFeedSlot?.sectionsChanged([.discover]) }
    }

    /// Hook from sign-out, Aurral sign-out and another Aurral user, beside D90's feeds file.
    func forgetDiscoverSnapshots() {
        discoverSnapshots.forget(root: dataDirectory)
    }

    // MARK: - Pages

    /// The saved page of `playlistId`, as it shows (with the flow as now known); its lookups join this session's
    /// where they are newer. nil when none is saved (or without Aurral).
    func savedDiscoverPage(playlistId: String) -> DiscoverPage? {
        guard aurralSetUp, let feeds = aurralFeedsScope,
              let saved = discoverSnapshots.snapshot(root: dataDirectory, scope: feeds).pages[playlistId] else { return nil }
        let copies = Dictionary(saved.entries.compactMap { entry in entry.copy.map { (entry.song.id, $0.song) } },
                                uniquingKeysWith: { a, _ in a })
        for (songId, lookup) in saved.lookups where (discover.lookups[songId]?.at ?? .distantPast) < lookup.at {
            let copy = lookup.copyId.flatMap { id in copies[songId].flatMap { $0.id == id ? $0 : nil } }
            if lookup.copyId != nil, copy == nil { continue }   // a copy the page doesn't carry: asked again
            discover.lookups[songId] = DiscoverLookup(copy: copy, at: lookup.at)
        }
        return DiscoverPage(playlist: saved.playlist.playlist, flow: discoverFlow(playlistId: playlistId),
                            entries: saved.discoverEntries)
    }

    /// Saves `page` with its songs' lookups (the session's, as they stand).
    func saveDiscoverPage(_ page: DiscoverPage) {
        guard let feeds = aurralFeedsScope else { return }
        let lookups = Dictionary(page.entries.compactMap { entry in
            discover.lookups[entry.original.id].map { (entry.original.id, DiscoverSnapshot.Lookup(copyId: $0.copy?.id, at: $0.at)) }
        }, uniquingKeysWith: { a, _ in a })
        let record = DiscoverSnapshot.Page(playlist: page.playlist, savedAt: discover.now(),
                                           entries: page.entries.map { ($0.original, $0.inYourLibrary ? $0.song : nil) },
                                           lookups: lookups)
        discoverSnapshots.update(root: dataDirectory, scope: feeds) { snapshot in
            guard snapshot.pages[page.playlist.id] != record else { return false }
            snapshot.pages[page.playlist.id] = record
            return true
        }
    }

    /// D285: opens a Discover playlist's page. The saved one is `show`n at once (unless `fresh`); the Discover read is
    /// waited for at most `discoverWait` when nothing is known yet (`waitForRead`, the phone's page; the car never
    /// waits); the playlist is read; when its songs are the saved ones the saved entries stay, otherwise the new songs
    /// show at once, each as Aurral's copy until its lookup lands; then each library copy fills its row in place, and
    /// replaces that song where it is still to come in the queue. The page is saved when done. `background`: a page
    /// whose songs are the saved ones is left as it is (no lookups), and lookups come out of `budget` (D284).
    @discardableResult
    func openDiscoverPage(playlistId: String, fresh: Bool, waitForRead: Bool, background: Bool = false,
                          budget: DiscoverLookupBudget? = nil,
                          show: @escaping (DiscoverPage) -> Void) async throws -> DiscoverPage {
        let feeds = aurralFeedsScope
        if !background { restoreSavedDiscover() }
        let saved = fresh ? nil : savedDiscoverPage(playlistId: playlistId)
        let savedRecord = fresh || feeds == nil ? nil
            : feeds.flatMap { discoverSnapshots.snapshot(root: dataDirectory, scope: $0).pages[playlistId] }
        if let saved { show(saved) }
        if waitForRead {   // the phone's page: the read when stale, waited for only with nothing to show
            if discover.playlists.isEmpty, saved == nil {
                await refreshDiscover(waitingAtMost: Self.discoverWait)
            } else {
                startDiscoverRead()
            }
        }
        let (playlist, songs) = try await request { try await $0.playlist(id: playlistId) }
        guard aurralFeedsScope == feeds else { throw CancellationError() }   // another account or Aurral meanwhile
        noteFlowSongs(songs)
        let flow = discoverFlow(playlistId: playlistId)
        let unchanged = savedRecord?.matches(changed: playlist.changed, songIds: songs.map(\.id)) ?? false
        if background, unchanged, let saved { return saved }
        var page: DiscoverPage
        if unchanged, let saved {
            page = DiscoverPage(playlist: playlist, flow: flow, entries: saved.entries)
        } else {
            let known = discover.copies
            page = DiscoverPage(playlist: playlist, flow: flow,
                                entries: songs.map { DiscoverEntry(song: known[$0.id] ?? $0, original: $0) })
        }
        show(page)
        let copies = await lookUpLibraryCopies(for: songs, flowId: flow?.id, fresh: fresh, budget: budget) { [weak self] id, copy in
            page.entries = page.entries.map { entry in
                entry.original.id == id ? DiscoverEntry(song: copy ?? entry.original, original: entry.original) : entry
            }
            show(page)
            if let copy { self?.replaceQueuedDiscoverSong(id, with: copy) }
        }
        guard aurralFeedsScope == feeds else { throw CancellationError() }
        page.entries = DiscoverRules.swapped(songs, copies: copies)
        show(page)
        saveDiscoverPage(page)
        return page
    }

    /// D285 (D59's swap): a library copy found after Play replaces that Discover song where it is still to come; the
    /// song playing now plays on as it is (no restart mid-song).
    func replaceQueuedDiscoverSong(_ id: String, with copy: Song) {
        guard player.queue.current?.song.id != id, player.queue.upcoming.contains(where: { $0.song.id == id }) else { return }
        player.replaceSong(id: id, with: copy)
    }

    /// D285: the car (and the queue's Play next) get the saved page at once, refreshed behind it; without one, the
    /// page is read as the phone's is, never waiting for the Discover read.
    func discoverPageSavedOrRead(playlistId: String, fresh: Bool) async throws -> DiscoverPage {
        restoreSavedDiscover()
        if !fresh, let saved = savedDiscoverPage(playlistId: playlistId) {
            refreshDiscoverPageBehind(playlistId)
            return saved
        }
        return try await openDiscoverPage(playlistId: playlistId, fresh: fresh, waitForRead: false) { _ in }
    }

    /// The saved page of `playlistId` read again and saved, once at a time (tests wait on it).
    @discardableResult
    func refreshDiscoverPageBehind(_ playlistId: String) -> Task<Void, Never> {
        if let running = discoverSnapshots.behind[playlistId] { return running }
        let store = discoverSnapshots
        let task = Task { [weak self] in
            _ = try? await self?.openDiscoverPage(playlistId: playlistId, fresh: false, waitForRead: false) { _ in }
            if !Task.isCancelled { store.behind[playlistId] = nil }   // cancelled: `forget` let go of it already
        }
        store.behind[playlistId] = task
        return task
    }

    // MARK: - Every page, in the background

    /// D284: after Library › Discover shows `rows`, each shown playlist's page is read and saved in the background:
    /// newest-changed first, a saved page with the same `changed` and as many songs skipped unread, at most
    /// `discoverPassPlaylists` pages and `discoverPassLookups` songs looked up, two pages at a time, one pass per
    /// `discoverPassGap` this session; cancelled at sign-out or another account. Offline, nothing.
    func startDiscoverPagePass(rows: [Playlist]) {
        guard aurralSetUp, !isOffline, session != nil, !rows.isEmpty, let feeds = aurralFeedsScope else { return }
        let store = discoverSnapshots
        guard store.passTask == nil else { return }
        if let at = store.passStartedAt, discover.now().timeIntervalSince(at) < Self.discoverPassGap { return }
        store.passStartedAt = discover.now()
        let saved = store.snapshot(root: dataDirectory, scope: feeds).pages
        let ids = DiscoverSnapshot.pagesToRefresh(rows: rows, saved: saved, limit: Self.discoverPassPlaylists)
        let budget = DiscoverLookupBudget(Self.discoverPassLookups)
        let queue = DiscoverPassQueue(ids)
        let root = dataDirectory
        store.holdsWrites = true
        store.passTask = Task { [weak self] in
            async let first: Void = self?.discoverPassWorker(queue, feeds: feeds, budget: budget) ?? ()
            async let second: Void = self?.discoverPassWorker(queue, feeds: feeds, budget: budget) ?? ()   // two at a time
            _ = await (first, second)
            guard !Task.isCancelled else { return }   // sign-out or another account: `forget` let go of everything
            store.lastPassLookups = budget.used
            store.flush(root: root, scope: feeds)   // one write for the whole pass
            store.passTask = nil
        }
    }

    /// One of the pass's two readers: the next page, until none is left, the pass is cancelled, or the account, the
    /// Aurral user or the connection changed.
    private func discoverPassWorker(_ queue: DiscoverPassQueue, feeds: String, budget: DiscoverLookupBudget) async {
        while !Task.isCancelled, aurralFeedsScope == feeds, !isOffline, let id = queue.next() {
            _ = try? await openDiscoverPage(playlistId: id, fresh: false, waitForRead: false, background: true,
                                            budget: budget) { _ in }
        }
    }

    /// Waits for the background pass under way (tests).
    func discoverPagePassSettled() async { await discoverSnapshots.passTask?.value }

    // MARK: - Lookups

    /// D285: whether this session's lookup of a song may be used as it is (`DiscoverSnapshot.Lookup.isFresh`), with the
    /// match index as now built (`index` nil: none, or an empty one).
    func isFreshDiscoverLookup(_ lookup: DiscoverLookup, now: Date, index: MatchIndex?) -> Bool {
        DiscoverSnapshot.Lookup(copyId: lookup.copy?.id, at: lookup.at)
            .isFresh(now: now, indexHoldsCopy: lookup.copy.flatMap { copy in index.map { $0.contains(songId: copy.id) } })
    }

    /// The match index when it is built and holds songs (a saved copy it no longer holds is looked up again).
    func discoverMatchIndex() async -> MatchIndex? {
        guard let index = await matchIndex?.index, index.count > 0 else { return nil }
        return index
    }
}

/// Round 27 D1 (D284): the pages a background pass has still to read, shared by its two readers.
@MainActor final class DiscoverPassQueue {
    private var ids: [String]
    init(_ ids: [String]) { self.ids = ids.reversed() }
    func next() -> String? { ids.popLast() }
}
