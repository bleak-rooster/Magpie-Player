import AurralKit
import Foundation
import MagpieCore

/// Round 23 R23F (owner, 2026-11-07): "an option to let me re-search Aurral playlist/flow songs that haven't
/// downloaded or are stalled … per playlist/flow" (D199, D200). "Search again for N missing songs" on the Discover page
/// of one of the user's own flows or Aurral playlists.
///
/// - Missing is what Aurral offers to search again for: failed (stalled transfers end there: Aurral gives up on one
///   after 30 minutes without progress) or never downloaded (`SearchAgain.missing`). One pending or downloading is
///   never sent (Aurral refuses it), and while one is, the flow's run is under way and the action is hidden (D61).
/// - Only on the owner's confirmed tap, through the allow-listed Retry route (D81/D82: `shared-playlists/:id/tracks/
///   :jobId/research`, which Aurral 2.13 serves for a flow's songs as for a playlist's), each song once per tap, one
///   after another, at most `SearchAgain.perTap`. Status is read fresh first; nothing is sent while a run is under way.
/// - Hidden without the capability (`trackResearch`, `playlistJobsById`) or the user's accessFlow, offline, and on
///   another user's flow (D190). A 403: a quiet note on the page.
enum SearchAgainState: Equatable, Sendable {
    /// Sent; Aurral is looking for this many songs.
    case looking(Int)
    /// The jobs settled.
    case finished(SearchAgain.Outcome)
    /// Aurral said no (403): this account may not.
    case notAllowed
}

/// One page's "Search again" this session: the songs the last tap sent, and what they came to.
struct SearchAgainRun: Equatable, Sendable {
    var sent: [String]
    var state: SearchAgainState
}

extension AppModel {
    /// This Aurral can search again and its user may (as last read), online.
    var maySearchAgain: Bool {
        let can = aurralCapabilities
        return can.trackResearch && can.playlistJobsById && discover.bootstrap?.user?.canAddFlow == true && !isOffline
    }

    /// The user's own flow or Aurral playlist a Discover page is (nil: another user's, one kept without a known flow,
    /// or Search again isn't available).
    func searchAgainFlow(playlistId: String) -> AurralFlow? {
        guard maySearchAgain,
              let flow = discover.playlists.first(where: { $0.playlist.id == playlistId })?.flow.nonEmpty,
              let status = discover.status,
              (status.flows + status.sharedPlaylists).contains(where: { $0.id == flow.id }) else { return nil }
        return flow
    }

    /// The page's missing songs, read fresh (none when Search again isn't available or the read fails).
    func missingSongs(playlistId: String) async -> [AurralJob] {
        guard let flow = searchAgainFlow(playlistId: playlistId), let client = aurralClient else { return [] }
        do {
            return SearchAgain.missing(try await client.playlistJobs(flow.id) ?? [])
        } catch {
            noteSearchAgainRefusal(error, playlistId: playlistId)
            return []
        }
    }

    /// Search again (after the owner confirmed): reads Aurral's status fresh and refuses while the flow's run is under
    /// way (`AurralError.runActive`, nothing sent), reads the songs fresh, then sends each missing one once, one after
    /// another, at most `SearchAgain.perTap`. A send that fails isn't sent again. Returns how many were sent.
    @discardableResult
    func searchAgain(playlistId: String) async throws -> Int {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard let flow = searchAgainFlow(playlistId: playlistId), let client = aurralClient else {
            throw AurralError.notPermitted
        }
        let batch: [AurralJob]
        do {
            noteStatus(try await client.status())
            guard !isFlowRunActive(flow.id) else { throw AurralError.runActive }   // D61
            batch = SearchAgain.batch(try await client.playlistJobs(flow.id) ?? [])
        } catch {
            noteSearchAgainRefusal(error, playlistId: playlistId)
            throw error
        }
        guard !batch.isEmpty else { return 0 }
        discover.searchAgain[playlistId] = SearchAgainRun(sent: [], state: .looking(batch.count))
        var sent: [String] = []
        var failure: Error?
        var refused = false
        for job in batch {
            do {
                _ = try await client.retrySong(playlistId: flow.id, jobId: job.id)
                sent.append(job.id)
            } catch AurralError.notPermitted {
                refused = true
                break   // this account may not: nothing more is sent
            } catch {
                failure = error   // a lost answer may have gone through: never sent again
            }
        }
        if refused {
            discover.searchAgain[playlistId] = SearchAgainRun(sent: sent, state: .notAllowed)
            return sent.count
        }
        guard !sent.isEmpty else {
            discover.searchAgain[playlistId] = nil
            throw failure ?? AurralError.notFound
        }
        discover.searchAgain[playlistId] = SearchAgainRun(sent: sent, state: .looking(sent.count))
        return sent.count
    }

    /// While Aurral is looking: reads the songs again and, once none sent is pending or downloading, the outcome.
    func followSearchAgain(playlistId: String) async {
        guard let run = discover.searchAgain[playlistId], case .looking = run.state,
              let flow = searchAgainFlow(playlistId: playlistId), let client = aurralClient,
              let jobs = try? await client.playlistJobs(flow.id),
              let outcome = SearchAgain.outcome(sent: run.sent, jobs: jobs),
              discover.searchAgain[playlistId] == run else { return }
        discover.searchAgain[playlistId] = SearchAgainRun(sent: run.sent, state: .finished(outcome))
    }

    func searchAgainState(playlistId: String) -> SearchAgainState? { discover.searchAgain[playlistId]?.state }

    /// A 403 is a quiet note on the page; anything else is only noted (`noteAurralError`).
    private func noteSearchAgainRefusal(_ error: Error, playlistId: String) {
        if (error as? AurralError) == .notPermitted {
            discover.searchAgain[playlistId] = SearchAgainRun(sent: [], state: .notAllowed)
        } else if (error as? AurralError) != .runActive {
            noteAurralError(error)
        }
    }
}

/// The words for D199/D200 (§5 voice: about music, "your server").
enum SearchAgainCopy {
    static func button(_ n: Int) -> String {
        n == 1 ? "Search again for 1 missing song" : "Search again for \(n) missing songs"
    }
    static func confirmTitle(_ n: Int) -> String { button(n) + "?" }
    static let confirmMessage = "Asks your server to look for these songs again."
    static let confirm = "Search again"
    static let symbol = "magnifyingglass"

    static func text(_ state: SearchAgainState) -> String {
        switch state {
        case .looking(let n): n == 1 ? "Looking again for 1 song" : "Looking again for \(n) songs"
        case .finished(let o): "\(o.found) found, \(o.stillMissing) still missing"
        case .notAllowed: "Your account can\u{2019}t ask for songs again."
        }
    }

    /// Each state its own symbol beside its words (D3).
    static func symbol(_ state: SearchAgainState) -> String {
        switch state {
        case .looking: "magnifyingglass"
        case .finished(let o): o.stillMissing == 0 ? "checkmark.circle" : "exclamationmark.circle"
        case .notAllowed: "info.circle"
        }
    }
}
