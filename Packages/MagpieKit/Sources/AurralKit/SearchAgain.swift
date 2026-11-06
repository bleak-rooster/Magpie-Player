import Foundation
import MagpieCore

/// Round 23 R23F (owner, 2026-11-07): "an option to let me re-search Aurral playlist/flow songs that haven't
/// downloaded or are stalled … per playlist/flow" (D199, D200). Which of one flow's or playlist's songs "Search again
/// for missing songs" asks Aurral to look for again, and what its jobs say afterwards. Pure, so tested on its own.
///
/// Checked in Aurral 2.13.0's source (and current `main`):
/// - Its own playlist page offers "search again" for a song `failed` or `saved` (`trackAvailability.ts`
///   `getTrackSearchAction`; saved: a flow's pick never downloaded). Those are the missing songs here.
/// - The research route refuses a song `pending` or `downloading` (`enqueueResearchTrack`: 409 "Track is already being
///   processed"; the worker's `researchPlaylistTrack` does nothing for one either), so one is never sent.
/// - A stalled song is Aurral's own call: its worker gives up on a transfer with no progress for 30 minutes
///   (`slskdOrchestrator` `STALLED_TRANSFER_MS`) or still untouched in an uploader's queue after 10
///   (`QUEUED_TRANSFER_MS`), tries its next source and then fails the song, which makes it missing here.
public enum SearchAgain {
    /// Songs asked for per tap (D200): a default flow (20 songs) in one tap; a 100-song chart flow in four. Each send
    /// queues one operation on Aurral's single playlist operation queue, so a tap never floods it, and stays far
    /// inside Aurral's API limit (5,000 requests per 15 minutes per address, `app.ts`).
    public static let perTap = 25

    /// The statuses Aurral offers to search again for.
    static let offered: Set<String> = ["failed", "saved"]

    /// The missing songs: failed or never downloaded, not a quality upgrade's job (`upgradeForJobId`), each once, in
    /// Aurral's order.
    public static func missing(_ jobs: [AurralJob]) -> [AurralJob] {
        var seen = Set<String>()
        return jobs.filter { job in
            guard let status = job.status?.lowercased(), offered.contains(status), job.upgradeForJobId == nil else {
                return false
            }
            return seen.insert(job.id).inserted
        }
    }

    /// What one tap sends: the first `perTap` missing songs.
    public static func batch(_ jobs: [AurralJob]) -> [AurralJob] { Array(missing(jobs).prefix(perTap)) }

    /// How a tap ended, as the jobs report it.
    public struct Outcome: Sendable, Equatable {
        public var found: Int
        public var stillMissing: Int
        public init(found: Int, stillMissing: Int) { self.found = found; self.stillMissing = stillMissing }
    }

    /// Nil while Aurral is still looking for one of the songs `sent` (pending or downloading); then the ones now done
    /// are found and every other one (failed again, blocked, gone from the list) is still missing.
    public static func outcome(sent: [String], jobs: [AurralJob]) -> Outcome? {
        let byId = Dictionary(jobs.map { ($0.id, $0.status?.lowercased()) }, uniquingKeysWith: { a, _ in a })
        var found = 0
        for id in sent {
            switch byId[id] ?? nil {
            case "pending"?, "downloading"?: return nil
            case "done"?: found += 1
            default: break
            }
        }
        return Outcome(found: found, stillMissing: sent.count - found)
    }
}
