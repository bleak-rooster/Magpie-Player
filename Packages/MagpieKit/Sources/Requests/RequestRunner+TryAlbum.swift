import Foundation
import ListenBrainzKit
import MagpieCore

/// Round 15 C3 (owner item 6, D135): which release a song brings in, said before anything is sent. Reads only.
extension RequestRunner {
    public enum TargetPreview: Sendable, Equatable {
        /// An artist in Lidarr: the smallest release its listing has that holds the song.
        case listed(title: String, isAlbum: Bool)
        /// An artist in Lidarr whose listing has no release holding the song (singles not listed, D146): the single
        /// (release group) the singles switch would list, when MusicBrainz names one.
        case notListed(artistId: Int, single: MBID?)
        /// An artist not in Lidarr: the release a new artist's add would monitor (the album asked for, or the smallest a
        /// Finds-profile add can monitor), with its MusicBrainz types: the add's release types must list it (D136, R2).
        case newArtist(title: String, isAlbum: Bool, primaryType: String?, secondaryTypes: [String])
    }

    /// `album`: an album-page add (that release group); otherwise the song's smallest release.
    public func targetPreview(_ recording: ExternalRecording, album: MBID? = nil) async throws -> TargetPreview {
        guard let recordingId = recording.recordingMBID else { throw MusicBrainzError.notFound }
        let found = try await mb.recording(recordingId)
        guard let artistMBID = recording.artistMBID ?? found.artistIds.first else { throw MusicBrainzError.notFound }
        if let artist = try await lidarr.artists().first(where: { $0.foreignArtistId == artistMBID }) {
            let albums = try await lidarr.albums(artistId: artist.id)
            guard let rg = ReleasePicker.smallest(containing: found, available: Set(albums.compactMap(\.foreignAlbumId))),
                  let album = albums.first(where: { $0.foreignAlbumId == rg }) else {
                let singles = Set(found.releases.filter(Self.fitsFindsProfile).map(\.releaseGroup.id))
                return .notListed(artistId: artist.id, single: ReleasePicker.smallest(containing: found, available: singles))
            }
            return .listed(title: album.title, isAlbum: (album.albumType ?? "Album").lowercased() == "album")
        }
        let fits = Set(found.releases.filter(Self.fitsFindsProfile).map(\.releaseGroup.id))
        guard let rg = album ?? ReleasePicker.smallest(containing: found, available: fits),
              let release = found.releases.first(where: { $0.releaseGroup.id == rg }) else { throw MusicBrainzError.notFound }
        let group = release.releaseGroup
        return .newArtist(title: release.title, isAlbum: group.primaryType?.lowercased() == "album",
                          primaryType: group.primaryType, secondaryTypes: group.secondaryTypes)
    }
}

/// R19 "Try this album" and R20's dedupe by release group.
extension RequestRunner {
    /// The live request this Try is. Try this album: only one bringing in that release group; a single-song request
    /// for its first track never stands for the album (review I1). A song: its own request, else one bringing in the
    /// album it was picked from (R20).
    func liveTry(_ recording: ExternalRecording, album: MBID?, releaseGroup: MBID?) -> MagpieRequest? {
        if let album { return liveRequest(releaseGroup: album) }
        return list.first { ($0.isActive || $0.state == .ready) && Self.sameSong($0.recording, recording) }
            ?? liveRequest(releaseGroup: releaseGroup)
    }

    /// The target, when the artist's catalogue allows it (the owner's artist: an album it has; a new artist: one the
    /// Finds metadata profile lists). A target that isn't allowed is never swapped for another release group.
    static func albumTarget(_ target: MBID?, allowed: Bool) -> MBID? {
        guard let target, allowed else { return nil }
        return target
    }

    /// A live (or Ready) request bringing in this release group: resolved to it, or a Try this album aimed at it.
    func liveRequest(releaseGroup: MBID?) -> MagpieRequest? {
        guard let releaseGroup else { return nil }
        return list.first { ($0.isActive || $0.state == .ready) && ($0.plan?.releaseGroupMBID ?? $0.albumTarget) == releaseGroup }
    }
}
