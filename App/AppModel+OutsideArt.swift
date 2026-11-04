import Foundation
import LidarrKit
import ListenBrainzKit
import Requests
import MagpieCore
import SwiftUI
import UIKit

/// R15 / R16: artwork for music that isn't in the library yet (search's "Not in your library", the car's search, Try
/// and the request screens). Each result set or screen gets its own `OutsideArtLoader`, held in memory and dropped when
/// the results change or the screen closes. B1 (D122, owner): pictures that loaded are also kept on the phone (their
/// own folder, excluded from backup, removed on sign-out), never in the P4 artwork cache. In-library artwork keeps going
/// through `artworkImage` (P4).
extension AppModel {
    #if DEBUG
    /// Tests: outside artwork requests go here instead of the internet (G0).
    static var outsideArtTransportForTesting: HTTPTransport?
    #endif

    /// A loader for one result set or screen. Artists' pictures come from the connected Lidarr's lookup; without
    /// Lidarr they keep the placeholder. Offline (or Offline mode On) nothing is sent.
    /// B1 (D122): pictures that loaded are kept on the phone (`outsideArtDisk`) and shown at once next time; an album's
    /// cover falls back to a release's front, then the cover Lidarr's lookup names; every loader takes turns through
    /// one limiter (four at once).
    func makeOutsideArt(maxPixel: Int = 500, maxArtistLookups: Int = OutsideArtPolicy.maxArtistLookups) -> OutsideArtLoader {
        var transport: HTTPTransport = OutsideArtTransport()
        #if DEBUG
        if let testing = Self.outsideArtTransportForTesting { transport = testing }
        #endif
        let musicBrainz = musicBrainz
        return OutsideArtLoader(
            transport: transport, userAgent: MusicBrainzClient.userAgent(version: Self.marketingVersion),
            artistImage: { [weak self] mbid in
                guard let client = await self?.lidarrClient else { return nil }
                return try await client.artistLookup(mbid: mbid)?.pictureURL
            },
            isOffline: { [weak self] in self?.isOffline ?? true },
            maxPixel: maxPixel, maxArtistLookups: maxArtistLookups,
            covers: OutsideCoverFallbacks(
                releases: { rg in try await musicBrainz.officialReleases(releaseGroup: rg).map(\.id) },
                lidarrCover: { [weak self] rg in
                    guard let client = await self?.lidarrClient else { return nil }
                    return try await client.albumCoverURL(releaseGroup: rg)
                }),
            disk: outsideArtDisk, limiter: Self.outsideArtLimiter)
    }

    /// B1: outside pictures on the phone (`Application Support/Magpie/OutsideArt`), removed on sign-out.
    var outsideArtDisk: OutsideArtDiskCache { OutsideArtDiskCache(directory: OutsideArtDiskCache.directory(root: dataDirectory)) }

    /// B1: every outside picture load in the app takes a turn here (at most four at once).
    static let outsideArtLimiter = AsyncLimiter(limit: 4)

    /// B1 (owner item 4): the long-lived loader for recommended artists' circles (Library › Recommended, Home): the
    /// same picture the artist page shows, prefetched, kept on the phone, no per-page lookup cap.
    var recommendedArt: OutsideArtLoader {
        if let loader = recommendedArtSlot { return loader }
        let loader = makeOutsideArt(maxPixel: 360, maxArtistLookups: .max)
        recommendedArtSlot = loader
        return loader
    }

    /// B1: loads the pictures of `artists` (those with an MBID) a few at a time, so every circle has one when it shows.
    func prefetchArtistPictures(_ artists: [MBID]) async {
        guard !isOffline, lidarr != nil else { return }
        await recommendedArt.prefetch(artists.map(OutsideArtKey.artist))
    }

    /// Sign-out: the pictures go with the account.
    func forgetOutsideArt() {
        recommendedArtSlot?.reset()
        recommendedArtSlot = nil
        outsideArtDisk.removeAll()
    }

