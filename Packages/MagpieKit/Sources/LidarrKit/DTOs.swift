import Foundation
import MagpieCore

// Lidarr v1 DTOs. Decoding is deliberately defensive (brief ruling 3): every field is optional or
// defaulted, MBIDs go through `MBID(_:)` (bad ones become nil), arrays drop undecodable elements,
// and display-only external strings are capped at `Lidarr.maxDisplayLength` characters.

public enum Lidarr {
    public static let maxDisplayLength = 500
}

extension String {
    /// Display-only external strings are capped so a hostile or broken server cannot flood the UI.
    func cappedForDisplay(_ limit: Int = Lidarr.maxDisplayLength) -> String {
        count > limit ? String(prefix(limit)) : self
    }
}

/// Decodes an array, skipping elements that fail to decode.
struct LossyArray<T: Decodable>: Decodable {
    var values: [T]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [T] = []
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) { out.append(value) } else { _ = try? container.decode(Skip.self) }
        }
        values = out
    }

    private struct Skip: Decodable {}
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    func value<T: Decodable>(_ key: String, as _: T.Type = T.self) -> T? {
        (try? decodeIfPresent(T.self, forKey: AnyKey(key))) ?? nil
    }

    func text(_ key: String) -> String? { value(key, as: String.self)?.cappedForDisplay() }

    func mbid(_ key: String) -> MBID? { value(key, as: String.self).flatMap { MBID($0) } }

    func int(_ key: String) -> Int? {
        if let i: Int = value(key) { return i }
        // `Int(_:)` traps beyond Int's range (`"id": 1e300`, crash hunt 4): such a value is unusable, like a missing one.
        if let d: Double = value(key) { return Int(exactly: d.rounded(.towardZero)) }
        return nil
    }

    /// Rows without a usable id are useless to callers; throwing lets `LossyArray` drop them.
    func requiredInt(_ key: String) throws -> Int {
        guard let i = int(key) else {
            throw DecodingError.keyNotFound(AnyKey(key), .init(codingPath: codingPath, debugDescription: "missing or invalid \(key)"))
        }
        return i
    }

    func double(_ key: String) -> Double? { value(key, as: Double.self) }

    func date(_ key: String) -> Date? { value(key, as: String.self).flatMap(LidarrDates.parse) }
}

enum LidarrDates {
    // Formatters are created once; ISO8601DateFormatter is safe to use concurrently for parsing/formatting.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// Lidarr (.NET) emits up to 7 fractional digits (`...00.1234567Z`); the formatter wants exactly 3.
    static func parse(_ s: String) -> Date? {
        if let d = plain.date(from: s) { return d }
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let digits = s[s.index(after: dot)...].prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = s[digits.endIndex...]
        let ms = String((digits + "000").prefix(3))
        return fractional.date(from: String(s[..<dot]) + "." + ms + rest)
    }

    static func format(_ d: Date) -> String { plain.string(from: d) }
}

public struct LidarrStatus: Sendable, Equatable, Decodable {
    public var version: String
    public var instanceName: String
    /// Lidarr's `authentication` value: `none`, `basic`, `forms` or `external`. Empty when unknown.
    public var authenticationMethod: String

    public init(version: String, instanceName: String, authenticationMethod: String) {
        self.version = version; self.instanceName = instanceName; self.authenticationMethod = authenticationMethod
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        version = c.text("version") ?? ""
        instanceName = c.text("instanceName") ?? ""
        authenticationMethod = c.text("authentication") ?? ""
    }
}

public struct HealthIssue: Sendable, Equatable, Decodable {
    public var source: String
    public var type: String
    public var message: String
    public var wikiUrl: String?

    public init(source: String, type: String, message: String, wikiUrl: String? = nil) {
        self.source = source; self.type = type; self.message = message; self.wikiUrl = wikiUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        source = c.text("source") ?? ""
        type = c.text("type") ?? ""
        message = c.text("message") ?? ""
        wikiUrl = c.text("wikiUrl")
    }
}

public struct RootFolder: Sendable, Equatable, Decodable {
    public var id: Int
    public var path: String
    public var freeSpace: Int64?
    public var name: String?
    public var accessible: Bool?

