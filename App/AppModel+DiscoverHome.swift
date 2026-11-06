import AurralKit
import Foundation
import MagpieCore

/// Round 13 Z2 (plan item 5): Home's Discover and Playlists stay right whatever Aurral is doing.
///
/// Root causes found (reproduced in `Round13HomeTests`):
/// 1. One read of Aurral that couldn't confirm a flow's playlist (its job list unreadable or slow, or a run under way
///    with the jobs cleared while the server still holds the last run's songs) took the playlist out of Discover and
///    saved that. Discover vanished (the next shelf moved into its place) and the playlist, whose cover is a grid of
///    album covers, moved to the top of Playlists. Now a known Discover playlist leaves Discover only on positive
///    evidence (`keptDiscoverPlaylists`).
/// 2. Home's whole read waited for Aurral (status, jobs, each playlist, its library), so with Aurral slow every shelf
///    not saved on the phone stayed hidden for up to a minute. Now Discover waits at most `discoverWait` and then uses
///    the playlists known to be Discover's; the read of Aurral carries on, and Home reads Discover and Playlists again
///    if it changes them.
/// 3. Discover's saved shelf was thrown away at every launch (`HomeShelf.fits`).
extension AppModel {
    /// The longest a screen waits for Aurral before showing the Discover playlists it already knows.
    nonisolated static let discoverWait: Duration = .seconds(3)

    /// The flows' playlists after a read. Round 22 R22A (owner, D182, supersedes D62's "more than half" and D75's
    /// "another playlist confirmed for the flow"): every playlist named as one of Aurral's is Discover's unless
    /// `ownersOwn` proves it the owner's own on this read. D75's stickiness holds in what it was for: a read that can't
    /// prove anything (jobs unreadable, a run under way, songs that didn't read) never moves one out of Discover; only
    /// proof does, so a playlist wrongly taken in while Aurral's library wasn't known yet goes back to the owner.
    /// Several playlists may be one flow's (an older name beside the new one): all are Discover's.
    nonisolated static func keptFlowPlaylists(_ candidates: [DiscoverPlaylist],
                                              ownersOwn: (DiscoverPlaylist) -> Bool) -> [DiscoverPlaylist] {
        candidates.filter { !ownersOwn($0) }
    }

    /// The playlists one read of Aurral reads the songs of: every candidate, and every known Discover playlist the
    /// server still has that no flow is named as now (a flow renamed first, or no flows listed).
    nonisolated static func discoverPlaylistsToRead(candidates: [DiscoverPlaylist], before: Set<String>,
                                                    all: [Playlist]) -> [String] {
        let named = candidates.map(\.playlist.id)
        let orphans = all.map(\.id).filter { before.contains($0) && !named.contains($0) }
        return named + orphans
    }

