import Foundation

public struct Song: Sendable, Hashable, Codable {
    public var id: String
    public var title: String
    public var artist: String
    public var artistId: String?
    public var album: String
    public var albumId: String?
    public var track: Int?
    public var disc: Int?
    public var duration: TimeInterval
    public var suffix: String?
    public var bitRate: Int?
    public var coverArtId: String?
    public var recordingMBID: MBID?
    /// The (first) track artist's MusicBrainz id, when the file is tagged with one (native API only).
    public var artistMBID: MBID?
    public var isrcs: [String]
    public var libraryId: Int?
    public var starred: Bool
    /// When the server first listed the song (native API only). A find's days left count from here.
    public var createdAt: Date?
    public var genre: String?
    public var replayGain: ReplayGain?

    public init(id: String, title: String, artist: String, artistId: String? = nil,
                album: String, albumId: String? = nil, track: Int? = nil, disc: Int? = nil,
                duration: TimeInterval, suffix: String? = nil, bitRate: Int? = nil,
                coverArtId: String? = nil, recordingMBID: MBID? = nil, artistMBID: MBID? = nil,
                isrcs: [String] = [], libraryId: Int? = nil, starred: Bool = false, createdAt: Date? = nil,
                genre: String? = nil, replayGain: ReplayGain? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.artistId = artistId
        self.album = album; self.albumId = albumId; self.track = track; self.disc = disc
        self.duration = duration; self.suffix = suffix; self.bitRate = bitRate
        self.coverArtId = coverArtId; self.recordingMBID = recordingMBID; self.artistMBID = artistMBID
        self.isrcs = isrcs; self.libraryId = libraryId; self.starred = starred; self.createdAt = createdAt
        self.genre = genre; self.replayGain = replayGain
    }
}

/// Gains in dB and peaks as linear sample amplitude, as the server read them from the file's tags.
public struct ReplayGain: Sendable, Hashable, Codable {
    public var trackGain: Double?
    public var albumGain: Double?
    public var trackPeak: Double?
    public var albumPeak: Double?

    public init(trackGain: Double? = nil, albumGain: Double? = nil, trackPeak: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain; self.albumGain = albumGain
        self.trackPeak = trackPeak; self.albumPeak = albumPeak
    }
}

public struct Genre: Sendable, Hashable, Codable {
    public var name: String
    public var songCount: Int
    public var albumCount: Int

    public init(name: String, songCount: Int, albumCount: Int) {
        self.name = name; self.songCount = songCount; self.albumCount = albumCount
    }
}

/// The user's starred songs and albums.
public struct Starred: Sendable, Hashable {
    public var songs: [Song]
    public var albums: [Album]

    public init(songs: [Song] = [], albums: [Album] = []) { self.songs = songs; self.albums = albums }
}

public struct Album: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var artist: String
    public var artistId: String?
    public var year: Int?
    public var songCount: Int
    public var duration: TimeInterval
    public var coverArtId: String?
    public var releaseGroupMBID: MBID?
    public var songs: [Song]?

    public init(id: String, name: String, artist: String, artistId: String? = nil, year: Int? = nil,
                songCount: Int, duration: TimeInterval, coverArtId: String? = nil,
                releaseGroupMBID: MBID? = nil, songs: [Song]? = nil) {
        self.id = id; self.name = name; self.artist = artist; self.artistId = artistId
        self.year = year; self.songCount = songCount; self.duration = duration
        self.coverArtId = coverArtId; self.releaseGroupMBID = releaseGroupMBID; self.songs = songs
    }
}

public struct Artist: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var albumCount: Int
    public var coverArtId: String?
    public var mbid: MBID?

    public init(id: String, name: String, albumCount: Int, coverArtId: String? = nil, mbid: MBID? = nil) {
        self.id = id; self.name = name; self.albumCount = albumCount
        self.coverArtId = coverArtId; self.mbid = mbid
    }
}

public struct Playlist: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var songCount: Int
    public var duration: TimeInterval
    public var coverArtId: String?

    public init(id: String, name: String, songCount: Int, duration: TimeInterval, coverArtId: String? = nil) {
        self.id = id; self.name = name; self.songCount = songCount
        self.duration = duration; self.coverArtId = coverArtId
    }
}

public enum ExternalSource: String, Sendable, Hashable, Codable {
    case listenBrainz, lidarr
}

public struct ExternalRecording: Sendable, Hashable, Codable {
    public var recordingMBID: MBID?
    public var artistMBID: MBID?
    public var title: String
    public var artist: String
    public var releaseTitle: String?
    public var duration: TimeInterval?
    /// ISRCs when the source knows them (LB labs search doesn't; A8).
    public var isrcs: [String]
    public var source: ExternalSource

    public init(recordingMBID: MBID? = nil, artistMBID: MBID? = nil, title: String, artist: String,
                releaseTitle: String? = nil, duration: TimeInterval? = nil, isrcs: [String] = [],
                source: ExternalSource) {
        self.recordingMBID = recordingMBID; self.artistMBID = artistMBID; self.title = title
        self.artist = artist; self.releaseTitle = releaseTitle; self.duration = duration
        self.isrcs = isrcs; self.source = source
    }
}

public enum Quality: Sendable, Hashable, Codable {
    case sample, losslessSoon, lossless, hiRes, standard

    /// Lossless containers (flac/alac/wav) map to `.lossless`; everything else, including unknown, is `.standard`.
    public static func from(suffix: String?, bitRate: Int?) -> Quality {
        switch suffix?.lowercased() {
        case "flac", "alac", "wav": return .lossless
        default: return .standard
        }
    }
}

public enum AlbumListType: String, Sendable, Hashable, Codable {
    case recent, newest, frequent, alphabeticalByName, random, starred
}

public struct LibrarySearchResult: Sendable, Hashable, Codable {
    public var songs: [Song]
    public var albums: [Album]
    public var artists: [Artist]

    public init(songs: [Song] = [], albums: [Album] = [], artists: [Artist] = []) {
        self.songs = songs; self.albums = albums; self.artists = artists
    }
}

public struct LyricLine: Sendable, Hashable, Codable {
    public var start: TimeInterval?
    public var text: String

    public init(start: TimeInterval? = nil, text: String) {
        self.start = start; self.text = text
    }
}

public struct Lyrics: Sendable, Hashable, Codable {
    public var synced: Bool
    public var lines: [LyricLine]

    public init(synced: Bool, lines: [LyricLine]) {
        self.synced = synced; self.lines = lines
    }
}
