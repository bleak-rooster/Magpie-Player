import Foundation
import MagpieCore
import Observation
import os
import Playback

/// Whether the app is offline, readable from any context: the stream URLs ask on every build. Written on the main
/// actor when offline mode is applied.
final class OfflineBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var isOffline: Bool { lock.withLock { $0 } }
    func set(_ offline: Bool) { lock.withLock { $0 = offline } }
}

/// Offline mode (spec §6, Task 14). Automatic follows whether the server answers; On forces it; Off never goes
/// offline. While offline only songs on the phone play (downloads and cache), nothing is fetched, no original is
/// tried, files that fail are kept, Lidarr waits, and the screens show what's on the phone.
extension AppModel {
    nonisolated static let offlineCopy = "You're offline"

    var isOffline: Bool {
        switch preferences.downloads.offlineMode {
        case .on: true
        case .off: false
        case .automatic: !serverReachable
        }
    }

    /// The server didn't answer: Automatic goes offline, and the server is probed every `reachabilityInterval` and as
    /// soon as the network comes back, until it answers.
    func noteUnreachable() {
        if serverReachable { serverReachable = false }
        guard reachabilityProbes.isEmpty, session != nil else { return }
        let interval = reachabilityInterval, network = self.network
        reachabilityProbes = [
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
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

    /// The server answered (or there is no session to reach): back online, and the probes stop.
    func noteReachable() {
        reachabilityProbes.forEach { $0.cancel() }
        reachabilityProbes = []
        if !serverReachable { serverReachable = true }
    }

    /// Probes the session's addresses once. One that answers is moved to and logged in to afresh (a launch with no
    /// network never logged in, and stream URLs need it), which marks the server reachable.
    func checkReachability() async {
        guard session != nil else { return }
        await reconnect(rebuildAlways: true)
    }

    /// Applies `isOffline` when it changed. Each of its inputs calls this (the reachability, the preference), so
    /// playback is right before anything else runs: offline only songs on the phone play, online every song does.
    func offlineInputsChanged() {
        let offline = isOffline
        guard offline != appliedOffline else { return }
        appliedOffline = offline
        offlineBox.set(offline)
        player.isPlayable = offline ? { [localFiles] in localFiles.hasFile($0.id) } : { _ in true }
        player.upcomingURLsChanged()
        downloads?.networkChanged()   // manual downloads wait while offline, and go again after
        if !offline { pollRequests() }
    }

    /// What's on the phone now (empty when signed out).
    var offlineCatalog: OfflineCatalog {
        get async {
            guard let store = downloads?.store else { return OfflineCatalog(entries: [], playlists: []) }
            return OfflineCatalog(entries: await store.entries(), playlists: await store.playlists())
        }
    }

    /// The cover saved with a download (one per album or playlist), shown before asking the server.
    func localCoverURL(_ coverArtId: String?) -> URL? {
        guard let coverArtId, let store = downloads?.store else { return nil }
        return store.savedCoverURL(coverArtId: coverArtId)
    }
}
