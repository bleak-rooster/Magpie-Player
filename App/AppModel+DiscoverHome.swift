import AurralKit
import Foundation
import MagpieCore
import os

/// Round 13 Z2 (plan item 5): Home's Discover and Playlists stay right whatever Aurral is doing.
///
/// Root causes found (reproduced in `Round13HomeTests`):
/// 1. One read of Aurral that couldn't confirm a flow's playlist (its job list unreadable or slow, or a run under way
///    with the jobs cleared while the server still holds the last run's songs) took the playlist out of Discover and
///    saved that. Discover vanished (the next shelf moved into its place) and the playlist, whose cover is a grid of
///    album covers, moved to the top of Playlists. Now a playlist confirmed once stays Discover's while it is still
///    named after the flow and no other playlist is confirmed for it.
/// 2. Home's whole read waited for Aurral (status, jobs, each playlist, its library), so with Aurral slow every shelf
///    not saved on the phone stayed hidden for up to a minute. Now Discover waits at most `discoverWait` and then uses
///    the playlists known to be Discover's; the read of Aurral carries on, and Home reads Discover and Playlists again
///    if it changes them.
/// 3. Discover's saved shelf was thrown away at every launch (`HomeShelf.fits`).
extension AppModel {
    /// The longest a screen waits for Aurral before showing the Discover playlists it already knows.
    nonisolated static let discoverWait: Duration = .seconds(3)

    /// The flows' playlists after a read: the ones confirmed now, and each one Discover's before (`before`) that is
    /// still named after its flow (it is a candidate) when no other playlist is confirmed for that flow. Aurral keeps a
    /// flow's playlist id and renames it in place, so a playlist once confirmed stays Discover's until it no longer
    /// carries a flow's name, another is confirmed for the flow, or Aurral is disconnected.
    nonisolated static func keptFlowPlaylists(_ candidates: [DiscoverPlaylist], confirmed: [DiscoverPlaylist],
                                              before: Set<String>) -> [DiscoverPlaylist] {
        let confirmedIds = Set(confirmed.map(\.playlist.id))
        let confirmedFlows = Set(confirmed.map(\.flow.id))
        return candidates.filter {
            confirmedIds.contains($0.playlist.id) || (before.contains($0.playlist.id) && !confirmedFlows.contains($0.flow.id))
        }
    }

    /// Reads Aurral again when stale (`refreshDiscover`), in a task of its own shared by every caller, and waits for it
    /// at most `limit`. The read goes on after the wait; whatever it changes reaches Home by itself.
    func refreshDiscover(waitingAtMost limit: Duration) async {
        let task: Task<Void, Never>
        if let running = discover.refreshTask {
            task = running
        } else {
            let state = discover
            task = Task { [weak self] in
                await self?.refreshDiscover()
                state.refreshTask = nil
            }
            discover.refreshTask = task
        }
        // Not a task group: leaving one waits for every child, and waiting on `task.value` can't be cancelled.
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @Sendable () -> Void = {
                if resumed.withLock({ done in defer { done = true }; return !done }) { continuation.resume() }
            }
            let timer = Task {
                try? await Task.sleep(for: limit)
                finish()
            }
            Task {
                await task.value
                timer.cancel()
                finish()
            }
        }
    }
}
