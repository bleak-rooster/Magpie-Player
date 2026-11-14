import AurralKit
import Foundation
import MagpieCore
import NavidromeKit
import Observation
import os

/// Round 27 D1 (owner, 2026-11-14, item 2: "When you open discover, it should have all of the flows and aurral
/// playlists loaded then saved. So when you open it again, it can load quickly. In the background it checks for any
/// changes and then reloads it when it has updated. It then saves this for next time"; D283): Discover's saved file.
/// One per Navidrome account and Aurral user (`AurralFeeds.scope`, D90's hash: never a server or user name), beside
/// D90's feeds file in Application Support/Magpie/Discover, excluded from backup, and removed with it (Aurral sign-out,
/// account sign-out, another Aurral user). What it holds is `DiscoverSnapshot`'s: rows and pages, ids and what a row
/// shows, never a URL or a key.
struct DiscoverSnapshotFile {
    let url: URL

    static let suffix = "-lists.json"

    init(root: URL, scope: String) {
        url = AurralFeeds.directory(root: root).appending(path: scope + Self.suffix)
    }

    /// The saved snapshot; nil when there is none, it is too big, another version, or doesn't read.
    func load() -> DiscoverSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return DiscoverSnapshot.decode(data)
    }

    /// Saves `snapshot` as it is (the store fits it to its bounds first, `DiscoverSnapshot.fitted`).
    func save(_ snapshot: DiscoverSnapshot) {
        do {
            try AtomicFile.write(snapshot, to: url)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var saved = url, directory = url.deletingLastPathComponent()
            try saved.setResourceValues(values)
            try directory.setResourceValues(values)
        } catch {
            Log.logger("discover").error("cannot save Discover's lists: \(Log.category(of: error), privacy: .public)")
        }
    }

    /// Removes every account's file under `root` (sign-out, another Aurral user).
    static func removeAll(root: URL) {
        let directory = AurralFeeds.directory(root: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(suffix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

/// Round 27 D1: the snapshot in memory for the signed-in account and Aurral user, and the session's background work on
/// it (the pages read behind Library › Discover, D284; a car page refreshed behind its saved copy, D285).
@MainActor final class DiscoverSnapshotStore {
    private var loaded: (scope: String, snapshot: DiscoverSnapshot)?
    /// D284: the background pass under way, and when this session's last one started (one per 10 minutes).
    var passTask: Task<Void, Never>?
    var passStartedAt: Date?
    /// D284: how many songs the last pass looked up (tests).
    var lastPassLookups = 0
    /// D285: a saved page being refreshed behind what the car showed, by playlist id.
    var behind: [String: Task<Void, Never>] = [:]
    /// D284, fix round 1 (M2): a background pass's own pages are kept in memory (`update(held:)`) and written with the
    /// next write that isn't held (a page the owner opened, a read's rows) or when the pass ends.
    private var unwritten = false
    /// Fix round 1 (M6): bumped by `forget`, so a read of the file started before it never lands after it.
    private var generation = 0

    /// Fix round 1 (M6): reads `scope`'s file off the main actor (up to 4 MB), once; the first screen awaits it.
    func prewarm(root: URL, scope: String) async {
        if let loaded, loaded.scope == scope { return }
        let file = DiscoverSnapshotFile(root: root, scope: scope), started = generation
        let read = await Task.detached(priority: .userInitiated) { file.load() }.value
        guard generation == started, loaded?.scope != scope else { return }
        loaded = (scope, read ?? DiscoverSnapshot())
    }

    /// The snapshot for `scope`: as in memory, else as saved, else empty.
    func snapshot(root: URL, scope: String) -> DiscoverSnapshot {
        if let loaded, loaded.scope == scope { return loaded.snapshot }
        let snapshot = DiscoverSnapshotFile(root: root, scope: scope).load() ?? DiscoverSnapshot()
        loaded = (scope, snapshot)
        return snapshot
    }

    /// Changes `scope`'s snapshot and saves it; `change` returns false to leave it (and the file) as it was.
    func update(root: URL, scope: String, held: Bool = false, _ change: (inout DiscoverSnapshot) -> Bool) {
        var snapshot = self.snapshot(root: root, scope: scope)
        guard change(&snapshot) else { return }
        guard !held else {
            loaded = (scope, snapshot.bounded())
            unwritten = true
            return
        }
        write(snapshot, root: root, scope: scope)
    }

    /// Writes what a background pass kept in memory, if it is still this account's.
    func flush(root: URL, scope: String) {
        guard unwritten else { return }
        guard let loaded, loaded.scope == scope else { return }
        write(loaded.snapshot, root: root, scope: scope)
    }

    private func write(_ snapshot: DiscoverSnapshot, root: URL, scope: String) {
        unwritten = false
        let fitted = (try? snapshot.fitted()) ?? snapshot.bounded()
        loaded = (scope, fitted)
        DiscoverSnapshotFile(root: root, scope: scope).save(fitted)
    }

    /// Sign-out of Aurral or of the account, or another Aurral user: the work stops, the memory and every file go.
    func forget(root: URL) {
        passTask?.cancel()
        passTask = nil
        passStartedAt = nil
        for task in behind.values { task.cancel() }
        behind = [:]
        unwritten = false
        generation += 1
        loaded = nil
        DiscoverSnapshotFile.removeAll(root: root)
    }
}

/// Round 27 D1 (D284): the songs a background pass may still look up (400 a pass), shared by its pages.
@MainActor final class DiscoverLookupBudget {
    private(set) var remaining: Int
    private(set) var used = 0
    init(_ limit: Int) { remaining = max(0, limit) }

    /// One more lookup, if any are left.
    func take() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        used += 1
        return true
    }
}

/// Round 27 D1 (owner, 2026-11-14, item 3; D285): one Discover playlist's page. The saved page shows at once; the
/// playlist is read again behind it, and its songs show as soon as they are read, each library copy filling its row in
/// place as its lookup lands. Nothing moves when nothing changed (`visibleChanges`), and a swap has no animation.
@MainActor @Observable final class DiscoverPageModel {
    let playlistId: String
    private(set) var state: Loadable<DiscoverPage> = .loading
    /// How many times what shows changed after it first showed (tests).
    @ObservationIgnored private(set) var visibleChanges = 0

    init(playlistId: String) { self.playlistId = playlistId }

    var page: DiscoverPage? { state.value }

    /// `fresh`: pull to refresh (every song looked up again; a failure says so). Otherwise a failure with a page on
    /// screen (the saved one) is quiet.
    func load(_ model: AppModel, fresh: Bool) async {
        do {
            _ = try await model.openDiscoverPage(playlistId: playlistId, fresh: fresh, waitForRead: true) { [weak self] page in
                self?.show(page)
            }
        } catch {
            state = fresh ? state.failing(error, noticeTo: model) : state.failing(error)
        }
    }

    /// The page as read replaces the one shown (it carries more than a saved page keeps, for Add and the artists); a
    /// change counts only when what a row shows changed.
    private func show(_ page: DiscoverPage) {
        guard state.value != page else { return }
        if let shown = state.value, shown.visible != page.visible { visibleChanges += 1 }
        state = .loaded(page)
    }
}

extension DiscoverPage {
    /// Round 27 D1 (D284): what the page shows: the playlist's row, whether it has a flow, and each row's song as
    /// `SongRow` shows it ("In your library" included).
    var visible: [String] {
        let list = DiscoverSnapshot.SavedPlaylist(playlist)
        let head = "\(list.id)|\(list.name)|\(list.coverArtId ?? "")|\(flow?.id ?? "")"
        return [head] + entries.map { entry in
            let song = DiscoverSnapshot.SavedSong(entry.song)
            return "\(entry.original.id)>\(song.id)|\(song.title)|\(song.artist)|\(song.album)|\(song.duration)|\(song.coverArtId ?? "")"
        }
    }
}

/// Round 27 D1 (D283, D284): Library › Discover's rows. The saved rows show at once; when a read changes them, the new
/// rows replace them in place (by row id, no animation); the same rows change nothing. Once rows show, every shown
/// playlist's page is read and saved in the background (`AppModel.startDiscoverPagePass`).
@MainActor @Observable final class DiscoverListModel {
    private(set) var rows: Loadable<[DiscoverRow]> = .loading
    /// How many times the rows changed after they first showed (tests).
    @ObservationIgnored private(set) var visibleChanges = 0

    func load(_ model: AppModel) async {
        if rows.value == nil {
            await model.prewarmDiscoverSnapshot()   // fix round 1 (M6): read off the main actor
            if let now = model.discoverRowsNow() { show(now) }   // the saved rows, before any wait
        }
        do {
            let fresh = try await model.discoverRows()
            show(fresh)
            model.startDiscoverPagePass(rows: fresh.compactMap {
                if case .playlist(let playlist) = $0.link { playlist } else { nil }
            })
        } catch {
            rows = rows.failing(error, noticeTo: model)   // Round 13 Z2: also never for a load cut short
        }
    }

    /// Rows a delete took away, at once.
    func remove(_ ids: Set<String>) {
        guard let list = rows.value else { return }
        show(list.filter { !ids.contains($0.id) })
    }

    private func show(_ new: [DiscoverRow]) {
        guard rows.value != new else { return }
        if rows.value != nil { visibleChanges += 1 }
        rows = .loaded(new)
    }
}
