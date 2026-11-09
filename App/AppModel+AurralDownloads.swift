import AurralKit
import Foundation
import MagpieCore

/// Round 24 C: what a song on "Songs still coming" offers (ruling Q5: no Cancel).
enum SongsStillComingAction: Sendable, Equatable { case approve, tryAnotherSource, searchNow }

/// Round 24 C fix round 1: why an action on a song wasn't sent.
enum SongsStillComingRefusal: Error, Equatable {
    /// I5: Magpie is already asking Aurral about that song (a second tap, or a row's Search now during "Search now for N").
    case alreadyAsking
    /// The fresh read shows the song isn't missing any more (found meanwhile, or being looked for).
    case notMissing
}

/// Round 24 C fix round 1 (M3): what "Search now for N" came to.
struct SearchNowOutcome: Sendable, Equatable {
    var sent: Int
    /// Aurral answered 403 part-way: nothing more was sent (D199's "Your account can't ask for songs again.").
    var refused: Bool
}

/// Round 24 C (owner, 2026-11-08, item 6: "A page like the active Lidarr downloads page, for Aurral: songs not yet
/// downloaded, their state; search now, blocklist and re-search, approve a download held for review"; D213, D214;
/// ruling Q5).
///
/// - "Songs still coming" lists the songs of the user's own flows and Aurral playlists (another user's too with
///   "Show everyone's flows" on, D190) by Aurral's state (`SongsStillComing`). Reads only what is already allowed:
///   `GET /api/playlists/status` and each item's `GET /api/playlists/jobs/:id`, at most `songsStillComingItemLimit`
///   items per read, four at a time; the page reads again every `songsStillComingInterval` while it is on screen. An
///   item whose songs couldn't be read keeps its last rows and is marked unread (fix round 1, M1).
/// - Actions only on the user's own songs, each hidden without `AurralCapabilities.canManage` and offline: **Approve**
///   and **Try another source** (B's approve and deny, D209) on a song Aurral held for review; **Search now** on one not
///   found, D199's Retry route and rules (never while that flow's run is under way, D61); "Search now for N" sends
///   D199's batch (at most `SearchAgain.perTap`, each once). Every one is sent once, on the owner's tap; the page then
///   reads again (the send and the read are separate: a failed read isn't a failed action, M2).
/// - Fix round 1 (B-M1): Aurral 2.13 checks no ownership on approve or deny, so `sendHeldDecision`, their one caller,
///   reads the status and the item's songs fresh and sends only when the item is still the user's and the song still
///   held (`scripts/check-writes.sh` pins that guard). Search now reads the song fresh too (M3).
/// - Fix round 1 (I5): a song being asked about (`discover.songsAsking`) is asked about once; a second ask is refused
///   and offers nothing until the first is answered.
/// - Home's banner counts the user's own held songs from the jobs Discover already reads (no extra read).
extension AppModel {
    /// Items read per refresh of the page (a bound like Lidarr's page: never a read per item without end).
    nonisolated static let songsStillComingItemLimit = 40
    /// How often the open page reads again.
    nonisolated static let songsStillComingInterval: Duration = .seconds(15)

    /// The page's entry (Settings › Aurral) shows: Aurral set up, its flows' songs readable, and this user allowed to
    /// read them (accessFlow; 2.13 refuses the reads otherwise).
    var songsStillComingAvailable: Bool {
        aurralSetUp && aurralCapabilities.playlistJobsById && discover.bootstrap?.user?.canAddFlow == true
            && !discover.flowsNotPermitted
    }

    /// Home's banner: the user's own songs Aurral holds for review, as Discover last read them (0 when the user can't
    /// decide them here).
    var heldSongsWaiting: Int {
        guard songsStillComingAvailable, aurralMayManage, let user = discover.bootstrap?.user,
              let status = discover.status else { return 0 }
        let own = Set((status.flows + status.sharedPlaylists).filter { $0.belongs(to: user) }.map(\.id))
        return discover.jobs.filter { job in
            job.status?.lowercased() == "blocked" && job.flowId.map(own.contains) == true
        }.count
    }

