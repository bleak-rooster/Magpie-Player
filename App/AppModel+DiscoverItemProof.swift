import AurralKit
import Foundation
import MagpieCore

/// Round 25 (owner, 2026-11-10): "There is one playlist with the same name in two separate users, and when I set it so
/// that only playlists/flows specific to me are meant to show, this playlist does not show at all. When I want to see
/// all playlists, then this playlist comes up twice without the name of the other user underneath either one."
/// (D251, D252).
///
/// With Aurral's owner prefix off, two users' items with one name give two Navidrome playlists of that name, and only
/// their songs say which is whose (D203 step 3): a name another item carries is never enough (step 4). The songs came
/// from Aurral's general jobs list alone, which doesn't always hold them: it may not be readable at all (a server
/// whose list is over D115's 8 MB cap reads as none), and Aurral 2.13 lists a playlist's songs taken from the Library
/// (`canonicalJobId`) as the Library's there. So neither item was proven, neither playlist claimed: the user's own
/// was hidden under "only mine", and both were listed under everyone's with no owner.
///
/// Each read now also reads, for the items a shared name leaves unproven (`DiscoverIdentity.unproven`), each one's
/// own songs from `GET /api/playlists/jobs/:id` (already allow-listed; what Songs still coming reads): the user's own
/// first, at most `discoverItemProofLimit` items, four at a time. Nothing is written. Once proven, a claim is saved
/// (D204), so the next read needs no reads for it.
///
/// Fix round 1 (I1): an item the general list contradicts is read too, whatever its name (that list may hold only some
/// of its songs). An item asked for whose songs don't come (an error, or none listed) is `unread`: the general list's
/// partial evidence then never drops its saved claim, which holds and is saved again.
extension AppModel {
    nonisolated static let discoverItemProofLimit = 10

    /// What `readDiscoverItemProof` learnt: each item's own songs, and the items asked for that gave none.
    struct DiscoverItemProof {
        var jobs: [String: [AurralJob]] = [:]
        var unread: Set<String> = []
    }

    /// Hook from `performDiscoverRead`, before `identifyDiscoverPlaylists`: the songs of the items that need them (none
    /// when nothing is unproven, or with no items listed). `playlists`: the Aurral playlists named as an item on this
    /// read.
    func readDiscoverItemProof(client: AurralClient, mine: [AurralFlow], others: [AurralFlow], playlists: [Playlist],
                               jobs: [AurralJob], entries: [String: [Song]], scope: String) async -> DiscoverItemProof {
        let items = mine + others
        guard !items.isEmpty else { return DiscoverItemProof() }
        let saved = discoverClaimsToResolve(scope: scope, items: items, playlists: playlists)
        let ids = Array(DiscoverIdentity.unproven(aurralItems: items, playlists: playlists, jobs: jobs, saved: saved,
                                                  entries: entries, running: Set(mine.map(\.id).filter(isFlowRunActive)))
            .prefix(Self.discoverItemProofLimit))
        guard !ids.isEmpty else { return DiscoverItemProof() }
        var read: [String: [AurralJob]] = [:]
        await withTaskGroup(of: (String, [AurralJob]?).self) { group in
            var started = 0
            for id in ids {
                if started >= 4, let done = await group.next() { read[done.0] = done.1 }   // four at a time
                started += 1
                group.addTask {
                    // As Songs still coming (R24 integration fix, D246): one return after the do/catch.
                    let jobs: [AurralJob]?
                    do { jobs = try await client.playlistJobs(id) } catch { jobs = nil }   // unreadable: no proof
                    return (id, jobs)
                }
            }
            for await done in group { read[done.0] = done.1 }
        }
        let given = read.filter { !$0.value.isEmpty }
        return DiscoverItemProof(jobs: given, unread: Set(ids).subtracting(given.keys))
    }
}