    public init(id: Int, path: String, freeSpace: Int64? = nil, name: String? = nil, accessible: Bool? = nil) {
        self.id = id; self.path = path; self.freeSpace = freeSpace; self.name = name; self.accessible = accessible
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredInt("id")
        path = c.value("path") ?? ""
        // Out of Int64's range (`1e300`) reads as unknown: `Int64(_:)` would trap (crash hunt 4).
        freeSpace = c.value("freeSpace", as: Int64.self) ?? c.double("freeSpace").flatMap { Int64(exactly: $0.rounded(.towardZero)) }
        name = c.text("name")
        accessible = c.value("accessible")
    }
}

public struct QualityProfile: Sendable, Equatable, Decodable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) { self.id = id; self.name = name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredInt("id")
        name = c.text("name") ?? ""
    }
}

public struct MetadataProfile: Sendable, Equatable, Decodable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) { self.id = id; self.name = name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredInt("id")
        name = c.text("name") ?? ""
    }
}

public struct LidarrTag: Sendable, Equatable, Decodable {
    public var id: Int
    public var label: String

    public init(id: Int, label: String) { self.id = id; self.label = label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredInt("id")
        label = c.text("label") ?? ""
    }
}

/// An artist as the lookup endpoint describes it. `id` is non-nil only when it is already in the library.
public struct LidarrArtistLookup: Sendable, Equatable, Decodable {
    public var foreignArtistId: MBID?
    public var artistName: String
    public var disambiguation: String?
    public var overview: String?
    public var artistType: String?
    public var status: String?
    public var id: Int?
    /// The artist folder name Lidarr's naming format gives now (`folder`): where a move puts it (G4).
    public var folder: String?

    public init(foreignArtistId: MBID?, artistName: String, disambiguation: String? = nil, overview: String? = nil,
                artistType: String? = nil, status: String? = nil, id: Int? = nil, folder: String? = nil) {
        self.foreignArtistId = foreignArtistId; self.artistName = artistName; self.disambiguation = disambiguation
        self.overview = overview; self.artistType = artistType; self.status = status; self.id = id
        self.folder = folder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        foreignArtistId = c.mbid("foreignArtistId")
        artistName = c.text("artistName") ?? ""
        disambiguation = c.text("disambiguation").flatMap { $0.isEmpty ? nil : $0 }
        overview = c.text("overview")
        artistType = c.text("artistType")
        status = c.text("status")
        id = c.int("id").flatMap { $0 > 0 ? $0 : nil }
        folder = c.value("folder", as: String.self).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One artist or album row of `/search` (A10: text search is flaky, so only these two row kinds are used).
public struct LidarrSearchHit: Sendable, Equatable, Decodable {
    public enum Kind: String, Sendable { case artist, album }

    public var kind: Kind
    public var foreignId: MBID?
    public var artistName: String
    public var artistMBID: MBID?
    public var albumTitle: String?
    public var albumType: String?
    public var releaseDate: Date?
    /// Library id when the artist or album is already in Lidarr.
    public var libraryId: Int?

    public init(kind: Kind, foreignId: MBID?, artistName: String, artistMBID: MBID? = nil, albumTitle: String? = nil,
                albumType: String? = nil, releaseDate: Date? = nil, libraryId: Int? = nil) {
        self.kind = kind; self.foreignId = foreignId; self.artistName = artistName; self.artistMBID = artistMBID
        self.albumTitle = albumTitle; self.albumType = albumType; self.releaseDate = releaseDate
        self.libraryId = libraryId
    }

    struct Unsupported: Error {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let positive: (Int?) -> Int? = { $0.flatMap { $0 > 0 ? $0 : nil } }
        if let artist = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("artist")) {
            kind = .artist
            artistName = artist.text("artistName") ?? ""
            artistMBID = artist.mbid("foreignArtistId")
            foreignId = c.mbid("foreignId") ?? artistMBID
            libraryId = positive(artist.int("id"))
        } else if let album = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("album")) {
            kind = .album
            albumTitle = album.text("title")
            albumType = album.text("albumType")
            releaseDate = album.date("releaseDate")
            foreignId = c.mbid("foreignId") ?? album.mbid("foreignAlbumId")
            libraryId = positive(album.int("id"))
            let artist = try? album.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("artist"))
            artistName = artist?.text("artistName") ?? ""
            artistMBID = artist?.mbid("foreignArtistId")
        } else {
            throw Unsupported()
        }
    }
}

