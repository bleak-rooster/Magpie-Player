import Foundation
import MagpieCore
import Playback
import Synchronization
#if os(iOS)
import UIKit
#endif

/// Downloads for the signed-in account (spec §6): one `AudioStore` and one `DownloadManager` per server scope,
/// built at sign-in and erased at sign-out.
extension AppModel {
    /// Builds the store and manager for this session's scope (the app's own hex id, never a server string). A
    /// manager stopped just before (a sign-out, a sign-in over a session) finishes its teardown first.
    func startDownloads() {
        stopDownloads(erase: false)
        guard let scope = navidromeScope else { return }
        let store = AudioStore(root: dataDirectory, scope: scope,
                               isProtectedDataAvailable: ProtectedDataSnapshot.shared.isAvailable)
        let manager = DownloadManager(
            store: store, fetcher: audioFetcher, network: network,
            preferences: { [weak self] in self?.preferences.downloads ?? .defaultValue },
            url: { [weak self] song, quality in
                self?.session?.client.streamURL(songId: song.id, maxBitRate: quality.maxBitRate, format: quality.format)
            },
            coverURL: { [weak self] id in self?.coverArtURL(id, size: DownloadManager.coverSize) })
        downloads = manager
        manager.begin(after: downloadsTeardown)
        if preferences.downloads.keepFavourites { keepFavouritesChanged() }
    }

    /// Stops the manager: nothing new starts, and the work in flight is cancelled and waited for before anything
    /// else touches the scope. `erase` (sign-out) then removes all of the scope's audio. The next manager starts
    /// after this teardown, so a late completion never lands in the next account's scope (or in this one, re-made).
    func stopDownloads(erase: Bool) {
        favouritesSync?.cancel()
        favouritesSync = nil
        guard let old = downloads else { return }
        downloads = nil
        old.cancelAll()
        let previous = downloadsTeardown
        downloadsTeardown = Task {
            await previous?.value
            await old.cancelAllAndSettle()
            if erase { await old.store.eraseScope() }
        }
    }

    func download(_ songs: [Song], reason: DownloadReason, playlist: DownloadedPlaylist? = nil, coverArtId: String? = nil) {
        downloads?.download(songs, reason: reason, playlist: playlist, coverArtId: coverArtId)
    }

    func removeDownload(_ reason: DownloadReason) async {
        await downloads?.remove(reason)
    }

    /// A song's "Remove download": it leaves the phone, whatever it was downloaded with.
    func removeSongDownload(_ songId: String) async {
        await downloads?.remove(songIds: [songId])
    }

    /// "Try again": what failed, waits for Wi-Fi or was stopped by "Downloads are full" is queued again.
    func retryDownloads() { downloads?.retryWaiting() }

    func downloadStatus(_ songIds: [String]) -> DownloadStatus {
        downloads?.status(for: songIds) ?? .none
    }

    /// A downloaded playlist opened with a connection: songs added since are downloaded, songs taken out lose the
    /// playlist (and leave the phone unless something else keeps them). A playlist that isn't downloaded is left be.
    func refreshDownloadedPlaylist(_ playlist: Playlist, songs: [Song]) async {
        guard let downloads,
              let saved = await downloads.store.playlists().first(where: { $0.id == playlist.id }),
              self.downloads === downloads else { return }
        let ids = songs.map(\.id)
        guard saved.songIds != ids || saved.name != playlist.name || saved.coverArtId != playlist.coverArtId else { return }
        let kept = Set(ids), before = Set(saved.songIds)
        await downloads.remove(.playlist(playlist.id), songIds: saved.songIds.filter { !kept.contains($0) })
        guard self.downloads === downloads else { return }
        let snapshot = DownloadedPlaylist(id: playlist.id, name: playlist.name, coverArtId: playlist.coverArtId,
                                          songIds: ids, savedAt: .now)
        downloads.download(songs.filter { !before.contains($0.id) }, reason: .playlist(playlist.id), playlist: snapshot,
                           coverArtId: playlist.coverArtId)
    }

    /// "Keep favourites downloaded": on downloads every starred song (and lets go of songs no longer starred); off
    /// removes the favourites reason.
    func setKeepFavourites(_ on: Bool) async {
        guard let downloads else { return }
        guard on else { return await downloads.remove(.favourites) }
        let starred: [Song]
        do {
            starred = try await request { try await $0.starred() }.songs
        } catch {
            Log.logger("downloads").error("favourites failed: \(Log.category(of: error), privacy: .public)")
            return
        }
        guard !Task.isCancelled, self.downloads === downloads else { return }   // turned off, or signed out
        let ids = Set(starred.map(\.id))
        let gone = await downloads.store.entries()
            .filter { $0.reasons.contains(.favourites) && !ids.contains($0.songId) }.map(\.songId)
        await downloads.remove(.favourites, songIds: gone)
        guard !Task.isCancelled, self.downloads === downloads else { return }
        downloads.download(starred, reason: .favourites)
    }

    /// The preference changed (or a session started with it on): the latest setting wins.
    func keepFavouritesChanged() {
        favouritesSync?.cancel()
        let on = preferences.downloads.keepFavourites
        favouritesSync = Task { [weak self] in await self?.setKeepFavourites(on) }
    }

    /// "Re-download at new quality": every download not at the download quality is fetched again and swapped in.
    func redownloadAtCurrentQuality() async {
        guard let downloads else { return }
        let quality = preferences.downloads.quality
        let ids = await downloads.store.entries()
            .filter { $0.kind == .download && $0.quality != quality }.map(\.songId).sorted()
        downloads.redownload(songIds: ids, quality: quality)
    }

    func removeAllDownloads() async { await downloads?.removeAllDownloads() }

    func clearCache() async { await downloads?.clearCache() }

    var storageUsage: AudioUsage {
        get async { await downloads?.store.usage() ?? AudioUsage(downloadBytes: 0, cacheBytes: 0) }
    }
}

/// UIApplication's `isProtectedDataAvailable`, readable from any thread: the audio store asks from its own actor.
/// Kept current from the protected-data notifications.
final class ProtectedDataSnapshot: Sendable {
    @MainActor static let shared = ProtectedDataSnapshot()

    private let available: Mutex<Bool>

    @MainActor private init() {
        #if os(iOS)
        available = Mutex(UIApplication.shared.isProtectedDataAvailable)
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil,
                               queue: nil) { [weak self] _ in self?.set(true) }
        _ = center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil,
                               queue: nil) { [weak self] _ in self?.set(false) }
        #else
        available = Mutex(true)
        #endif
    }

    /// For `AudioStore(isProtectedDataAvailable:)`.
    var isAvailable: @Sendable () -> Bool { { [self] in available.withLock { $0 } } }

    private func set(_ value: Bool) { available.withLock { $0 = value } }
}