    /// Review I1: Discover after a read. Candidates follow `keptFlowPlaylists` (round 22 R22A: named as Aurral's and
    /// not proven the owner's own, D182). A known Discover playlist that no flow
    /// is named as now (and that the server still has) stays Discover's unless Aurral positively says otherwise: it
    /// leaves only when the status lists flows, none is named as it, its songs could be read, and they are no longer a
    /// flow's (by Aurral's jobs) or Aurral's copies. A status with no flows (Z1's fail-closed status when the user
    /// isn't known), a flow renamed before its playlist, or songs that didn't read change nothing. A kept playlist's
    /// flow is the one its songs belong to, else the one it had (renamed as the status says), else none (no Refresh).
    /// `evidence` gets the kept playlists whose songs show them Aurral's (R22A): only their songs teach Magpie what
    /// Aurral's copies and library are, never a playlist that is Discover's only for want of proof.
    func keptDiscoverPlaylists(flows: [AurralFlow], all: [Playlist], candidates: [DiscoverPlaylist],
                               entries: [String: [Song]], before: Set<String>, jobsRead: Bool,
                               evidence: inout Set<String>) -> [DiscoverPlaylist] {
        let known = knownAurralSongIds
        let jobs = discover.jobs
        let libraries = savedDiscoverLibraryIds
        // R22A (D182): a read that can't tell keeps what was known (Discover's before, or proven the owner's own
        // before); one never told apart is Aurral's.
        let ownBefore = ownPlaylistIds
        var own = Set<String>(), found = Set<String>()
        var kept = Self.keptFlowPlaylists(candidates) { candidate in
            let flowId = candidate.flow.id, id = candidate.playlist.id
            let told = DiscoverRules.isOwnersOwn(songs: entries[id],
                                                 flowJobs: flowId.isEmpty ? [] : jobs.filter { $0.flowId == flowId },
                                                 jobsRead: jobsRead, runActive: !flowId.isEmpty && isFlowRunActive(flowId),
                                                 aurralSongIds: known, aurralLibraries: libraries)
            let isOwn = told ?? (ownBefore.contains(id) && !before.contains(id))
            if isOwn { own.insert(id) }
            if told == false { found.insert(id) }
            return isOwn
        }
        if let scope = navidromeScope { appDefaults.set(own.sorted(), forKey: Self.ownPlaylistsKey(scope)) }
        let named = Set(candidates.map(\.playlist.id))
        let previous = Dictionary(discover.playlists.map { ($0.playlist.id, $0.flow) }, uniquingKeysWith: { a, _ in a })
        for playlist in all where before.contains(playlist.id) && !named.contains(playlist.id) {
            let had = previous[playlist.id].flatMap { old in flows.first { $0.id == old.id } ?? old }
            let fallback = had ?? AurralFlow(id: "", name: playlist.name)
            guard !flows.isEmpty, let songs = entries[playlist.id] else {
                kept.append(DiscoverPlaylist(flow: fallback, playlist: playlist))   // nothing to go by: unchanged
                continue
            }
            func confirms(_ flow: AurralFlow, _ jobs: [AurralJob], _ ids: Set<String>) -> Bool {
                !DiscoverRules.confirmedFlowPlaylists([DiscoverPlaylist(flow: flow, playlist: playlist)],
                                                      entries: [playlist.id: songs], jobs: jobs, aurralSongIds: ids).isEmpty
            }
            if let flow = flows.first(where: { confirms($0, jobs, []) }) {
                kept.append(DiscoverPlaylist(flow: flow, playlist: playlist))   // still a flow's songs
                found.insert(playlist.id)
            } else if confirms(fallback, [], known) {
                kept.append(DiscoverPlaylist(flow: fallback, playlist: playlist))   // still Aurral's copies
                found.insert(playlist.id)
            }
        }
        evidence = found
        let keptIds = Set(kept.map(\.playlist.id))
        let order = all.map(\.id).filter(keptIds.contains)
        let byId = Dictionary(kept.map { ($0.playlist.id, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { byId[$0] }
    }

    /// Reads Aurral again (`performDiscoverRead`), one read at a time: a call while one is under way joins it; a
    /// forced call starts a new one after it, so two reads never overlap and an older one never writes last.
    func refreshDiscover(force: Bool = false) async {
        await sharedDiscoverRead(force: force).value
    }

    @discardableResult
    private func sharedDiscoverRead(force: Bool) -> Task<Void, Never> {
        if let running = discover.refreshTask, !force { return running.task }
        let previous = discover.refreshTask?.task
        let id = UUID()
        let state = discover
        let task = Task { [weak self] in
            await previous?.value
            if !Task.isCancelled { await self?.performDiscoverRead(force: force) }
            if state.refreshTask?.id == id { state.refreshTask = nil }
        }
        discover.refreshTask = (id, task)
        return task
    }

    /// Reads Aurral again when stale, shared with every other caller, and waits for it at most `limit` (less when the
    /// caller is cancelled). The read goes on after the wait; whatever it changes reaches Home by itself. Polls the
    /// shared read rather than awaiting it, so no waiter outlives the wait.
    func refreshDiscover(waitingAtMost limit: Duration) async {
        sharedDiscoverRead(force: false)
        guard let id = discover.refreshTask?.id else { return }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while discover.refreshTask?.id == id, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }   // cancelled: stop waiting
        }
    }
}

extension AurralFlow {
    /// The flow, or nil for the empty one a kept Discover playlist without a known flow carries.
    var nonEmpty: AurralFlow? { id.isEmpty ? nil : self }
}