public struct LidarrArtist: Sendable, Equatable, Decodable {
    public var id: Int
    public var artistName: String
    public var foreignArtistId: MBID?
    public var path: String?
    public var rootFolderPath: String?
    public var monitored: Bool
    public var qualityProfileId: Int?
    public var metadataProfileId: Int?
    public var tags: [Int]
    public var albumCount: Int?
    public var trackFileCount: Int?
    /// Which albums Lidarr monitors when they show up (`all`, `new`, `none`); Follow new releases (Task 7.1b).
    public var monitorNewItems: String?

    public init(id: Int, artistName: String, foreignArtistId: MBID? = nil, path: String? = nil,
                rootFolderPath: String? = nil, monitored: Bool = false, qualityProfileId: Int? = nil,
                metadataProfileId: Int? = nil, tags: [Int] = [], albumCount: Int? = nil, trackFileCount: Int? = nil,
                monitorNewItems: String? = nil) {
        self.id = id; self.artistName = artistName; self.foreignArtistId = foreignArtistId; self.path = path
        self.rootFolderPath = rootFolderPath; self.monitored = monitored; self.qualityProfileId = qualityProfileId
        self.metadataProfileId = metadataProfileId; self.tags = tags; self.albumCount = albumCount
        self.trackFileCount = trackFileCount; self.monitorNewItems = monitorNewItems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredInt("id")
        artistName = c.text("artistName") ?? ""
        foreignArtistId = c.mbid("foreignArtistId")
        path = c.value("path")
        rootFolderPath = c.value("rootFolderPath")
        monitored = c.value("monitored") ?? false
        qualityProfileId = c.int("qualityProfileId")
        metadataProfileId = c.int("metadataProfileId")
        tags = c.value("tags", as: LossyArray<Int>.self)?.values ?? []
        let stats = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("statistics"))
        albumCount = stats?.int("albumCount")
        trackFileCount = stats?.int("trackFileCount")
        monitorNewItems = c.value("monitorNewItems")
    }
}

public struct LidarrAlbum: Sendable, Equatable, Decodable {
    public var id: Int
    public var title: String
    public var artistId: Int?
    public var foreignAlbumId: MBID?
    public var monitored: Bool
    public var albumType: String?
    public var releaseDate: Date?
    public var trackCount: Int?
    public var trackFileCount: Int?
    /// Seconds of music, from Lidarr's `duration` (milliseconds, the length of the release it would bring in).
    /// Nil when Lidarr doesn't know it (0 or missing): never guessed (A5).
    public var duration: TimeInterval?

    public init(id: Int, title: String, artistId: Int? = nil, foreignAlbumId: MBID? = nil, monitored: Bool = false,
                albumType: String? = nil, releaseDate: Date? = nil, trackCount: Int? = nil, trackFileCount: Int? = nil,
                duration: TimeInterval? = nil) {
        self.id = id; self.title = title; self.artistId = artistId; self.foreignAlbumId = foreignAlbumId
        self.monitored = monitored; self.albumType = albumType; self.releaseDate = releaseDate
        self.trackCount = trackCount; self.trackFileCount = trackFileCount; self.duration = duration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredInt("id")
        title = c.text("title") ?? ""
        artistId = c.int("artistId")
        foreignAlbumId = c.mbid("foreignAlbumId")
        monitored = c.value("monitored") ?? false
        albumType = c.text("albumType")
        releaseDate = c.date("releaseDate")
        let stats = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("statistics"))
        trackCount = stats?.int("trackCount")
        trackFileCount = stats?.int("trackFileCount")
        duration = c.double("duration").flatMap { $0 > 0 && $0.isFinite ? $0 / 1000 : nil }
    }
}

