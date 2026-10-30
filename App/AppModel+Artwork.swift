import Foundation
import MagpieCore
import UIKit

/// Artwork for the phone and the car (P4): memory first, then the cover saved with a download (Task 14), then the
/// disk cache, then the server, whose image is saved to the disk cache. A cached image costs no request, online or
/// offline; nothing is fetched again unless the owner reloads it.
extension AppModel {
    /// The account's artwork on disk.
    var artworkDisk: ArtworkDiskCache { ArtworkDiskCache.forRoot(dataDirectory) }

    func artworkImage(_ coverArtId: String, size: Int) async -> UIImage? {
        guard let memoryScope = artworkScope, let scope = navidromeScope else { return nil }
        let key = ArtworkCache.key(scope: memoryScope, coverArtId: coverArtId, size: size)
        let memory = ArtworkCache.shared
        if let hit = memory.cached(key) { return hit }
        let reloaded = ArtworkReloads.shared.version(coverArtId) > 0
        // The cover saved with a download: it shows offline and costs no request (unless reloaded while online).
        if !reloaded || isOffline, let file = localCoverURL(coverArtId),
           let saved = await Task.detached(priority: .utility, operation: {
               UIImage(contentsOfFile: file.path)?.preparingForDisplay()
           }).value {
            memory.store(saved, for: key)
            return saved
        }
        let disk = artworkDisk, generation = memory.generation
        if let data = await disk.data(scope: scope, coverArtId: coverArtId, size: size),
           let cached = await Task.detached(priority: .utility, operation: { UIImage(data: data)?.preparingForDisplay() }).value {
            guard memory.generation == generation else { return nil }   // signed out/in meanwhile
            memory.store(cached, for: key)
            return cached
        }
        guard let url = coverArtURL(coverArtId, size: size) else { return nil }   // offline: the placeholder
        var fetched: (data: Data, generation: Int)?
        let image = await memory.image(key: key, url: url) { fetched = ($0, $1) }
        if let fetched {   // saved before returning, so the next ask (or a relaunch) finds it on disk
            await disk.save(fetched.data, scope: scope, coverArtId: coverArtId, size: size, generation: fetched.generation)
        }
        return image
    }

    /// "Reload artwork" on an album, artist or playlist: its cached sizes go and it is fetched again.
    func reloadArtwork(_ coverArtId: String?) async {
        guard let coverArtId, let memoryScope = artworkScope, let scope = navidromeScope else { return }
        ArtworkCache.shared.remove(scope: memoryScope, coverArtId: coverArtId)
        await artworkDisk.remove(scope: scope, coverArtId: coverArtId)
        ArtworkReloads.shared.bump(coverArtId)
    }

    /// Settings › Downloads & Storage: "Artwork · 84 MB".
    var artworkUsage: Int64 { get async { await artworkDisk.usage() } }

    /// "Clear artwork cache" (confirmed first): what's on screen stays until it's next loaded.
    func clearArtworkCache() async {
        ArtworkCache.shared.removeAll()
        await artworkDisk.clear()
    }

    /// Sign-out: the account's artwork leaves the phone (as its downloads do). The memory cache is cleared first, so a
    /// fetch still in flight never writes into the erased scope.
    func eraseArtwork(scope: String?) {
        ArtworkCache.shared.removeAll()
        ArtworkReloads.shared.reset()
        guard let scope else { return }
        let disk = artworkDisk, generation = ArtworkCache.shared.generation
        Task { await disk.eraseScope(scope, generation: generation) }
    }
}
