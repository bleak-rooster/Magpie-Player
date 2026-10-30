import Foundation
import MagpieCore
import NavidromeKit
import Observation
import os
import Playback

/// Whether the app is offline, readable from any context: the stream URLs and the scrobble router ask on every use.
/// Written on the main actor when offline mode is applied.
final class OfflineBox: Sendable {
    private let lock: OSAllocatedUnfairLock<Bool>
    init(_ offline: Bool = false) { lock = OSAllocatedUnfairLock(initialState: offline) }
    var isOffline: Bool { lock.withLock { $0 } }
    func set(_ offline: Bool) { lock.withLock { $0 = offline } }
}

/// The bookkeeping behind Automatic offline mode (one object, so `AppModel` holds a single property for it).
@MainActor final class ReachabilityState {
    /// Offline, and forced On, as last applied to playback and downloads.
    var appliedOffline = false
    var appliedForced = false
    /// The probes that run while the server is suspect or unreachable.
    var probes: [Task<Void, Never>] = []
    /// Failed reconnects (each probes every address) since the server last answered, and when the first failed.
    var failures = 0
    var since: Date?
    /// The first probe after a failure comes after `suspectInterval`; later ones every `interval`.
    var suspectInterval: Duration = .seconds(5)
    var interval: Duration = .seconds(30)
    /// Controller ruling (a): a suspect server counts as unreachable after this long, or after 2 failed reconnects.
    var offlineAfter: TimeInterval = 10
    /// The last reconnect's login was refused (401/403): the server answers, the password doesn't work.
    var authRejected = false
    /// When a failed download last probed the server (fix round 3): at most one such probe per `suspectInterval`.
    var lastDownloadProbe: Date?

    var isSuspect: Bool { since != nil }
}

/// Offline mode (spec §6, Task 14). Automatic follows whether the server answers; On forces it; Off never goes
/// offline. While offline only songs on the phone play (downloads and cache), nothing is fetched, no original is
/// tried, files that fail are kept, Lidarr waits, and the screens show what's on the phone. Forced On sends nothing
/// at all: no request, stream, artwork, scrobble or probe.
///
/// Automatic doesn't go offline on one failure (ruling a): the server is suspect until it has been unreachable for
/// `offlineAfter` or 2 reconnects have failed. While suspect nothing is skipped; a song that failed is played again
/// when the server answers.
extension AppModel {
    nonisolated static let offlineCopy = "You're offline"
    /// The error `request` throws while Offline mode is On: a connection error, so callers treat it as unreachable.
    nonisolated static let forcedOfflineError = URLError(.notConnectedToInternet)

    var isOffline: Bool {
        switch preferences.downloads.offlineMode {
        case .on: true
        case .off: false
        case .automatic: !serverReachable
        }
    }

    /// Offline mode is On: nothing goes to the network.
    var isForcedOffline: Bool { preferences.downloads.offlineMode == .on }

    /// `request`'s gate: Offline mode On makes no request.
    func requireNotForcedOffline() throws {
        if isForcedOffline { throw Self.forcedOfflineError }
    }

    // MARK: - Reachability

    /// A reconnect probed every address and none answered: one more failure towards going offline.
    func reconnectFailed() {
        guard !isForcedOffline else { return }
        reachability.failures += 1
        reachability.authRejected = false   // a real outage now: "isn't answering", not the sign-in error
        downloads?.serverDropConfirmed()
        noteUnreachable()
    }

    /// The server didn't answer: it is suspect (probed after `suspectInterval`, then every `interval`, and as soon as
    /// the network comes back, until it answers). Automatic goes offline once it has been unreachable for
    /// `offlineAfter` or 2 reconnects have failed.
    func noteUnreachable() {
        guard session != nil, !isForcedOffline else { return }
        let r = reachability
        let wasSuspect = r.isSuspect
        let since = r.since ?? .now
        r.since = since
        if serverReachable, r.failures >= 2 || Date.now.timeIntervalSince(since) >= r.offlineAfter {
            serverReachable = false
        }
        if !wasSuspect { downloads?.networkChanged() }   // manual downloads wait for the server from now
        startProbes()
    }

    private func startProbes() {
        let r = reachability
        guard r.probes.isEmpty else { return }
        let network = self.network
        r.probes = [
            Task { [weak self, r] in
                var wait = r.suspectInterval
                while !Task.isCancelled {
                    try? await Task.sleep(for: wait)
                    wait = r.interval
                    guard !Task.isCancelled, let self else { return }
                    await self.checkReachability()
                }
            },
            Task { [weak self] in
                var wasConnected = network.status.isConnected
                for await status in Observations({ @MainActor in network.status }) {
                    defer { wasConnected = status.isConnected }
                    guard status.isConnected, !wasConnected, !Task.isCancelled else { continue }
                    await self?.checkReachability()
                }
            },
        ]
    }

    private func stopProbes() {
        reachability.probes.forEach { $0.cancel() }
        reachability.probes = []
    }

    /// The server answered (or there is no session to reach): back online, the probes stop, and what waited on it
    /// goes again: a song that failed while it was suspect, and downloads.
    func noteReachable() {
        let r = reachability
        let wasDown = r.isSuspect || !serverReachable
        stopProbes()
        r.failures = 0
        r.since = nil
        r.authRejected = false
        if !serverReachable { serverReachable = true }
        // Downloads that failed meanwhile count as attempts, and the rest go again.
        if wasDown || downloads?.hasAwaitingVerdict == true { downloads?.serverAnswered() }
        guard wasDown else { return }
        serverAnsweredGeneration += 1   // P5: Home reads what failed
        player.retryAfterFailure()
        drainScrobblesSoon()   // plays queued while it was down (T17)
    }

