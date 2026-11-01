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
    ///
    /// `stopDownloads(erase: false)` keeps the old scope's files: signing in over a session to the same account
    /// keeps its downloads. Another scope left on disk (a sign-out cut short by the app being killed, an earlier
    /// account) is removed by the sweep here, before the new manager starts.
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
            coverURL: { [weak self] id in self?.coverArtURL(id, size: DownloadManager.coverSize) },
            // Manual downloads also wait while the server is suspect (Task 14): they'd only fail.
            isOffline: { [weak self] in self.map { $0.isOffline || $0.reachability.isSuspect } ?? false },
            backgroundFetcher: backgroundAudioFetcher)
        downloads = manager
        // R1: a launch for the background session's events stores what they delivered before the system is told.
        (backgroundAudioFetcher as? BackgroundAudioFetcher)?.onEventsFinished = { @MainActor [weak self] in
            await self?.downloads?.deliveriesSettled()
        }
        applyLaunchPresence(to: manager)   // P1: a launch in the background starts held
        // Task 13: songs on the phone play from it; one that lands or leaves re-sends the songs after the current one.
        manager.onLocalFilesChanged = { [weak self, weak manager] in
            guard let self, let manager, self.downloads === manager else { return }
            self.localFiles.set(manager.localFiles)
            self.player.upcomingURLsChanged()
            self.preDownloadLanded()
        }
        // A download couldn't connect: probe the server, so the failure counts as a drop or as an attempt.
        manager.onUnreachable = { [weak self] in self?.downloadCouldNotConnect() }
        let previous = downloadsTeardown, root = dataDirectory
        let ready = Task {
            await previous?.value
            await Task.detached { AppModel.sweepAudioScopes(root: root, keeping: scope) }.value
        }
        downloadsTeardown = ready
        manager.begin(after: ready)
        watchQueueForPreDownload()
        if preferences.downloads.keepFavourites { keepFavouritesChanged() }
    }

    /// Stops the manager: nothing new starts, and the work in flight is cancelled and waited for before anything
    /// else touches the scope. `erase` (sign-out) then removes all of the scope's audio. The next manager starts
    /// after this teardown, so a late completion never lands in the next account's scope (or in this one, re-made).
    func stopDownloads(erase: Bool) {
        favouritesSync?.cancel()
        favouritesSync = nil
        preDownloadWatch?.cancel()
        preDownloadWatch = nil
        preDownloadSnapshot = nil
        cacheEviction?.cancel()
        cacheEviction = nil
        let upkeep = cacheUpkeep
        upkeep?.cancel()
        cacheUpkeep = nil
        // R1, sign-out: the background session is invalidated (its tasks cancelled), and made again when next needed.
        if erase { backgroundAudioFetcher?.invalidate() }
        guard let old = downloads else { return }
        downloads = nil
        localFiles.set([:])
        old.cancelAll()
        let previous = downloadsTeardown
        downloadsTeardown = Task {
            await previous?.value
            await upkeep?.value
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

    /// Removes every audio scope folder under `<root>/Magpie/Audio` but `scope`. Only names a scope can have are
    /// touched, and symbolic links (to or below the folder) are never followed or removed.
    nonisolated static func sweepAudioScopes(root: URL, keeping scope: String) {
        let fm = FileManager.default
        let magpie = root.appending(path: "Magpie", directoryHint: .isDirectory)
        let audio = magpie.appending(path: "Audio", directoryHint: .isDirectory)
        func isRealDirectory(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return false }
            return values.isSymbolicLink != true && values.isDirectory == true
        }
        guard isRealDirectory(magpie), isRealDirectory(audio),
              let names = try? fm.contentsOfDirectory(atPath: audio.path) else { return }
        for name in names where name != scope && name.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil {
            let folder = audio.appending(path: name, directoryHint: .isDirectory)
            guard isRealDirectory(folder) else { continue }
            try? fm.removeItem(at: folder)   // removes links inside it, never what they point to
        }
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

    /// An album's or playlist's status: only songs downloaded with `reason` count.
    func downloadStatus(_ songIds: [String], reason: DownloadReason) -> DownloadStatus {
        downloads?.status(for: songIds, reason: reason) ?? .none
    }

    /// "3 of 12 songs are already on this phone" under an album or playlist not downloaded as such; nil when none.
    func alreadyOnPhoneNote(_ songIds: [String], reason: DownloadReason) -> String? {
        let count = downloads?.onPhoneForOtherReasons(songIds, reason: reason) ?? 0
        guard count > 0 else { return nil }
        switch downloadStatus(songIds, reason: reason) {
        case .none, .partial: break
        default: return nil
        }
        return "\(count) of \(songIds.count) songs are already on this phone"
    }

    /// What "Remove download" confirms about a song kept for more than itself; nil when nothing to add.
    func songRemovalNote(_ songId: String) -> String? {
        let reasons = downloads?.reasons(for: songId) ?? []
        if reasons.contains(.favourites), preferences.downloads.keepFavourites {
            return "It's a favourite, so it'll come back while Keep favourites downloaded is on."
        }
        // "also" only when the song was downloaded on its own too.
        let also = reasons.contains(.song) ? "also " : ""
        if reasons.contains(where: { if case .album = $0 { true } else { false } }) {
            return "It's \(also)part of a downloaded album; removing it here takes it off this phone."
        }
        if reasons.contains(where: { if case .playlist = $0 { true } else { false } }) {
            return "It's \(also)part of a downloaded playlist; removing it here takes it off this phone."
        }
        if reasons.contains(where: { if case .artist = $0 { true } else { false } }) {
            return "It's \(also)part of an artist's downloaded songs; removing it here takes it off this phone."
        }
        return nil
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

    /// A song was starred or unstarred: with "Keep favourites downloaded" on, the favourites sync runs once the
    /// starring has paused for `favouritesDebounce` (a run of stars costs one sync).
    func favouriteStarChanged() {
        guard preferences.downloads.keepFavourites, downloads != nil else { return }
        favouritesSync?.cancel()
        let delay = favouritesDebounce
        favouritesSync = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self?.preferences.downloads.keepFavourites == true else { return }
            await self?.setKeepFavourites(true)
        }
    }

    /// "Re-download in this format": every download not at the download quality is fetched again and swapped in.
    func redownloadAtCurrentQuality() async {
        guard let downloads else { return }
        let quality = preferences.downloads.quality
        let ids = await downloads.store.entries()
            .filter { $0.kind == .download && $0.quality != quality }.map(\.songId).sorted()
        downloads.redownload(songIds: ids, quality: quality)
    }

    /// Also turns off "Keep favourites downloaded", or the favourites would come straight back.
    func removeAllDownloads() async {
        if preferences.downloads.keepFavourites { updatePreferences { $0.downloads.keepFavourites = false } }
        favouritesSync?.cancel()
        favouritesSync = nil
        await downloads?.removeAllDownloads()
    }

    func clearCache() async { await downloads?.clearCache() }

    var storageUsage: AudioUsage {
        get async { await downloads?.store.usage() ?? AudioUsage(downloadBytes: 0, cacheBytes: 0) }
    }
}

/// UIApplication's `isProtectedDataAvailable`, readable from any thread: the audio store asks from its own actor.
/// Kept current from the protected-data notifications.
final class ProtectedDataSnapshot: Sendable {
    #if os(iOS)
    @MainActor static let shared = ProtectedDataSnapshot(notifications: .default,
                                                         initial: UIApplication.shared.isProtectedDataAvailable)
    #endif

    private let available: Mutex<Bool>
    private let center: NotificationCenter
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(notifications center: NotificationCenter, initial: Bool) {
        available = Mutex(initial)
        self.center = center
        #if os(iOS)
        observers = [
            center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil,
                               queue: nil) { [weak self] _ in self?.set(true) },
            center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil,
                               queue: nil) { [weak self] _ in self?.set(false) },
        ]
        #endif
    }

    deinit { observers.forEach(center.removeObserver) }

    /// For `AudioStore(isProtectedDataAvailable:)`.
    var isAvailable: @Sendable () -> Bool { { [self] in available.withLock { $0 } } }

    private func set(_ value: Bool) { available.withLock { $0 = value } }
}
