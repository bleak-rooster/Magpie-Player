import AurralKit
import Foundation
import MagpieCore
import NavidromeKit

/// One Discover playlist's page (or a chart followed as one): its songs as Aurral lists them.
struct EditorialPage: Equatable, Sendable {
    var id: String
    var name: String
    var description: String?
    var curator: String?
    var artwork: AurralImage?
    var songs: [ChartSong]
    /// The user's synced playlist for it, once added (Aurral's `libraryPlaylistId`, else what Magpie added).
    var libraryPlaylistId: String?
}

/// Add flow's progress: the synced playlist's songs as Aurral's jobs say.
struct SyncedProgress: Equatable, Sendable {
    var total: Int
    var done: Int
    /// Songs that couldn't download (each with Retry).
    var failed: [AurralJob]

    init(jobs: [AurralJob]) {
        total = jobs.count
        done = jobs.filter { $0.status == "done" }.count
        failed = jobs.filter { $0.status == "failed" }
    }

    /// Songs still to come (neither in nor failed).
    var waiting: Int { max(0, total - done - failed.count) }
}

/// Round 14 A4 (owner answers 1 and 10, D94): the Discover playlists (Aurral's editorial playlists) and Add flow.
///
/// - Add flow is the one write: `POST /api/discover/editorial/:id/library`, only on the owner's tap, and only for a
///   user with accessFlow (`aurralCanAddFlow`; hidden otherwise). Aurral makes a synced playlist, queues every song
///   through its own download sources and publishes it to Navidrome. Magpie starts nothing else and sends no Lidarr
///   write for it (owner answer 10): it only reads the progress (`GET /api/playlists/jobs/:id`), every 30 s while the
///   page is open.
/// - Without a download source, Add flow says so first; the flow then waits for a downloader rather than spinning.
/// - A song that couldn't download offers Retry (Aurral's re-search); a flow made with auto-download off offers
///   Download songs.
/// - Once added, the playlist joins Your flows as its songs arrive (D75 amended: synced playlists are Discover's).
extension AppModel {
    /// The Discover playlist's songs.
    func editorialPage(id: String) async throws -> EditorialPage {
        guard let client = aurralClient, !isOffline else { throw AurralError.signInNeeded }
        do {
            let p = try await client.editorialPlaylist(id)
            return EditorialPage(id: p.id, name: p.name, description: p.description, curator: p.curator, artwork: p.artwork,
                                 songs: p.tracks.map(ChartSong.init),
                                 libraryPlaylistId: p.libraryPlaylistId ?? aurralFeeds.added[id])
        } catch {
            noteAurralError(error)
            throw error
        }
    }

    /// Add flow (after the no-downloader explanation, when there is none): the synced playlist's id.
    func addFlow(deezerPlaylistId id: String) async throws -> AurralEditorialAddResult {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard aurralCanAddFlow, let client = aurralClient else { throw AurralError.notPermitted }
        let result = try await client.addEditorialPlaylist(id)
        aurralFeeds.noteAdded(id, as: result.playlistId)
        // Fix round 1 (M8): "Adding…" ends when the server answers; Your flows reads again behind it (the playlist joins
        // as the server creates and publishes it).
        Task { [weak self] in
            await self?.refreshDiscover(force: true)
            self?.homeFeedSlot?.sectionsChanged([.discover])
        }
        return result
    }

    /// The synced playlist's progress (nil: Aurral doesn't know it, or this user may not read it).
    func syncedProgress(playlistId: String) async -> SyncedProgress? {
        guard let client = aurralClient, !isOffline else { return nil }
        do {
            guard let jobs = try await client.playlistJobs(playlistId) else { return nil }
            return SyncedProgress(jobs: jobs)
        } catch {
            noteAurralError(error)
            return nil
        }
    }

    /// Retry a song that couldn't download (Aurral searches for it again).
    func retrySong(playlistId: String, job: AurralJob) async throws {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard aurralCanAddFlow, let client = aurralClient else { throw AurralError.notPermitted }
        _ = try await client.retrySong(playlistId: playlistId, jobId: job.id)
    }

    /// Download songs, for a flow made with auto-download off. Throws `noDownloader` without a download source.
    func downloadFlowSongs(flowId: String) async throws {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard aurralCanAddFlow, let client = aurralClient else { throw AurralError.notPermitted }
        _ = try await client.downloadFlow(flowId)
        await refreshDiscoverStatus()
    }