    /// A reconnect's login (fix round 2, B). A refusal (401/403) means the server answered: it is reachable, and
    /// `request` throws the sign-in error instead of going offline. Any other failure counts as a failed reconnect.
    func reconnectLogin(_ client: NavidromeClient, replacing old: NavidromeClient) async -> LoginResult? {
        do {
            let login = try await client.connect()
            reachability.authRejected = false
            return login
        } catch {
            guard session?.client === old else { return nil }   // signed out or in meanwhile
            if Self.isAuthRejection(error) {
                noteReachable()
                reachability.authRejected = true
            } else {
                reconnectFailed()
            }
            return nil
        }
    }

    nonisolated static func isAuthRejection(_ error: Error) -> Bool {
        switch error as? NavidromeError {
        case .badCredentials?: true
        case .http(let status)?: status == 401 || status == 403
        default: false
        }
    }

    /// `request` after a failed reconnect whose login was refused: the sign-in error, not the connection one.
    func rethrowAuthRejection() throws {
        if reachability.authRejected { throw NavidromeError.badCredentials }
    }

    /// A download couldn't connect (fix round 3): probe the server, at most once per `suspectInterval` and without
    /// logging in again while the session works. A failure inside that window marks the server suspect and waits for
    /// that probe's verdict, or the probe loop's.
    func downloadCouldNotConnect() {
        guard session != nil, !isForcedOffline else { return }
        let r = reachability
        let window = Double(r.suspectInterval.components.seconds) + Double(r.suspectInterval.components.attoseconds) / 1e18
        if let last = r.lastDownloadProbe, Date.now.timeIntervalSince(last) < window {
            noteUnreachable()
            return
        }
        r.lastDownloadProbe = .now
        Task { [weak self] in await self?.reconnect(rebuildAlways: false) }
    }

    /// Probes the session's addresses once. One that answers is moved to and logged in to afresh (a launch with no
    /// network never logged in, and stream URLs need it), which marks the server reachable. Nothing while forced On.
    func checkReachability() async {
        guard session != nil, !isForcedOffline else { return }
        await reconnect(rebuildAlways: true)
    }

    // MARK: - Applying offline mode

    /// Applies `isOffline` when it changed. Each of its inputs calls this (the reachability, the preference), so
    /// playback is right before anything else runs: offline only songs on the phone play, online every song does.
    func offlineInputsChanged() {
        let r = reachability
        let offline = isOffline, forced = isForcedOffline
        let leftForced = r.appliedForced && !forced
        r.appliedForced = forced
        if forced { stopProbes() }
        guard offline != r.appliedOffline else {
            if leftForced { restoreAfterOffline(reconnecting: true) }   // On to Off with the server reachable
            return
        }
        r.appliedOffline = offline
        offlineBox.set(offline)
        player.isPlayable = offline ? { [localFiles] in localFiles.hasFile($0.id) } : { _ in true }
        player.upcomingURLsChanged()
        downloads?.networkChanged()   // manual downloads wait while offline, pre-downloads stop; both go again after
        if forced {
            // On sends nothing: a song still streaming gives way to the next one on the phone, or pauses.
            player.stopUnplayableCurrent(message: Self.offlineCopy)
        }
        if offline {
            player.retryAfterFailure()   // a song that failed while the server was suspect: on to the next one here
        } else {
            restoreAfterOffline(reconnecting: leftForced)
        }
    }

    /// Back online (I4): what offline held back. Leaving On logs in first (nothing was sent while it was on).
    private func restoreAfterOffline(reconnecting: Bool) {
        Task { [weak self] in
            if reconnecting { await self?.checkReachability() }
            guard let self, !self.isOffline else { return }
            self.drainScrobblesSoon()
            self.pollRequests()
            Task { await self.refreshFinds() }
            Task { try? await self.refreshMatchIndex() }
            if self.madeForYouShelf.isEmpty { Task { await self.refreshMadeForYou() } }
            if self.lidarr != nil { Task { _ = await self.lidarrAudit() } }
        }
    }

    // MARK: - What's on the phone

    /// What's on the phone now (empty when signed out).
    var offlineCatalog: OfflineCatalog {
        get async {
            guard let store = downloads?.store else { return OfflineCatalog(entries: [], playlists: []) }
            return OfflineCatalog(entries: await store.entries(), playlists: await store.playlists())
        }
    }

    /// Where the cover saved with a download is (one per album or playlist), shown before asking the server. Not
    /// checked here: the caller reads it off the main actor, and a missing file reads as no image.
    func localCoverURL(_ coverArtId: String?) -> URL? {
        guard let coverArtId, let store = downloads?.store else { return nil }
        return store.coverPath(coverArtId: coverArtId)
    }

    /// The lock screen's artwork: offline only a cover saved on the phone (none if it isn't), online the server's.
    func nowPlayingArtworkURL(_ song: Song) -> URL? {
        isOffline ? localCoverURL(song.coverArtId) : coverArtURL(song.coverArtId, size: 600)
    }

    /// What offline pages load again on: the mode, and offline the songs on the phone (the store may only become
    /// readable after first unlock).
    var offlinePageKey: String { isOffline ? "offline|\(downloads?.localFiles.count ?? 0)" : "online" }
}
