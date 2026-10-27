import Foundation
import ListenBrainzKit
import MagpieCore
import Search

/// One song of a "Made for you" playlist: a library song (plays) or one not in the library (Try).
enum MadeForYouRow: Hashable {
    case library(Song)
    case notYet(ExternalRecording)
}

/// Task 7.1c: Home "Made for you" (ListenBrainz, only with a token) and the Artist page's "Not in your library"
/// albums (Lidarr, when connected). Both only read, and fill in after the library's own content; anything that fails
/// or takes too long leaves them out.
extension AppModel {
    /// Most library songs read at once when a playlist opens.
    static let madeForYouSongReads = 6

    /// A9: the token only ever goes to api.listenbrainz.org. Nil without a token: the section is absent.
    private func madeForYou() -> MadeForYou? {
        guard let token = tokenStore.load() else { return nil }
        return MadeForYou(client: ListenBrainzClient(transport: transport, token: token, limiter: listenBrainzLimiter))
    }

    /// The "Made for you" shelf. Empty without a token, or when ListenBrainz can't be read.
    func madeForYouPlaylists() async -> [MadeForYou.Playlist] {
        await madeForYou()?.playlists() ?? []
    }

    /// The playlist's songs, in order. Library songs whose details can't be read are left out (never shown as
    /// not in the library). Nil without a token or when the playlist can't be read.
    func madeForYouTracks(_ id: MBID) async -> [MadeForYouRow]? {
        guard let made = madeForYou() else { return nil }
        let index = await matchIndex?.index ?? .empty
        guard let tracks = await made.tracks(id, index: index) else { return nil }
        let songs = await librarySongs(tracks.compactMap { if case .library(let id, _) = $0 { id } else { nil } })
        return tracks.compactMap { track in
            switch track {
            case .library(let id, _): songs[id].map(MadeForYouRow.library)
            case .notYet(let recording): .notYet(recording)
            }
        }
    }

    /// The songs for `ids`, a few at a time. Ids that can't be read are missing from the result.
    private func librarySongs(_ ids: [String]) async -> [String: Song] {
        let unique = Array(Set(ids))
        var found: [String: Song] = [:]
        var next = 0
        await withTaskGroup(of: Song?.self) { group in
            func addNext() {
                guard next < unique.count else { return }
                let id = unique[next]
                next += 1
                group.addTask { [weak self] in try? await self?.request { try await $0.song(id: id) } }
            }
            for _ in 0..<Self.madeForYouSongReads { addNext() }
            for await song in group {
                if let song { found[song.id] = song }
                addNext()
            }
        }
        return found
    }

    /// The artist's albums Lidarr knows that the library doesn't have (`library`: the albums the page shows).
    /// Empty when Lidarr isn't connected or can't be read. Read-only.
    func artistNotYetAlbums(_ artist: Artist, library: [Album]) async -> [NotYetAlbum] {
        guard let lidarr = lidarrClient else { return [] }
        return await ArtistNotYet.albums(artist: artist.name, mbid: artist.mbid, library: library, lidarr: lidarr)
    }
}
