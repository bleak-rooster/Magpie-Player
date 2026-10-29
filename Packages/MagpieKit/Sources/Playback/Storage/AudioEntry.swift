import Foundation
import MagpieCore

/// Downloads are kept until the owner removes them; the cache holds pre-downloaded songs, evicted LRU (spec §6).
public enum AudioKind: String, Codable, Sendable { case download, cache }

/// Why a download is kept. A song stays while any reason holds it.
public enum DownloadReason: Codable, Hashable, Sendable { case song, album(String), playlist(String), favourites }

/// The snapshot of a song kept beside its file: enough to browse and play what's on the phone offline.
public struct AudioMetadata: Codable, Hashable, Sendable {
    public var songId: String
    public var title: String
    public var artist: String
    public var artistId: String?
    public var album: String
    public var albumId: String?
    public var track: Int?
    public var disc: Int?
    public var duration: TimeInterval
    public var genre: String?
    public var coverArtId: String?
    public var suffix: String?
    public var replayGain: ReplayGain?

    public init(_ song: Song) {
        songId = song.id; title = song.title; artist = song.artist; artistId = song.artistId
        album = song.album; albumId = song.albumId; track = song.track; disc = song.disc
        duration = song.duration; genre = song.genre; coverArtId = song.coverArtId; suffix = song.suffix
        replayGain = song.replayGain
    }

    public var song: Song {
        Song(id: songId, title: title, artist: artist, artistId: artistId, album: album, albumId: albumId,
             track: track, disc: disc, duration: duration, suffix: suffix, coverArtId: coverArtId,
             genre: genre, replayGain: replayGain)
    }
}

/// One stored song (at most one per song id). Also written as the file's sidecar, `<fileName>.json`.
public struct AudioEntry: Codable, Hashable, Sendable {
    public var songId: String
    public var quality: StreamQuality
    /// `sha256(songId|quality).<ext>`: never a server string.
    public var fileName: String
    public var size: Int64
    public var kind: AudioKind
    /// Empty for cache entries.
    public var reasons: Set<DownloadReason>
    public var downloadedAt: Date
    public var lastPlayed: Date?
    public var metadata: AudioMetadata
}

/// A playlist as it was when downloaded (refreshed when it's opened with a connection).
public struct DownloadedPlaylist: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var coverArtId: String?
    public var songIds: [String]
    public var savedAt: Date

    public init(id: String, name: String, coverArtId: String?, songIds: [String], savedAt: Date) {
        self.id = id; self.name = name; self.coverArtId = coverArtId; self.songIds = songIds; self.savedAt = savedAt
    }
}

public struct AudioUsage: Sendable, Equatable {
    public var downloadBytes: Int64
    public var cacheBytes: Int64

    public init(downloadBytes: Int64, cacheBytes: Int64) {
        self.downloadBytes = downloadBytes; self.cacheBytes = cacheBytes
    }
}

public enum AudioStoreError: Error, Equatable { case downloadsFull, invalidFile, unknownSong }

// MARK: - Tolerant decoding
//
// Sidecars outlive app versions. Only the fields that name the file are required; anything else missing (an
// older schema) takes a safe default, so a schema change never makes a stored song undecodable. A default kind of
// `.download` means a song is never evicted because its kind was lost; the size is re-read from the file.

extension AudioEntry {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songId = try c.decode(String.self, forKey: .songId)
        quality = try c.decode(StreamQuality.self, forKey: .quality)
        fileName = try c.decode(String.self, forKey: .fileName)
        size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? 0
        kind = (try? c.decodeIfPresent(AudioKind.self, forKey: .kind)) ?? .download
        reasons = (try? c.decodeIfPresent(Set<DownloadReason>.self, forKey: .reasons)) ?? []
        downloadedAt = (try? c.decodeIfPresent(Date.self, forKey: .downloadedAt)) ?? Date(timeIntervalSinceReferenceDate: 0)
        lastPlayed = try? c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        metadata = (try? c.decodeIfPresent(AudioMetadata.self, forKey: .metadata))
            ?? AudioMetadata(Song(id: songId, title: "", artist: "", album: "", duration: 0))
    }
}

extension AudioMetadata {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songId = try c.decode(String.self, forKey: .songId)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        artist = (try? c.decodeIfPresent(String.self, forKey: .artist)) ?? ""
        artistId = try? c.decodeIfPresent(String.self, forKey: .artistId)
        album = (try? c.decodeIfPresent(String.self, forKey: .album)) ?? ""
        albumId = try? c.decodeIfPresent(String.self, forKey: .albumId)
        track = try? c.decodeIfPresent(Int.self, forKey: .track)
        disc = try? c.decodeIfPresent(Int.self, forKey: .disc)
        duration = (try? c.decodeIfPresent(TimeInterval.self, forKey: .duration)) ?? 0
        genre = try? c.decodeIfPresent(String.self, forKey: .genre)
        coverArtId = try? c.decodeIfPresent(String.self, forKey: .coverArtId)
        suffix = try? c.decodeIfPresent(String.self, forKey: .suffix)
        replayGain = try? c.decodeIfPresent(ReplayGain.self, forKey: .replayGain)
    }
}
