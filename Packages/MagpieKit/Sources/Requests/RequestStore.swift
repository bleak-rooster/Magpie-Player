import Foundation
import MagpieCore

public struct RequestID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }
}

/// How fast a request is likely to arrive (D8, review of D8): Standard when Tubifarry is detected, else Patient.
/// Quick fetch needs the Mac helper and is not in v1.
public enum Tier: String, Codable, Sendable, CaseIterable {
    case quickFetch, standard, patient

    public var title: String {
        switch self {
        case .quickFetch: "Quick fetch"
        case .standard: "Standard"
        case .patient: "Patient"
        }
    }

    /// The honest estimate shown before and while waiting.
    public var estimate: String {
        switch self {
        case .quickFetch: "usually under a minute"
        case .standard: "usually a few minutes"
        case .patient: "can take a few hours"
        }
    }

    /// D8: waits over ~10 minutes get "Ask for it" and no spinning wait screen.
    public var asksInsteadOfWaiting: Bool { self == .patient }
}

/// One Try: a song the owner asked Magpie to bring home, and the bookkeeping the runner needs to resume it
/// after a relaunch. Everything here is persisted (`RequestStore`).
public struct MagpieRequest: Sendable, Codable, Equatable, Identifiable {
    public var id: RequestID
    public var recording: ExternalRecording
    public var state: RequestState
    public var tier: Tier
    public var createdAt: Date
    /// The release being brought in (known once resolved).
    public var albumTitle: String?

    public var updatedAt: Date
    public var plan: Plan?
    public var lidarrArtistId: Int?
    public var albumId: Int?
    /// Root folder the artist was added to (new-artist branch), for the ledger.
    public var root: String?
    /// `POST /artist` was sent for this request. Set (and saved) before the write, so after a relaunch the
    /// artist is never mistaken for one the owner already had.
    public var addSent: Bool = false
    /// When `POST /artist` was sent. Lidarr applies `albumsToMonitor` only when its refresh of the new artist
    /// finishes, so for a while after this the album's monitored flag isn't final.
    public var addedAt: Date?
    /// Another request already asked for this release group; this one only follows it and never writes (G7).
    public var joinedTo: RequestID?
    /// The add already started the search (`searchForMissingAlbums`) or a joined request: skip the next AlbumSearch.
    public var skipNextSearch: Bool = false
    /// Runner contract of `RequestMachine.step`: the current waiting episode's reason, nil after forward progress.
    public var priorWait: WaitReason?
    public var searchStartedAt: Date?
    public var searchCommandId: Int?
    public var grabbed: Bool = false
    /// Date of the newest download failure already acted on.
    public var failureSeenAt: Date?
    public var lastScanAt: Date?
    /// When the request last entered `importing`.
    public var importingSince: Date?
    /// Set when the library still didn't list the song `RequestRunner.importingLimit` after import: the
    /// library is no longer polled for it until the owner taps Check again.
    public var notListedAt: Date?
    /// The library song once Navidrome lists it.
    public var songId: String?
    /// Cancel/fail clean-up (unmonitor) still to do.
    public var cleanupPending: Bool = false
    /// Lidarr's latest status message for the download, if any (display only).
    public var note: String?
    /// Finds mode was on, but the Finds root no longer checked out when the artist was added (G2): the song
    /// went into the library instead (B8).
    public var findsUnavailable: Bool {
        get { findsFellBack ?? false }
        set { findsFellBack = newValue ? true : nil }
    }
    /// Stored optional, so requests saved before Task 6.2a (no such key) still decode.
    var findsFellBack: Bool?

    // Keep (Task 6.2b). All optional, so requests saved before it still decode.

    /// A Keep that wrote to Lidarr and isn't settled yet (saved before the write, M6). While set, Keep never
    /// writes the move again: the runner only checks how it went (`RequestRunner.keep`, `tick`).
    public var keep: KeepProgress?
    /// Kept where it is: the main root already had a folder for the artist, so only `magpie-find` came off (G4).
    public var keptInPlace: Bool {
        get { stayedInFinds ?? false }
        set { stayedInFinds = newValue ? true : nil }
    }
    var stayedInFinds: Bool?
    /// The last Keep didn't go through (Lidarr couldn't move it); the find is as it was and can be kept again.
    public var keepFailed: Bool {
        get { lastKeepFailed ?? false }
        set { lastKeepFailed = newValue ? true : nil }
    }
    var lastKeepFailed: Bool?
    /// Kept and moved: the library song is looked up again by MBID (A3). False once found or given up; nil
    /// for requests that never moved.
    public var relinkPending: Bool?
    /// When the move was confirmed (the re-resolve gives up `RequestRunner.relinkLimit` after it).
    public var movedAt: Date?
    /// The library song's file type once re-resolved after Keep ("Lossless soon" until it is lossless).
    public var songSuffix: String?