public struct QueueItem: Sendable, Equatable, Decodable {
    /// The queue item's id (R17: `DELETE /queue/{id}` removes a stalled download). Nil when Lidarr didn't send one.
    public var id: Int?
    public var albumId: Int?
    public var artistId: Int?
    /// The download client's *name* as set up in Lidarr (`DownloadClientInfo.name`), e.g. "Slskd".
    public var downloadClient: String?
    /// Lidarr's protocol name, e.g. `SoulseekDownloadProtocol`.
    public var protocolName: String?
    public var size: Double
    public var sizeleft: Double
    public var status: String
    public var trackedDownloadState: String
    public var timeleft: String?
    public var statusMessages: [String]

    public init(id: Int? = nil, albumId: Int?, artistId: Int? = nil, downloadClient: String? = nil,
                protocolName: String? = nil, size: Double, sizeleft: Double, status: String = "",
                trackedDownloadState: String = "", timeleft: String? = nil, statusMessages: [String] = []) {
        self.id = id; self.albumId = albumId; self.artistId = artistId; self.downloadClient = downloadClient
        self.protocolName = protocolName; self.size = size; self.sizeleft = sizeleft; self.status = status
        self.trackedDownloadState = trackedDownloadState; self.timeleft = timeleft; self.statusMessages = statusMessages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("id")
        albumId = c.int("albumId")
        artistId = c.int("artistId")
        downloadClient = c.text("downloadClient")
        protocolName = c.text("protocol")
        size = c.double("size") ?? 0
        sizeleft = c.double("sizeleft") ?? 0
        status = c.text("status") ?? ""
        trackedDownloadState = c.text("trackedDownloadState") ?? ""
        timeleft = c.text("timeleft")
        var messages: [String] = []
        for entry in c.value("statusMessages", as: LossyArray<StatusMessage>.self)?.values ?? [] {
            messages.append(contentsOf: entry.messages.isEmpty ? [entry.title].filter { !$0.isEmpty } : entry.messages)
        }
        statusMessages = messages
    }

    /// A14: progress = 1 - sizeleft/size, clamped to 0...1. `nil` when the size is not known yet.
    public var progress: Double? {
        guard size > 0 else { return nil }
        return min(1, max(0, 1 - sizeleft / size))
    }

    private struct StatusMessage: Decodable {
        var title: String
        var messages: [String]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            title = c.text("title") ?? ""
            messages = (c.value("messages", as: LossyArray<String>.self)?.values ?? []).map { $0.cappedForDisplay() }
        }
    }
}

/// One download client as Lidarr has it set up (`GET /downloadclient`, read only). Only what R17 needs: its settings
/// (`fields`, which may carry the client's own API key) are never decoded.
public struct DownloadClientInfo: Sendable, Equatable, Decodable {
    public var id: Int
    public var name: String
    public var implementation: String
    public var implementationName: String
    public var protocolName: String

    public init(id: Int, name: String, implementation: String = "", implementationName: String = "",
                protocolName: String = "") {
        self.id = id; self.name = name; self.implementation = implementation
        self.implementationName = implementationName; self.protocolName = protocolName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredInt("id")
        name = c.text("name") ?? ""
        implementation = c.text("implementation") ?? ""
        implementationName = c.text("implementationName") ?? ""
        protocolName = c.text("protocol") ?? ""
    }

    /// A Soulseek client (slskd through Tubifarry: implementation `SlskdClient`, protocol `SoulseekDownloadProtocol`).
    public var isSoulseek: Bool {
        [implementation, implementationName, protocolName].contains { text in
            let t = text.lowercased()
            return t.contains("slskd") || t.contains("soulseek")
        }
    }
}

public struct HistoryEvent: Sendable, Equatable, Decodable {
    /// How Magpie reads a Lidarr history event (A14). Failures are `waiting`, never `failed`: Lidarr retries.
    public enum Kind: Sendable, Equatable {
        case grabbed
        case imported
        case waiting
        case ignored
        case other
    }

    public var id: Int?
    public var albumId: Int?
    public var artistId: Int?
    public var sourceTitle: String
    public var eventType: String
    public var date: Date?