    /// R16: the library cover of a request that Navidrome now lists (its song's cover id), through the P4 cache.
    func readyCoverArtId(_ request: MagpieRequestCover) async -> String? {
        guard let songId = request.songId else { return nil }
        if let known = ReadyCovers.shared.ids[songId] { return known }
        guard let song = await librarySong(songId), let id = song.coverArtId else { return nil }   // a gone id: looked up again
        ReadyCovers.shared.ids[songId] = id
        return id
    }
}

extension MagpieRequest {
    var cover: MagpieRequestCover {
        MagpieRequestCover(songId: songId,
                           outside: .cover(releaseGroup: plan?.releaseGroupMBID, release: recording.releaseMBID),
                           artist: (plan?.artistMBID ?? recording.artistMBID).map(OutsideArtKey.artist))
    }
}

/// What a request screen needs to show its art.
struct MagpieRequestCover: Hashable {
    /// The library song once Navidrome lists it.
    var songId: String?
    /// Before then: the release group (once resolved) or the release search named.
    var outside: OutsideArtKey?
    /// Without a cover: the artist's picture (Lidarr's, from an allowed host), else the placeholder (fix round 1).
    var artist: OutsideArtKey? = nil
}

/// Ready songs' cover ids, so a request row doesn't ask the server for its song each time it shows. Ids only, never
/// images (those are in the P4 cache).
@MainActor
final class ReadyCovers {
    static let shared = ReadyCovers()
    var ids: [String: String] = [:]
}

/// Hands `content` the outside image for `key` once it has loaded (nil until then, and for good when there is none).
struct OutsideArtwork<Content: View>: View {
    let loader: OutsideArtLoader?
    let key: OutsideArtKey?
    var fallback: OutsideArtKey? = nil
    /// B1: bumped by a pull to refresh, so a picture that didn't load is asked for again.
    var attempt = 0
    @ViewBuilder let content: (Image?) -> Content
    /// The picture loaded, and for which key (a reused row never shows another key's picture).
    @State private var loaded: (key: OutsideArtKey?, image: CGImage)?

    init(_ loader: OutsideArtLoader?, key: OutsideArtKey?, fallback: OutsideArtKey? = nil, attempt: Int = 0,
         @ViewBuilder content: @escaping (Image?) -> Content) {
        self.loader = loader; self.key = key; self.fallback = fallback; self.attempt = attempt; self.content = content
    }

    var body: some View {
        // B1: a picture already on the phone shows at once, before the task runs.
        let shown = (loaded?.key == key ? loaded?.image : nil) ?? key.flatMap { loader?.cached($0) }
        content(shown.map { Image(decorative: $0, scale: 1) })
            .task(id: TaskKey(key: key, fallback: fallback, loader: loader.map(ObjectIdentifier.init), attempt: attempt)) {
                guard let loader else { loaded = nil; return }
                // A row scrolled away cancels this wait, not the load: the picture is kept for when it comes back. A
                // refresh that fails keeps the picture already shown.
                if let found = await loader.image(key, fallback: fallback) { loaded = (key, found) }
            }
    }

    private struct TaskKey: Equatable {
        var key: OutsideArtKey?
        var fallback: OutsideArtKey?
        var loader: ObjectIdentifier?
        var attempt: Int
    }
}

/// A request's art (R16): the library cover through P4 once Navidrome lists the song, otherwise the outside cover
/// (R15 rules), otherwise the placeholder.
struct RequestArtwork<Content: View>: View {
    @Environment(AppModel.self) private var model
    let cover: MagpieRequestCover
    let loader: OutsideArtLoader?
    let side: CGFloat
    @ViewBuilder let content: (Image?) -> Content
    @State private var coverArtId: String?

    var body: some View {
        Group {
            if let coverArtId {
                Artwork(coverArtId, side: side, content: content)
            } else {
                OutsideArtwork(loader, key: cover.outside, fallback: cover.artist, content: content)
            }
        }
        .task(id: cover.songId) { coverArtId = await model.readyCoverArtId(cover) }
    }
}