    public init(id: RequestID = RequestID(), recording: ExternalRecording, tier: Tier, createdAt: Date) {
        self.id = id
        self.recording = recording
        self.state = .pending
        self.tier = tier
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Counts toward the limit of 5 (G7) and is polled: not finished and not yet ready.
    public var isActive: Bool { !state.isTerminal && state != .ready }

    /// Headed for (or added to) the Finds folder: a new artist added in Finds mode (Task 6.2a).
    public var isFind: Bool { plan?.mode == .finds }

    /// Imported by Lidarr but not listed by the library after the time limit (Needs attention).
    public var isNotListed: Bool { state == .importing && notListedAt != nil }
}

/// A Keep in flight (Task 6.2b), saved before its first Lidarr write so a relaunch never writes it twice.
public struct KeepProgress: Sendable, Codable, Equatable {
    public enum Phase: String, Sendable, Codable {
        /// `PUT /artist/editor` with the main root was (maybe) sent: wait for `BulkMoveArtist` (A3).
        case moving
        /// The destination existed: only `magpie-find` is being removed (G4).
        case untagging
        /// The move failed: `magpie-find` and the earlier quality profile are being put back.
        case restoring
    }

    public var phase: Phase
    public var startedAt: Date
    public var artistId: Int
    /// The artist folder before the move (inside the Finds root).
    public var fromPath: String
    public var findsRoot: String
    public var mainRoot: String
    public var findTagId: Int
    /// The artist's quality profile before Keep, to put back if the move fails.
    public var priorQualityProfileId: Int?
    /// The highest `/command` id Lidarr listed before the move was asked for: only later ones are this move.
    public var commandBaseline: Int
    public var lastCheckAt: Date?

    public init(phase: Phase, startedAt: Date, artistId: Int, fromPath: String, findsRoot: String, mainRoot: String,
                findTagId: Int, priorQualityProfileId: Int?, commandBaseline: Int) {
        self.phase = phase; self.startedAt = startedAt; self.artistId = artistId; self.fromPath = fromPath
        self.findsRoot = findsRoot; self.mainRoot = mainRoot; self.findTagId = findTagId
        self.priorQualityProfileId = priorQualityProfileId; self.commandBaseline = commandBaseline
    }
}

public enum RequestStoreError: Error, Equatable {
    /// The file exists but cannot be read right now (protected data before first unlock). Nothing is written
    /// until it can be read, so in-flight requests are never lost.
    case unavailable
}

/// The requests on disk (`Application Support/Magpie/requests.json`), written atomically with file protection.
public actor RequestStore {
    /// `Application Support/Magpie/requests-<instance>.json`: one file per Lidarr server
    /// (`LidarrClient.instanceScope`), so requests never cross servers.
    public static func defaultURL(in directory: URL = URL.applicationSupportDirectory, instance: String) -> URL {
        directory.appending(path: "Magpie/requests-\(instance).json")
    }

    private let fileURL: URL?
    private var memory: [MagpieRequest] = []

    /// `fileURL` nil keeps the requests in memory only.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// The saved requests; empty when there are none. A damaged file is moved aside and an empty list returned.
    public func load() throws -> [MagpieRequest] {
        guard let fileURL else { return memory }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw RequestStoreError.unavailable }
        do {
            return try JSONDecoder().decode([MagpieRequest].self, from: data)
        } catch {
            let aside = fileURL.deletingLastPathComponent()
                .appending(path: "\(fileURL.lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970))")
            do { try FileManager.default.moveItem(at: fileURL, to: aside) } catch { throw RequestStoreError.unavailable }
            Log.logger("requests").error("damaged requests file; kept aside, starting empty")
            return []
        }
    }

    public func save(_ requests: [MagpieRequest]) throws {
        guard let fileURL else { memory = requests; return }
        try AtomicFile.write(requests, to: fileURL)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = fileURL
        try? file.setResourceValues(values)
    }

    /// Forgets every request (sign-out). The Lidarr ledger is kept: it is the owner's undo map.
    public func erase() {
        memory = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }
}
