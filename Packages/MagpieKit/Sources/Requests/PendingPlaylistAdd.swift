import Foundation
import MagpieCore

/// Round 14 A3 (Decision 5, D101): a song saved to one of the owner's playlists before the library has it. Navidrome
/// playlists only hold songs it has, so the add waits ("Coming") and is made when the song lands.
///
/// - **Just this song** (Decision 4) links the Find that brings it (`requestId`): on arrival a find is kept (moved into
///   the main library) first, then added.
/// - **Whole artist** has no request (the artist's own add brings it): the library is looked up for it by recording MBID,
///   else artist + title + length within 3 s (`SongIdentity`), never by name alone, for up to 14 days.
public struct PendingPlaylistAdd: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var playlistId: String
    public var playlistName: String
    public var recording: ExternalRecording
    public var requestId: RequestID?
    public var createdAt: Date
    /// Gave up (the request stopped, the playlist went, nothing landed in time): the row offers Retry and Remove.
    public var failedAt: Date?
    /// The library song the playlist write was (maybe) sent for, saved just before it: after a relaunch the playlist is
    /// read first, so the song is never added twice.
    public var sendingSongId: String?
    /// The playlist can't take it (gone, or not the owner's any more): Remove only.
    public var playlistGone: Bool?

    public init(id: UUID = UUID(), playlistId: String, playlistName: String, recording: ExternalRecording,
                requestId: RequestID?, createdAt: Date) {
        self.id = id; self.playlistId = playlistId; self.playlistName = playlistName; self.recording = recording
        self.requestId = requestId; self.createdAt = createdAt
    }

    public var isFailed: Bool { failedAt != nil }
}

/// What to do about a pending add now (pure; the app does it).
public enum PendingAddStep: Equatable, Sendable {
    /// Still coming: the request's state for the row's progress (nil: Whole artist).
    case waiting(RequestState?)
    /// A find arrived: keep it first (moved into the main library), then add.
    case keep(RequestID)
    case add(songId: String)
    /// Whole artist: look the library up for it.
    case lookUp
    case failed
}

public enum PendingPlaylistAdds {
    /// How long a Whole artist add waits for its song.
    public static let wholeArtistLimit: TimeInterval = 14 * 86_400

    public static func step(_ add: PendingPlaylistAdd, request: MagpieRequest?, now: Date) -> PendingAddStep {
        if add.failedAt != nil { return .failed }
        guard let linked = add.requestId else {
            return now.timeIntervalSince(add.createdAt) > wholeArtistLimit ? .failed : .lookUp
        }
        guard let r = request, r.id == linked else { return .failed }
        switch r.state {
        case .failed, .cancelled, .dismissed:
            return .failed
        case .ready:
            guard r.isFind else { return r.songId.map { .add(songId: $0) } ?? .waiting(r.state) }
            if r.collision || r.keptInPlace { return r.songId.map { .add(songId: $0) } ?? .waiting(r.state) }
            if r.keepNeedsAttention || r.keepFailed || r.notForMe != nil || r.notForMeNeedsAttention { return .failed }
            if r.keep != nil || r.songId == nil { return .waiting(r.state) }
            return .keep(r.id)
        case .kept:
            if r.keepNeedsAttention { return .failed }
            if r.keep != nil || r.relinkPending == true { return .waiting(r.state) }
            return r.songId.map { .add(songId: $0) } ?? .waiting(r.state)
        default:
            return .waiting(r.state)
        }
    }

    /// The library's song for `recording`: one whose recording MBID is the same, else one with the same artist, title
    /// and length (within 3 s). Never by name alone.
    public static func librarySong(for recording: ExternalRecording, mbidMatches: [Song], textMatches: [Song]) -> Song? {
        if let mbid = recording.recordingMBID, let hit = mbidMatches.first(where: { $0.recordingMBID == mbid }) {
            return hit
        }
        return textMatches.first {
            SongIdentity.same(title: $0.title, artist: $0.artist, duration: $0.duration,
                              as: recording.title, artist: recording.artist, duration: recording.duration)
        }
    }
}

/// D101: the pending adds, beside the requests: `Application Support/Magpie/playlist-adds-<instance>.json`, one file per
/// Lidarr (`LidarrClient.instanceScope`, like `RequestStore`), atomic, excluded from backup, removed on sign-out with
/// the requests (`RequestStore.eraseAll`). A separate file, so requests saved before round 14 are untouched and an
/// unreadable entry never costs a request.
public actor PlaylistAddStore {
    public static func defaultURL(in directory: URL = URL.applicationSupportDirectory, instance: String) -> URL {
        directory.appending(path: "Magpie/playlist-adds-\(instance).json")
    }

    /// At most this many waiting adds are kept.
    public static let limit = 500

    nonisolated let fileURL: URL?
    private var memory: [PendingPlaylistAdd] = []

    public init(fileURL: URL?) { self.fileURL = fileURL }

    /// The saved adds; empty when none. A file that isn't a list is moved aside; an entry that doesn't decode is dropped.
    public func load() throws -> [PendingPlaylistAdd] {
        guard let fileURL else { return memory }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw RequestStoreError.unavailable }
        guard let rows = try? JSONDecoder().decode([Lenient].self, from: data) else {
            let aside = fileURL.deletingLastPathComponent()
                .appending(path: "\(fileURL.lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return []
        }
        return Array(rows.compactMap(\.value).prefix(Self.limit))
    }

    public func save(_ adds: [PendingPlaylistAdd]) throws {
        let adds = Array(adds.prefix(Self.limit))
        guard let fileURL else { memory = adds; return }
        try AtomicFile.write(adds, to: fileURL)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = fileURL
        try? file.setResourceValues(values)
    }

    private struct Lenient: Decodable {
        let value: PendingPlaylistAdd?
        init(from decoder: Decoder) throws { value = try? PendingPlaylistAdd(from: decoder) }
    }
}