    /// How long a just-added playlist may stay queued on the server before the page stops asking (fix round 1, I1).
    nonisolated static let addFlowSetUpLimit: TimeInterval = 10 * 60

    /// Add flow's state on a page (fix round 1, I1). Hidden without accessFlow (nothing can be read or sent); Add flow;
    /// Adding…; then, once added: **Setting up** while the server hasn't created it yet (2.13 queues the creation: it
    /// isn't listed and its songs answer 404), **Still setting up** after `addFlowSetUpLimit`; Downloading 12/40 (or
    /// Waiting for a downloader); **In your flows** only once the server lists it with its songs, all in or failed.
    nonisolated static func addFlowPhase(canAdd: Bool, adding: Bool, playlistId: String?, listed: Bool,
                                         progress: SyncedProgress?, hasDownloader: Bool?,
                                         settingUpFor: TimeInterval?) -> AddFlowPhase {
        if adding { return .adding }
        guard canAdd else { return .hidden }
        guard playlistId != nil else { return .ready }
        guard listed, let progress, progress.total > 0 else {
            return (settingUpFor ?? .infinity) < addFlowSetUpLimit ? .preparing : .stillSettingUp
        }
        guard progress.waiting > 0 else { return .inYourFlows }
        return hasDownloader == false ? .waitingForDownloader : .downloading(done: progress.done, total: progress.total)
    }

    /// The state now: the server's status (is it listed yet?) and its songs, read fresh.
    func addFlowState(playlistId: String?) async -> AddFlowPhase {
        guard let playlistId else {
            return Self.addFlowPhase(canAdd: aurralCanAddFlow, adding: false, playlistId: nil, listed: false, progress: nil,
                                     hasDownloader: aurralHasDownloader, settingUpFor: nil)
        }
        guard aurralCanAddFlow else { return .hidden }
        await refreshDiscoverStatus()
        let listed = discover.status?.sharedPlaylists.contains { $0.id == playlistId } ?? false
        let progress = listed ? await syncedProgress(playlistId: playlistId) : nil
        let since = aurralFeeds.addedAt[playlistId].map { aurralFeeds.now().timeIntervalSince($0) }
        return Self.addFlowPhase(canAdd: true, adding: false, playlistId: playlistId, listed: listed, progress: progress,
                                 hasDownloader: aurralHasDownloader, settingUpFor: since)
    }

    /// Follows a just-added (or downloading) playlist while its page is open: the state every `every` (30 s on screen)
    /// until it is in your flows, still not set up after the limit, or hidden. Cancelled with the page.
    func followAddFlow(playlistId: String, every: Duration = .seconds(30),
                       onPhase: @MainActor (AddFlowPhase) -> Void) async {
        while !Task.isCancelled {
            let phase = await addFlowState(playlistId: playlistId)
            onPhase(phase)
            switch phase {
            case .preparing, .downloading, .waitingForDownloader: break
            default: return
            }
            do { try await Task.sleep(for: every) } catch { return }
        }
    }
}

extension AppModel {
    /// Your flows' For you tiles on Home, after the owner's flows: from the saved copy at once; read (at most
    /// `discoverWait`) only when there is none yet, so Home is never held up.
    func forYouOnHome(limit: Int) async -> [HomeOutsideItem] {
        guard limit > 0, !isOffline, let feeds = aurralFeeds, feeds.can.editorial else { return [] }
        final class Done { var value = false }
        let done = Done()
        Task { await feeds.refresh(.editorial); done.value = true }
        // Polls the read rather than awaiting it (as `refreshDiscover(waitingAtMost:)`), so no wait outlives the limit;
        // with a saved copy, not at all.
        let deadline = ContinuousClock.now.advanced(by: Self.discoverWait)
        while !feeds.has(.editorial), !done.value, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        return Array(feeds.forYouTiles.prefix(limit))
    }
}

enum AddFlowPhase: Equatable, Sendable {
    case hidden, ready, adding, preparing, stillSettingUp, downloading(done: Int, total: Int), waitingForDownloader,
         inYourFlows