    public init(id: Int? = nil, albumId: Int? = nil, artistId: Int? = nil, sourceTitle: String = "",
                eventType: String, date: Date? = nil) {
        self.id = id; self.albumId = albumId; self.artistId = artistId; self.sourceTitle = sourceTitle
        self.eventType = eventType; self.date = date
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("id")
        albumId = c.int("albumId")
        artistId = c.int("artistId")
        sourceTitle = c.text("sourceTitle") ?? ""
        eventType = c.text("eventType") ?? ""
        date = c.date("date")
    }

    public var kind: Kind {
        switch eventType.lowercased() {
        case "grabbed": .grabbed
        case "trackfileimported", "downloadimported", "downloadfolderimported": .imported
        case "downloadfailed", "albumimportincomplete": .waiting
        case "downloadignored": .ignored
        default: .other
        }
    }
}

public struct CommandStatus: Sendable, Equatable, Decodable {
    public var id: Int
    public var name: String
    /// `queued`, `started`, `completed`, `failed`, ...
    public var status: String
    public var result: String?
    public var message: String?
    public var queued: Date?
    public var started: Date?
    public var ended: Date?
    /// Artists the command works on (Keep's `BulkMoveArtist`, A3), from its body: `artist[].artistId` (Lidarr's
    /// `BulkMoveArtistCommand`), and defensively `artists[].artistId`, `artistIds[]`, `artistId`.
    public var artistIds: [Int]

    public init(id: Int, name: String, status: String, result: String? = nil, message: String? = nil,
                queued: Date? = nil, started: Date? = nil, ended: Date? = nil, artistIds: [Int] = []) {
        self.id = id; self.name = name; self.status = status; self.result = result; self.message = message
        self.queued = queued; self.started = started; self.ended = ended; self.artistIds = artistIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredInt("id")
        name = c.text("name") ?? ""
        status = c.text("status") ?? ""
        result = c.text("result")
        message = c.text("message")
        queued = c.date("queued")
        started = c.date("started")
        ended = c.date("ended")
        var ids: [Int] = []
        if let body = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("body")) {
            for key in ["artist", "artists"] {
                ids += (body.value(key, as: LossyArray<ArtistRef>.self)?.values ?? []).compactMap(\.artistId)
            }
            ids += body.value("artistIds", as: LossyArray<Int>.self)?.values ?? []
            if let one = body.int("artistId") { ids.append(one) }
        }
        artistIds = ids
    }

    private struct ArtistRef: Decodable {
        var artistId: Int?
        init(from decoder: Decoder) throws { artistId = try decoder.container(keyedBy: AnyKey.self).int("artistId") }
    }
}

public struct TrackFile: Sendable, Equatable, Decodable {
    public var id: Int
    public var path: String
    /// Quality name such as `FLAC` or `MP3-320`.
    public var quality: String?
    public var albumId: Int?
    /// The artist the file belongs to (the write gate confines track file deletes to Magpie's finds, FM1).
    public var artistId: Int?
    public var size: Int64?

    public init(id: Int, path: String, quality: String? = nil, albumId: Int? = nil, artistId: Int? = nil,
                size: Int64? = nil) {
        self.id = id; self.path = path; self.quality = quality; self.albumId = albumId; self.artistId = artistId
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredInt("id")
        path = c.value("path") ?? ""
        albumId = c.int("albumId")
        artistId = c.int("artistId")
        size = c.value("size", as: Int64.self)
        let outer = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("quality"))
        let inner = try? outer?.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("quality"))
        quality = inner?.text("name")
    }
}

/// `/filesystem` response, only the part `filesystemExists` needs.
struct FilesystemListing: Decodable {
    var directories: [String]
    var files: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        struct Entry: Decodable {
            var path: String
            init(from decoder: Decoder) throws {
                path = try decoder.container(keyedBy: AnyKey.self).value("path") ?? ""
            }
        }
        directories = (c.value("directories", as: LossyArray<Entry>.self)?.values ?? []).map(\.path)
        files = (c.value("files", as: LossyArray<Entry>.self)?.values ?? []).map(\.path)
    }
}