    /// The page, read fresh: Aurral's status, then each item's songs. An item whose songs couldn't be read keeps
    /// `previous`'s rows for it and is listed in `unread` (M1). Throws `CancellationError` when cancelled meanwhile.
    func readSongsStillComing(previous: SongsStillComing.Board? = nil) async throws -> SongsStillComing.Board {
        guard songsStillComingAvailable, !isOffline, let client = aurralClient else { throw AurralError.notPermitted }
        let status: AurralStatus
        do { status = try await client.status() } catch {
            noteAurralError(error)
            throw error
        }
        noteStatus(status)
        let user = discover.bootstrap?.user
        var items = (status.flows + status.sharedPlaylists).map { ($0, user.map($0.belongs) ?? false) }
        if showEveryonesFlows { items += status.othersPlaylists.map { ($0, false) } }
        items = Array(items.filter { discover.removing[$0.0.id] == nil }.prefix(Self.songsStillComingItemLimit))
        var read = [[AurralJob]?](repeating: nil, count: items.count)   // nil: couldn't be read
        await withTaskGroup(of: (Int, [AurralJob]?).self) { group in
            var started = 0
            for (index, item) in items.enumerated() {
                if started >= 4, let done = await group.next() { read[done.0] = done.1 }   // four at a time
                started += 1
                group.addTask {
                    do { return (index, try await client.playlistJobs(item.0.id) ?? []) }   // 404: none (gone)
                    catch { return (index, nil) }
                }
            }
            for await done in group { read[done.0] = done.1 }
        }
        try Task.checkCancellation()
        var unread = Set<String>()
        var board = SongsStillComing.board(items.enumerated().map { index, item in
            if let jobs = read[index] { return SongsStillComing.Item(item: item.0, own: item.1, jobs: jobs) }
            unread.insert(item.0.id)
            return SongsStillComing.Item(item: item.0, own: item.1, jobs: Self.lastJobs(of: item.0.id, in: previous))
        })
        board.unread = unread
        noteJobStates(read.compactMap { $0 }.flatMap { $0 })
        return board
    }

    /// An item's songs as the last board showed them (M1).
    nonisolated static func lastJobs(of itemId: String, in board: SongsStillComing.Board?) -> [AurralJob] {
        guard let board else { return [] }
        return SongsStillComing.Section.allCases.flatMap { board.rows($0) }.filter { $0.item.id == itemId }.map(\.job)
    }

    /// What `row` offers now (nothing on another user's song, offline, without `canManage`, or while Magpie is asking
    /// about it); Search now not while that flow's run is under way (D61).
    func actions(for row: SongsStillComing.Row) -> [SongsStillComingAction] {
        guard !discover.songsAsking.contains(row.job.id) else { return [] }
        return [.approve, .tryAnotherSource, .searchNow].filter { action in
            offers(action, row) && (action != .searchNow || !isFlowRunActive(row.item.id))
        }
    }

    /// Whether `action` is ever offered on `row`: the user's own song, in the right state, managed here.
    private func offers(_ action: SongsStillComingAction, _ row: SongsStillComing.Row) -> Bool {
        guard row.own, aurralMayManage, ownAurralItem(id: row.item.id) != nil, discover.removing[row.item.id] == nil else {
            return false
        }
        switch action {
        case .approve, .tryAnotherSource: return row.section == .held
        case .searchNow: return row.section == .notFound && aurralCapabilities.trackResearch
        }
    }

    /// Approve (after "Add this copy to your library?"): Aurral adds the copy it held back. Sent once.
    func approve(_ row: SongsStillComing.Row) async throws { try await sendHeldDecision(.approve, row) }

    /// Try another source (after its confirmation): Aurral's deny. It won't use that copy again and looks for another.
    func tryAnotherSource(_ row: SongsStillComing.Row) async throws { try await sendHeldDecision(.tryAnotherSource, row) }