    var label: String? {
        switch self {
        case .hidden: nil
        case .ready: DiscoverPagesCopy.addFlow
        case .adding: DiscoverPagesCopy.adding
        case .preparing: DiscoverPagesCopy.settingUp
        case .stillSettingUp: DiscoverPagesCopy.stillSettingUp
        case .downloading(let done, let total): DiscoverPagesCopy.downloading(done, total)
        case .waitingForDownloader: DiscoverPagesCopy.waitingForDownloader
        case .inYourFlows: DiscoverPagesCopy.inYourFlows
        }
    }

    /// Each state its own symbol, always beside its words (D3: never a shape alone).
    var symbol: String {
        switch self {
        case .hidden, .ready: "plus.circle"
        case .adding, .preparing: "clock"
        case .stillSettingUp: "clock.badge.exclamationmark"
        case .downloading: "arrow.down.circle.dotted"
        case .waitingForDownloader: "hourglass"
        case .inYourFlows: "checkmark.circle"
        }
    }
}

/// Discover, Trending and Recommended's words (design language §5: about music; never the server's name).
enum DiscoverPagesCopy {
    static let forYou = "For you"
    static let browseMore = "Browse more playlists"
    static let trending = "Trending"
    static let recommended = "Recommended"
    static let addFlow = "Add flow"
    static let adding = "Adding\u{2026}"
    static func downloading(_ done: Int, _ total: Int) -> String { "Downloading \(done)/\(total)" }
    static let waitingForDownloader = "Waiting for a downloader"
    static let inYourFlows = "In your flows"
    static let settingUp = "Setting up\u{2026}"
    static let stillSettingUp = "Still setting up. Check back later."
    static let couldntDownloadSymbol = "exclamationmark.triangle"
    static let noDownloaderTitle = "No downloader set up"
    static let noDownloader = "Songs already in your library will appear; others can\u{2019}t be downloaded until a downloader is set up on your server."
    static let couldntDownload = "Couldn\u{2019}t download"
    static let retry = "Retry"
    static let downloadSongs = "Download songs"
    static let updating = "Updating\u{2026} Check back in a little while."
    static let notReady = "Not ready yet. Check back later."
    static let couldntUpdate = "Couldn\u{2019}t update just now. Showing the last copy."
    /// A country's name in the phone's language (never a hard-coded one).
    static func regionName(_ code: String) -> String { Locale.current.localizedString(forRegionCode: code) ?? code }
    static func topSongs(region: String?) -> String { region.map { "\(topSongs) \u{00B7} \(regionName($0))" } ?? topSongs }
    static func topAlbums(region: String?) -> String { region.map { "\(topAlbums) \u{00B7} \(regionName($0))" } ?? topAlbums }
    static func showingServer(region: String) -> String { "Showing \(regionName(region)) charts" }
    static let chartsCountry = "Charts country"
    static let chartsAutomatic = "Automatic"
    static let chartsAutomaticNote = "Your phone\u{2019}s region, when it has a chart"
    static let chartsServer = "Your server\u{2019}s region"
    static let worldwide = "Worldwide"
    static let topSongs = "Top songs"
    static let topAlbums = "Top albums"
    static let topArtists = "Top artists"
    static let chartsByGenre = "Charts by genre"
    static let popularPlaylists = "Popular playlists"
    static let numberOne = "No. 1"
    static func daysAtTop(_ n: Int) -> String { n == 1 ? "1 day at No. 1" : "\(n) days at No. 1" }
    static let topPick = "Top pick"
    static let newThisWeek = "New this week"
    static let closeToHome = "Close to home"
    static let furtherOut = "Further out"
    static let all = "All"
    static let notForMe = "Not for me"
    static let sortRank = "Rank"
    static let sortName = "Name"
    static let sortFirstSeen = "First seen"
    static func becauseYouLike(_ seed: String) -> String { "Because you like \(seed)" }
    static func songs(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }
    static func curated(by curator: String) -> String { "By \(curator)" }
    static let new = "NEW"
    static func movement(_ m: ChartSong.Movement) -> (text: String, label: String)? {
        switch m {
        case .up(let n): ("\u{25B2}\(n)", "Up \(n)")
        case .down(let n): ("\u{25BC}\(n)", "Down \(n)")
        case .new: (new, "New this week")
        case .same: nil
        }
    }
}
