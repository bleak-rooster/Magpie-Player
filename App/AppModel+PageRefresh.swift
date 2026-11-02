import Foundation
import MagpieCore

/// Round 12 Y3 (plan item 4): pull to refresh on the artist, album and playlist pages. A pull forgets what the page
/// keeps (the artist's saved Popular, the cover's Immersive colours and its image in memory), asks the server for a
/// quick scan so new downloads are picked up, reloads the page at once, and once the scan says it's done (at most
/// `scanWait`) reloads it again. Offline it re-reads the phone's downloads. No path or other server data is kept.
extension AppModel {
    /// The longest a pull waits for the server's quick scan.
    nonisolated static let scanWait: Duration = .seconds(20)
    /// How often the scan is asked about meanwhile.
    nonisolated static let scanPoll: Duration = .seconds(1)

    /// What one pull did (tests).
    struct PageRefreshOutcome: Equatable {
        /// The server accepted the quick scan.
        var scanned: Bool
        /// The scan said it was done before `scanWait` ran out.
        var scanFinished: Bool
        var reloads: Int
    }

    /// Pull to refresh for a page: `reload` reads the page again (the page's own load, which also re-runs its Lidarr
    /// line and "Not in your library"). `artistId` names the artist page whose saved Popular goes; `coverArtIds` the
    /// covers whose colours and in-memory images go. `sleep` is injected by tests.
    @discardableResult
    func refreshPage(artistId: String? = nil, coverArtIds: [String?], reload: @MainActor () async -> Void,
                     sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
        async -> PageRefreshOutcome {
        forgetPageCaches(artistId: artistId, coverArtIds: coverArtIds.compactMap { $0 })
        guard !isOffline else {   // the phone's downloads, read again
            await reload()
            return PageRefreshOutcome(scanned: false, scanFinished: false, reloads: 1)
        }
        // A scan already under way (the owner's own): no second one and no wait, just the page again.
        if (try? await request({ try await $0.scanStatus() })) == true {
            await reload()
            return PageRefreshOutcome(scanned: false, scanFinished: false, reloads: 1)
        }
        let scanned = await startQuickScan()
        await reload()
        guard scanned else { return PageRefreshOutcome(scanned: false, scanFinished: false, reloads: 1) }
        let finished = await waitForScan(sleep: sleep)
        guard finished, !Task.isCancelled else { return PageRefreshOutcome(scanned: true, scanFinished: finished, reloads: 1) }
        await reload()   // what the scan found: new downloads, new tracks
        return PageRefreshOutcome(scanned: true, scanFinished: true, reloads: 2)
    }

    /// The artist's saved Popular, and each cover's Immersive colours and in-memory images. The cover on disk stays
    /// ("Reload artwork" is the way to fetch it again).
    func forgetPageCaches(artistId: String?, coverArtIds: [String]) {
        if let artistId, let scope = navidromeScope {
            PopularSongsCache(root: dataDirectory, scope: scope).save([], artistId: artistId)
        }
        for id in coverArtIds {
            ArtPaletteCache.shared.remove(id)
            if let memoryScope = artworkScope { ArtworkCache.shared.remove(scope: memoryScope, coverArtId: id) }
        }
    }

    /// A quick scan (`fullScan=false`) of the main library and Finds (every library while no main one is known);
    /// false when the server refused it (an account that isn't an admin) or didn't answer.
    private func startQuickScan() async -> Bool {
        let targets: [String]
        switch matchIndexLibraries {
        case .only(let ids): targets = ids.map { "\($0):" }
        case .all, .scoped: targets = []
        }
        do {
            try await request { try await $0.startScan(targets: targets) }
            return true
        } catch {
            return false
        }
    }

    /// Asks `getScanStatus` every `scanPoll` until it says it's done, for at most `scanWait`. True once it's done;
    /// false when it ran out of time, the answer failed, or the pull was cancelled.
    private func waitForScan(sleep: @escaping @Sendable (Duration) async throws -> Void) async -> Bool {
        var waited: Duration = .zero
        while waited < Self.scanWait {
            do { try await sleep(Self.scanPoll) } catch { return false }
            waited += Self.scanPoll
            guard let scanning = try? await request({ try await $0.scanStatus() }) else { return false }
            if !scanning { return true }
        }
        return false
    }
}