    /// B-M1: the one place Approve and Try another source are sent. Aurral's status and the item's songs are read fresh;
    /// only an item still the user's (`belongs(to:)` on the fresh status) and a song still held are sent, once.
    private func sendHeldDecision(_ action: SongsStillComingAction, _ row: SongsStillComing.Row) async throws {
        let client = try manageClient(action, row)
        try beginAsking([row.job.id])
        defer { endAsking([row.job.id]) }
        do {
            let fresh = try await client.status()
            noteStatus(fresh)
            let jobs = try await client.playlistJobs(row.item.id) ?? []
            let freshItem = (fresh.flows + fresh.sharedPlaylists).first { $0.id == row.item.id }
            guard let user = discover.bootstrap?.user, let freshItem, freshItem.belongs(to: user) else { throw AurralError.notPermitted }
            guard jobs.contains(where: { $0.id == row.job.id && $0.status?.lowercased() == "blocked" }) else {
                throw AurralError.notHeldAnyMore
            }
            if action == .approve {
                try await client.approveHeldSong(row.job.id)
            } else {
                try await client.denyHeldSong(row.job.id)
            }
        } catch {
            noteAurralError(error)
            throw error
        }
    }

    /// Search now for one song not found: Aurral's status read fresh first, refused while that flow's run is under way
    /// (D61, nothing sent); the song read fresh and sent only while still missing; then D199's Retry route, once.
    func searchNow(_ row: SongsStillComing.Row) async throws {
        let client = try manageClient(.searchNow, row)
        try beginAsking([row.job.id])
        defer { endAsking([row.job.id]) }
        do {
            noteStatus(try await client.status())
            guard !isFlowRunActive(row.item.id) else { throw AurralError.runActive }
            let jobs = try await client.playlistJobs(row.item.id) ?? []
            guard SearchAgain.missing(jobs).contains(where: { $0.id == row.job.id }) else {
                throw SongsStillComingRefusal.notMissing
            }
            try await sendSearchNow(row, client)
        } catch {
            noteAurralError(error)
            throw error
        }
    }

    /// The user's own songs "Search now for N" would send (at most `SearchAgain.perTap`), as last read.
    func searchNowBatch(_ board: SongsStillComing.Board) -> [SongsStillComing.Row] {
        Array(board.notFound.filter { actions(for: $0).contains(.searchNow) }.prefix(SearchAgain.perTap))
    }

    /// "Search now for N" (after D199's confirmation): status read fresh, each item's songs read fresh (M3: only songs
    /// still missing, of items with no run under way; an item that doesn't read sends nothing), then each once, one
    /// after another. A 403 stops it (`refused`). Songs another ask is under way for are left out (I5).
    func searchNowAll(_ board: SongsStillComing.Board) async throws -> SearchNowOutcome {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard aurralMayManage, aurralCapabilities.trackResearch, let client = aurralClient else {
            throw AurralError.notPermitted
        }
        do { noteStatus(try await client.status()) } catch {
            noteAurralError(error)
            throw error
        }
        let candidates = searchNowBatch(board)
        var stillMissing = Set<String>()
        for itemId in Set(candidates.map(\.item.id)) {
            guard let jobs = try? await client.playlistJobs(itemId) else { continue }
            stillMissing.formUnion(SearchAgain.missing(jobs).map { itemId + "/" + $0.id })
        }
        let batch = candidates.filter { stillMissing.contains($0.id) && !discover.songsAsking.contains($0.job.id) }
        let ids = Set(batch.map(\.job.id))
        try beginAsking(ids)
        defer { endAsking(ids) }
        var sent = 0
        var failure: Error?
        for row in batch {
            do {
                try await sendSearchNow(row, client)
                sent += 1
            } catch AurralError.notPermitted {
                return SearchNowOutcome(sent: sent, refused: true)   // this account may not: nothing more is sent
            } catch {
                failure = error   // a lost answer may have gone through: never sent again
            }
        }
        if sent == 0, let failure { throw failure }
        return SearchNowOutcome(sent: sent, refused: false)
    }

    /// D199's Retry route for one song, the page's only call of it (`scripts/check-writes.sh` pins its callers).
    private func sendSearchNow(_ row: SongsStillComing.Row, _ client: AurralClient) async throws {
        _ = try await client.retrySong(playlistId: row.item.id, jobId: row.job.id)
    }

    /// The client for one of `row`'s actions, or why not: offline (nothing sent), or not offered (`notPermitted`).
    private func manageClient(_ action: SongsStillComingAction, _ row: SongsStillComing.Row) throws -> AurralClient {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard offers(action, row), let client = aurralClient else { throw AurralError.notPermitted }
        return client
    }

