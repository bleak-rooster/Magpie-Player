import Foundation
import LidarrKit
import ListenBrainzKit
import Requests
import MagpieCore
import SwiftUI
import UIKit

/// R15 / R16: artwork for music that isn't in the library yet (search's "Not in your library", the car's search, Try
/// and the request screens). Never cached: each result set or screen gets its own `OutsideArtLoader`, held in memory
/// and dropped when the results change or the screen closes. Nothing reaches the disk, the P4 artwork cache or the
/// backup. In-library artwork keeps going through `artworkImage` (P4).
extension AppModel {
    #if DEBUG
    /// Tests: outside artwork requests go here instead of the internet (G0).
    static var outsideArtTransportForTesting: HTTPTransport?
    #endif

    /// A loader for one result set or screen. Artists' pictures come from the connected Lidarr's lookup; without
    /// Lidarr they keep the placeholder. Offline (or Offline mode On) nothing is sent.
    func makeOutsideArt(maxPixel: Int = 500) -> OutsideArtLoader {
        var transport: HTTPTransport = OutsideArtTransport()
        #if DEBUG
        if let testing = Self.outsideArtTransportForTesting { transport = testing }
        #endif
        return OutsideArtLoader(
            transport: transport, userAgent: MusicBrainzClient.userAgent(version: Self.marketingVersion),
            artistImage: { [weak self] mbid in
                guard let client = await self?.lidarrClient else { return nil }
                return try await client.artistLookup(mbid: mbid)?.pictureURL
            },
            isOffline: { [weak self] in self?.isOffline ?? true },
            maxPixel: maxPixel)
    }

    /// R16: the library cover of a request that Navidrome now lists (its song's cover id), through the P4 cache.
    func readyCoverArtId(_ request: MagpieRequestCover) async -> String? {
        guard let songId = request.songId else { return nil }
        if let known = ReadyCovers.shared.ids[songId] { return known }
        guard let song = try? await self.request({ try await $0.song(id: songId) }), let id = song.coverArtId else { return nil }
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
    @ViewBuilder let content: (Image?) -> Content
    @State private var image: CGImage?

    init(_ loader: OutsideArtLoader?, key: OutsideArtKey?, fallback: OutsideArtKey? = nil,
         @ViewBuilder content: @escaping (Image?) -> Content) {
        self.loader = loader; self.key = key; self.fallback = fallback; self.content = content
    }

    var body: some View {
        content(image.map { Image(decorative: $0, scale: 1) })
            .task(id: TaskKey(key: key, fallback: fallback, loader: loader.map(ObjectIdentifier.init))) {
                guard let loader else { image = nil; return }
                image = await loader.image(key, fallback: fallback)
            }
    }

    private struct TaskKey: Equatable {
        var key: OutsideArtKey?
        var fallback: OutsideArtKey?
        var loader: ObjectIdentifier?
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
