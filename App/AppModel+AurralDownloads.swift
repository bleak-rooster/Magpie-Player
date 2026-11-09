import AurralKit
import Foundation
import MagpieCore

/// Round 24 C: what a song on "Songs still coming" offers (ruling Q5: no Cancel).
enum SongsStillComingAction: Sendable, Equatable { case approve, tryAnotherSource, searchNow }

/// Round 24 C (owner, 2026-11-08, item 6: "A page like the active Lidarr downloads page, for Aurral: songs not yet
/// downloaded, their state; search now, blocklist and re-search, approve a download held for review"; D213, D214;
/// ruling Q5).
///
/// - "Songs still coming" lists the songs of the user's own flows and Aurral playlists (another user's too with
///   "Show everyone's flows" on, D190) by Aurral's state (`SongsStillComing`). Reads only what is already allowed:
///   `GET /api/playlists/status` and each item's `GET /api/playlists/jobs/:id`, at most `songsStillComingItemLimit`
///   items per read, four at a time; the page reads again every `songsStillComingInterval` while it is on screen.
/// - Actions only on the user's own songs (Aurral 2.13 checks no ownership on approve or deny), each hidden without
///   `AurralCapabilities.canManage` and offline: **Approve** and **Try another source** (B's approve and deny, D209) on
///   a song Aurral held for review; **Search now** on one not found, D199's Retry route and rules (never while that
///   flow's run is under way, D61); "Search now for N" sends D199's batch (at most `SearchAgain.perTap`, each once).
///   Every one is sent once, on the owner's tap; the page then reads again.
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
        guard songsStillComingAvailable, aurralMayManage else { return 0 }
        return discover.jobs.filter { job in
            job.status?.lowercased() == "blocked" && job.flowId.map { ownAurralItem(id: $0) != nil } == true
        }.count
    }

    /// The page, read fresh: Aurral's status, then each item's songs.
    func readSongsStillComing() async throws -> SongsStillComing.Board {
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
        var read = [[AurralJob]?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, [AurralJob]?).self) { group in
            var started = 0
            for (index, item) in items.enumerated() {
                if started >= 4, let done = await group.next() { read[done.0] = done.1 }   // four at a time
                started += 1
                group.addTask { (index, try? await client.playlistJobs(item.0.id)) }
            }
            for await done in group { read[done.0] = done.1 }
        }
        let board = SongsStillComing.board(items.enumerated().map { index, item in
            SongsStillComing.Item(item: item.0, own: item.1, jobs: read[index] ?? [])
        })
        noteJobStates(read.compactMap { $0 }.flatMap { $0 })
        return board
    }

    /// What `row` offers now (nothing on another user's song, offline, or without `canManage`); Search now not while
    /// that flow's run is under way (D61).
    func actions(for row: SongsStillComing.Row) -> [SongsStillComingAction] {
        [.approve, .tryAnotherSource, .searchNow].filter { action in
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

    /// Approve (after "Add this copy to your library?"): Aurral adds the copy it held back. Sent once; then the page, read again.
    func approve(_ row: SongsStillComing.Row) async throws -> SongsStillComing.Board {
        let client = try manageClient(.approve, row)
        do { try await client.approveHeldSong(row.job.id) } catch {
            noteAurralError(error)
            throw error
        }
        return try await readSongsStillComing()
    }

    /// Try another source (after its confirmation): Aurral's deny. It won't use that copy again and looks for another.
    func tryAnotherSource(_ row: SongsStillComing.Row) async throws -> SongsStillComing.Board {
        let client = try manageClient(.tryAnotherSource, row)
        do { try await client.denyHeldSong(row.job.id) } catch {
            noteAurralError(error)
            throw error
        }
        return try await readSongsStillComing()
    }

    /// Search now for one song not found: Aurral's status read fresh first, refused while that flow's run is under way
    /// (D61, nothing sent); then D199's Retry route, once.
    func searchNow(_ row: SongsStillComing.Row) async throws -> SongsStillComing.Board {
        let client = try manageClient(.searchNow, row)
        do {
            noteStatus(try await client.status())
            guard !isFlowRunActive(row.item.id) else { throw AurralError.runActive }
            _ = try await client.retrySong(playlistId: row.item.id, jobId: row.job.id)
        } catch {
            noteAurralError(error)
            throw error
        }
        return try await readSongsStillComing()
    }

    /// The user's own songs "Search now for N" would send (at most `SearchAgain.perTap`), as last read.
    func searchNowBatch(_ board: SongsStillComing.Board) -> [SongsStillComing.Row] {
        Array(board.notFound.filter { actions(for: $0).contains(.searchNow) }.prefix(SearchAgain.perTap))
    }

    /// "Search now for N" (after D199's confirmation): status read fresh, then each of the user's own songs not found
    /// whose flow has no run under way, once, one after another. Returns how many were sent; a refusal (403) stops it.
    func searchNowAll(_ board: SongsStillComing.Board) async throws -> Int {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard aurralMayManage, aurralCapabilities.trackResearch, let client = aurralClient else {
            throw AurralError.notPermitted
        }
        do { noteStatus(try await client.status()) } catch {
            noteAurralError(error)
            throw error
        }
        var sent = 0
        var failure: Error?
        for row in searchNowBatch(board) {
            do {
                _ = try await client.retrySong(playlistId: row.item.id, jobId: row.job.id)
                sent += 1
            } catch AurralError.notPermitted {
                failure = AurralError.notPermitted
                break   // this account may not: nothing more is sent
            } catch {
                failure = error   // a lost answer may have gone through: never sent again
            }
        }
        if sent == 0, let failure { throw failure }
        return sent
    }

    /// The client for one of `row`'s actions, or why not: offline (nothing sent), or not offered (`notPermitted`).
    private func manageClient(_ action: SongsStillComingAction, _ row: SongsStillComing.Row) throws -> AurralClient {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard offers(action, row), let client = aurralClient else { throw AurralError.notPermitted }
        return client
    }

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
    static let heldNote = "Aurral held this copy back. Listen to decide."
    /// Plan §6 C risk: Aurral holds songs back only with its review setting on.
    static let noneHeld = "Aurral holds a song back for you to decide only when its review setting is on."
    static let approve = "Approve"
    static let approveTitle = "Add this copy to your library?"
    static let tryAnotherSource = "Try another source"
    static let tryAnotherSourceTitle = "Try another source?"
    static let tryAnotherSourceMessage = "Aurral won\u{2019}t use that copy again and looks for another."
    static let searchNow = "Search now"
    static func searchNowAll(_ n: Int) -> String { "Search now for \(n)" }
    static let unreachable = "Couldn\u{2019}t reach Aurral. Trying again\u{2026}"
    static let doneSymbol = "checkmark.circle"

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
        switch error as? AurralError {
        case .notHeldAnyMore?: "That song isn\u{2019}t waiting for you any more."
        case .runActive?: "Songs are still downloading there. Try again when they\u{2019}re done."
        default: DiscoverCopy.message(for: error)
        }
    }
}
