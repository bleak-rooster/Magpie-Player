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
    /// The original file's sample rate (Hz) and bit depth, when the server says (round 12 Y3: Now Playing's label).
    public var samplingRate: Int? = nil
    public var bitDepth: Int? = nil

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
    /// False when the server left a count out (it reads as 0): such a genre is shown, never dropped as empty.
    public var countsKnown: Bool

    public init(name: String, songCount: Int, albumCount: Int, countsKnown: Bool = true) {
        self.name = name; self.songCount = songCount; self.albumCount = albumCount; self.countsKnown = countsKnown
    }

    /// Known to have no albums and no songs (both counts given, both zero).
    public var isKnownEmpty: Bool { countsKnown && songCount == 0 && albumCount == 0 }
}

/// The user's starred songs, albums and artists.
public struct Starred: Sendable, Hashable {
    public var songs: [Song]
    public var albums: [Album]
    public var artists: [Artist]

    public init(songs: [Song] = [], albums: [Album] = [], artists: [Artist] = []) {
        self.songs = songs; self.albums = albums; self.artists = artists
    }
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
    /// The user starred ("favourited") it (round 11 R7).
    public var starred: Bool
    /// When the server first listed it (Subsonic `created`), when it says. Round 13: the car's Newest, after the year.
    public var created: Date?
    /// The user's plays of it, when the server says (round 15 C4: a genre page's Most played, sorted on the phone).
    public var playCount: Int?
    /// The original release's year, when the server says (round 15 C4 fix round, D142): Navidrome orders "by year" by the
    /// original date first.
    public var originalYear: Int?

    /// The year Navidrome's year order uses: the original release's, else the album's own.
    public var sortYear: Int? { originalYear ?? year }

    public init(id: String, name: String, artist: String, artistId: String? = nil, year: Int? = nil,
                songCount: Int, duration: TimeInterval, coverArtId: String? = nil,
                releaseGroupMBID: MBID? = nil, songs: [Song]? = nil, starred: Bool = false, created: Date? = nil,
                playCount: Int? = nil, originalYear: Int? = nil) {
        self.id = id; self.name = name; self.artist = artist; self.artistId = artistId
        self.year = year; self.songCount = songCount; self.duration = duration
        self.coverArtId = coverArtId; self.releaseGroupMBID = releaseGroupMBID; self.songs = songs
        self.starred = starred; self.created = created; self.playCount = playCount
        self.originalYear = originalYear
    }
}

public struct Artist: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var albumCount: Int
    public var coverArtId: String?
    public var mbid: MBID?
    /// The user starred ("favourited") them (round 11 R7).
    public var starred: Bool

    public init(id: String, name: String, albumCount: Int, coverArtId: String? = nil, mbid: MBID? = nil,
                starred: Bool = false) {
        self.id = id; self.name = name; self.albumCount = albumCount
        self.coverArtId = coverArtId; self.mbid = mbid; self.starred = starred
    }
}

public struct Playlist: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var songCount: Int
    public var duration: TimeInterval
    public var coverArtId: String?
    /// The owner's user name, when the server says (round 11 R8).
    public var owner: String?
    /// OpenSubsonic `readonly`: whether the signed-in user may not change it; nil from a server that doesn't say.
    public var readOnly: Bool?
    /// When it last changed, when the server says (Add to playlist lists the latest first).
    public var changed: Date?

    public init(id: String, name: String, songCount: Int, duration: TimeInterval, coverArtId: String? = nil,
                owner: String? = nil, readOnly: Bool? = nil, changed: Date? = nil) {
        self.id = id; self.name = name; self.songCount = songCount
        self.duration = duration; self.coverArtId = coverArtId; self.owner = owner; self.readOnly = readOnly
        self.changed = changed
    }

    /// Whether `username` may rename it, change its songs or delete it (spec R8: only the user's own): never when
    /// the server says `readonly`; otherwise owned by that user (compared case-insensitively, as Navidrome signs in),
    /// or, with no owner given, the server's `readonly: false`.
    public func isEditable(by username: String) -> Bool {
        if readOnly == true { return false }
        if let owner { return owner.caseInsensitiveCompare(username) == .orderedSame }
        return readOnly == false
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
    /// The release the source names (LB labs search's `release_mbid`), for its Cover Art Archive front (R15). Optional,
    /// so requests saved before it still decode.
    public var releaseMBID: MBID?

    public init(recordingMBID: MBID? = nil, artistMBID: MBID? = nil, title: String, artist: String,
                releaseTitle: String? = nil, duration: TimeInterval? = nil, isrcs: [String] = [],
                source: ExternalSource, releaseMBID: MBID? = nil) {
        self.recordingMBID = recordingMBID; self.artistMBID = artistMBID; self.title = title
        self.artist = artist; self.releaseTitle = releaseTitle; self.duration = duration
        self.isrcs = isrcs; self.source = source; self.releaseMBID = releaseMBID
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
