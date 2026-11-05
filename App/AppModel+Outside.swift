import Foundation
import ListenBrainzKit
import MagpieCore
import Requests
import Search

/// R19: the outside artist and album pages. MusicBrainz through the app's one client (1 request/s, the app UA), read
/// into memory for this session only; Try this album and the per-track Try through the existing Try.
extension AppModel {
    var outsideCatalog: OutsideCatalog {
        if let outsideCatalogStore { return outsideCatalogStore }
        let catalog = OutsideCatalog(musicBrainz: musicBrainz)
        outsideCatalogStore = catalog
        return catalog
    }

    /// "Try this album": the existing Try aimed at the album's release group (into Finds when set up, otherwise straight
    /// into the library). A live request for that album is returned instead of a second one.
    func tryAlbum(_ firstTrack: ExternalRecording, releaseGroup: MBID,
                  intent: RequestRunner.Intent = .plain) async throws -> RequestID {
        try await startTry(firstTrack, album: releaseGroup, releaseGroup: nil, intent: intent)
    }

    /// A track of an outside album: the existing single-song Try, deduped against a live request for its album (R20).
    func tryTrack(_ recording: ExternalRecording, releaseGroup: MBID?,
                  intent: RequestRunner.Intent = .plain) async throws -> RequestID {
        try await startTry(recording, album: nil, releaseGroup: releaseGroup, intent: intent)
    }

    /// Round 15 C3 (D135, D139): `intent` is the menus' Try (`.trial`) or Add to library (`.library`).
    func startTry(_ recording: ExternalRecording, album: MBID?, releaseGroup: MBID?,
                  intent: RequestRunner.Intent = .plain) async throws -> RequestID {
        guard let runner else { throw RequestRunner.TryError.notSetUp }
        let id = try await runner.tryRecording(recording, tier: speedTier, album: album, releaseGroup: releaseGroup,
                                               intent: intent)
        if notifications { ReadyNotifier.shared.requestAuthorizationIfNeeded() }
        pollRequests()
        return id
    }

    /// The library song for an outside track, once the library has it (the match index, then the song itself).
    func librarySong(for recording: ExternalRecording) async -> Song? {
        guard let id = await matchIndex?.index.librarySong(for: recording) else { return nil }
        return try? await request { try await $0.song(id: id) }
    }
}
