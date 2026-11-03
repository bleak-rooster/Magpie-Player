import Foundation
import MagpieCore
import Playback

/// Round 13 item 7 (D64): playback's side of replacing a cached copy at the wrong quality (`DownloadManager+CacheQuality`).
extension AppModel {
    /// On each queue change: a held copy goes in once its song is no longer playing (or waiting in the engine), and a
    /// song that has just started playing from the cache is checked against the current network's quality.
    func cacheQualityQueueChanged(current: String?, currentChanged: Bool, manager: DownloadManager) {
        let target = currentStreamQuality
        manager.applyCacheSwap(target: target)
        guard currentChanged, let current, !isOffline else { return }
        manager.refreshCacheQuality(songId: current, target: target)
    }

    /// The stream quality for now changed (network, settings): work for the old target stops, and the playing song is
    /// checked against the new one.
    func cacheQualityTargetChanged() {
        guard let manager = downloads else { return }
        let target = currentStreamQuality
        manager.cacheTargetChanged(target)
        manager.applyCacheSwap(target: target)
        guard !isOffline, let current = player.queue.current?.song.id else { return }
        manager.refreshCacheQuality(songId: current, target: target)
    }
}
