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
    /// The library song once Navidrome lists it.
    public var songId: String?
    /// Cancel/fail clean-up (unmonitor) still to do.
    public var cleanupPending: Bool = false
    /// Lidarr's latest status message for the download, if any (display only).
    public var note: String?

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
}

public enum RequestStoreError: Error, Equatable {
    /// The file exists but cannot be read right now (protected data before first unlock). Nothing is written
    /// until it can be read, so in-flight requests are never lost.
    case unavailable
}

/// The requests on disk (`Application Support/Magpie/requests.json`), written atomically with file protection.
public actor RequestStore {
    public static func defaultURL(in directory: URL = URL.applicationSupportDirectory) -> URL {
        directory.appending(path: "Magpie/requests.json")
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
