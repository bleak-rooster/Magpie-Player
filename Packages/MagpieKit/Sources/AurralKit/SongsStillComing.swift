import Foundation
import MagpieCore

/// Round 24 C (owner, 2026-11-08, item 6: "a page like the active Lidarr downloads page, for Aurral: songs not yet
/// downloaded, their state; search now, blocklist and re-search, approve a download held for review"; D213). The pure
/// rules of "Songs still coming": each song's section by Aurral 2.13's job state, which rows are the user's own, and
/// Done recently's limit. Pure, so tested on its own.
///
/// Aurral 2.13's job states: `pending`, `downloading`, `done`, `failed`, `saved`, `blocked`, `cancelled`,
/// `cancel_requested`. `blocked` is a copy Aurral held back for review (`blockedJobReview.ts`): only these may be
/// approved or denied (D209). Not found is D199's "missing" (failed, or saved: a flow's pick never downloaded), never a
/// quality upgrade's job (`SearchAgain.missing`), the only songs "Search now" sends.
public enum SongsStillComing {
    /// Done recently shows at most this many: the last Aurral lists (it gives no finish time).
    public static let doneShown = 10

    public enum Section: String, Sendable, CaseIterable {
        case held, notFound, looking, downloading, doneRecently
    }

    /// One flow or playlist and its songs, as read.
    public struct Item: Sendable, Equatable {
        public var item: AurralFlow
        /// The signed-in user's own (D190: the only ones with actions; Aurral decides for everyone else's).
        public var own: Bool
        public var jobs: [AurralJob]
        public init(item: AurralFlow, own: Bool, jobs: [AurralJob]) { self.item = item; self.own = own; self.jobs = jobs }
    }

    /// One song on the page.
    public struct Row: Sendable, Equatable, Identifiable {
        public var job: AurralJob
        public var item: AurralFlow
        public var own: Bool
        public var section: Section
        /// The item and the job: a job id is Aurral's own and unique, the item keeps two reads apart.
        public var id: String { item.id + "/" + job.id }
    }

    public struct Board: Sendable, Equatable {
        public var held: [Row] = []
        public var notFound: [Row] = []
        public var looking: [Row] = []
        public var downloading: [Row] = []
        public var doneRecently: [Row] = []
        /// Fix round 1 (M1): the items whose songs couldn't be read this time (their rows, if any, are the last read's).
        public var unread: Set<String> = []
        public init() {}

        /// Nothing is waiting: nothing held, missing, looked for or downloading (Done recently doesn't count).
        public var isEmpty: Bool { held.isEmpty && notFound.isEmpty && looking.isEmpty && downloading.isEmpty }

        public func rows(_ section: Section) -> [Row] {
            switch section {
            case .held: held
            case .notFound: notFound
            case .looking: looking
            case .downloading: downloading
            case .doneRecently: doneRecently
            }
        }
    }

    /// The section a song is in; nil for one not shown (cancelled, a cancel asked for, a state Magpie doesn't know, a
    /// quality upgrade's job that failed).
    public static func section(of job: AurralJob) -> Section? {
        switch job.status?.lowercased() {
        case "blocked": .held
        case "pending": .looking
        case "downloading": .downloading
        case "done": .doneRecently
        case "failed", "saved": SearchAgain.missing([job]).isEmpty ? nil : .notFound
        default: nil
        }
    }

    /// The page: every item's songs in their sections, in Aurral's order (each row once), Done recently the last
    /// `doneShown`.
    public static func board(_ items: [Item]) -> Board {
        var board = Board()
        var seen = Set<String>()
        var done: [Row] = []
        for item in items {
            for job in item.jobs {
                guard let section = section(of: job) else { continue }
                let row = Row(job: job, item: item.item, own: item.own, section: section)
                guard seen.insert(row.id).inserted else { continue }
                switch section {
                case .held: board.held.append(row)
                case .notFound: board.notFound.append(row)
                case .looking: board.looking.append(row)
                case .downloading: board.downloading.append(row)
                case .doneRecently: done.append(row)
                }
            }
        }
        board.doneRecently = Array(done.suffix(doneShown))
        return board
    }
}