    /// I5: marks songs as being asked about, before anything is sent; refuses if any already is.
    private func beginAsking(_ ids: Set<String>) throws {
        guard discover.songsAsking.isDisjoint(with: ids) else { throw SongsStillComingRefusal.alreadyAsking }
        discover.songsAsking.formUnion(ids)
    }

    private func endAsking(_ ids: Set<String>) { discover.songsAsking.subtract(ids) }

    /// The songs just read update Discover's own copy of their states (so Home's banner follows an Approve at once).
    private func noteJobStates(_ jobs: [AurralJob]) {
        let fresh = Dictionary(jobs.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        discover.jobs = discover.jobs.map { job in
            guard let status = fresh[job.id] else { return job }
            var job = job
            job.status = status
            return job
        }
    }
}

/// The words for D213 and D214 (the plan's where it gives them; §5 voice elsewhere).
enum SongsStillComingCopy {
    static let title = "Songs still coming"
    static let entry = "Songs still coming"
    static let entryFooter = "Songs your flows and playlists are still waiting for, and the ones held for you to decide."
    static let empty = "Nothing is waiting on Aurral."
    /// Fix round 1 (I2, ruling): the phone can't play a held copy, so no "Listen to decide".
    static let heldNote = "Aurral held this copy back for you to decide."
    /// Plan §6 C risk: Aurral holds songs back only with its review setting on.
    static let noneHeld = "Aurral holds a song back for you to decide only when its review setting is on."
    static let approve = "Approve"
    static let approveTitle = "Add this copy to your library?"
    static let tryAnotherSource = "Try another source"
    static let tryAnotherSourceTitle = "Try another source?"
    static let tryAnotherSourceMessage = "Aurral won\u{2019}t use that copy again and looks for another."
    static let searchNow = "Search now"
    static func searchNowAll(_ n: Int) -> String { "Search now for \(n)" }
    /// Fix round 1 (M7, ruling).
    static let unreachable = "Couldn\u{2019}t check on your songs. Trying again\u{2026}"
    static let working = "Asking\u{2026}"
    /// Fix round 1 (M3): D199's words after a 403.
    static let searchNowAllRefused = SearchAgainCopy.text(.notAllowed)
    /// Fix round 1 (I4): a song's progress, when Aurral gives one.
    static func progress(_ percent: Int) -> String { "\(percent)%" }

    static func heading(_ section: SongsStillComing.Section) -> String {
        switch section {
        case .held: "Held for review"
        case .notFound: "Not found"
        case .looking: "Looking"
        case .downloading: "Downloading"
        case .doneRecently: "Done recently"
        }
    }

    /// Each state its own symbol beside its words (D3).
    static func symbol(_ section: SongsStillComing.Section) -> String {
        switch section {
        case .held: "hand.raised"
        case .notFound: "magnifyingglass"
        case .looking: "clock"
        case .downloading: "arrow.down.circle.dotted"
        case .doneRecently: "checkmark.circle"
        }
    }

    /// A row's state line: the section, and for a song never downloaded, that.
    static func state(_ row: SongsStillComing.Row) -> String {
        row.section == .notFound && row.job.status?.lowercased() == "saved" ? "Not downloaded yet" : heading(row.section)
    }

    /// Home's banner (no service named on Home).
    static func banner(_ n: Int) -> String {
        n == 1 ? "1 song is waiting for you to decide" : "\(n) songs are waiting for you to decide"
    }
    static let bannerHint = "Opens Songs still coming."

    static func madeBy(_ owner: String) -> String { "made by \(owner)" }

    static func message(for error: Error) -> String {
        if let refusal = error as? SongsStillComingRefusal {
            switch refusal {
            case .alreadyAsking: return "Magpie is already asking about that song."
            case .notMissing: return "That song isn\u{2019}t missing any more."
            }
        }
        switch error as? AurralError {
        case .notHeldAnyMore?: return "That song isn\u{2019}t waiting for you any more."
        case .runActive?: return "Songs are still downloading there. Try again when they\u{2019}re done."
        default: return DiscoverCopy.message(for: error)
        }
    }

    /// "Search now for N"'s failure words: a 403 is D199's (M3).
    static func searchNowAllMessage(for error: Error) -> String {
        (error as? AurralError) == .notPermitted ? searchNowAllRefused : message(for: error)
    }
}
