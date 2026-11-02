import Foundation
import MagpieCore

public enum LidarrError: Error, Sendable, Equatable {
    case http(status: Int)
    case unauthorized
    case decoding
}

/// Read-only Lidarr v1 client. It can only issue GETs: writes go through `LidarrWriteGate` (G1), which owns
/// the only code path that sends POST, PUT or DELETE (see `LidarrConnection` in WriteGate.swift).
public struct LidarrClient: Sendable {
    let connection: LidarrConnection

    /// `base` is the Lidarr root, optionally with a reverse-proxy path (`https://host/lidarr`); it is preserved.
    public init(base: URL, apiKey: String, transport: HTTPTransport) {
        self.connection = LidarrConnection(base: base, apiKey: apiKey, transport: transport)
    }

    /// Identifies this Lidarr server for on-device records (ledger, requests): a hash of the address and the
    /// API key, which is unique per Lidarr install. Lidarr has no stable server id in `/system/status`
    /// (`instanceName` is a free label). A changed address or regenerated key starts a fresh scope: Magpie
    /// then forgets earlier requests rather than risk acting on another server's ids.
    public var instanceScope: String { connection.instanceScope }

    // MARK: - Plumbing

    private func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        try await connection.get(path, query)
    }

    private func ok(_ path: String, _ query: [URLQueryItem] = []) async throws -> Data {
        let (data, response) = try await get(path, query)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw LidarrError.unauthorized
        default: throw LidarrError.http(status: response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        let data = try await ok(path, query)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw LidarrError.decoding }
    }

    /// Raw JSON of a GET (provisioning reads schemas and existing profiles whole, A15).
    func json(_ path: String) async throws -> JSONValue { try await decode(JSONValue.self, path) }

    private func list<T: Decodable>(_ type: T.Type, _ path: String, _ query: [URLQueryItem] = []) async throws -> [T] {
        try await decode(LossyArray<T>.self, path, query).values
    }

    // MARK: - System

    public func status() async throws -> LidarrStatus { try await decode(LidarrStatus.self, "system/status") }

    public func health() async throws -> [HealthIssue] { try await list(HealthIssue.self, "health") }

    public func rootFolders() async throws -> [RootFolder] { try await list(RootFolder.self, "rootfolder") }

    public func qualityProfiles() async throws -> [QualityProfile] { try await list(QualityProfile.self, "qualityprofile") }

    public func metadataProfiles() async throws -> [MetadataProfile] { try await list(MetadataProfile.self, "metadataprofile") }

    public func tags() async throws -> [LidarrTag] { try await list(LidarrTag.self, "tag") }

    /// Text of each installed plugin (every string value, lower-cased). `nil` when `/system/plugins` is 404 (A15).
    public func pluginTexts() async throws -> [String]? {
        let (data, response) = try await get("system/plugins")
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            throw response.statusCode == 401 ? LidarrError.unauthorized : LidarrError.http(status: response.statusCode)
        }
        // Measured first: a deeply nested answer would overflow the stack in JSONSerialization (crash hunt 4).
        guard let items = JSONNesting.object(with: data) as? [Any] else { return [] }
        return items.map { Self.strings(in: $0).joined(separator: " ").lowercased() }
    }

    /// A15: `/system/plugins` answering 404 means "not detected". A 200 with no plugins is not detected either.
    public func pluginsDetected() async throws -> Bool {
        !(try await pluginTexts() ?? []).isEmpty
    }

    /// G3: `config/mediamanagement.recycleBin`. `nil` when empty, which means deletes are permanent.
    public func recycleBin() async throws -> String? {
        let data = try await ok("config/mediamanagement")
        guard let object = JSONNesting.object(with: data) as? [String: Any],
              let path = object["recycleBin"] as? String else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func strings(in value: Any) -> [String] {
        switch value {
        case let s as String: [s]
        case let a as [Any]: a.flatMap(strings)
        case let d as [String: Any]: d.values.flatMap(strings)
        default: []
        }
    }

    // MARK: - Lookup and search

    /// Reliable ID lookup (A10). `nil` when Lidarr knows no artist with that MBID.
    public func artistLookup(mbid: MBID) async throws -> LidarrArtistLookup? {
        let hits = try await list(LidarrArtistLookup.self, "artist/lookup",
                                  [URLQueryItem(name: "term", value: "lidarr:" + mbid.rawValue)])
        return hits.first { $0.foreignArtistId == mbid }
    }

    /// Lidarr's artist search by name (`artist/lookup?term=`): MusicBrainz artists, with their disambiguation and type.
    public func artistLookup(term: String) async throws -> [LidarrArtistLookup] {
        try await list(LidarrArtistLookup.self, "artist/lookup", [URLQueryItem(name: "term", value: term)])
    }

    /// The lookup row for `mbid` as raw JSON, the base of the single atomic `POST /artist` (A6). `nil` when
    /// Lidarr knows no artist with that MBID.
    public func artistLookupJSON(mbid: MBID) async throws -> JSONValue? {
        let data = try await ok("artist/lookup", [URLQueryItem(name: "term", value: "lidarr:" + mbid.rawValue)])
        guard let rows = (try? JSONDecoder().decode(JSONValue.self, from: data))?.arrayValue else {
            throw LidarrError.decoding
        }
        return rows.first { $0["foreignArtistId"]?.stringValue.flatMap(MBID.init) == mbid }
    }

    /// Text search (A10: flaky SkyHook search). Only artist and album rows are returned.
    public func search(term: String) async throws -> [LidarrSearchHit] {
        try await list(LidarrSearchHit.self, "search", [URLQueryItem(name: "term", value: term)])
    }

    // MARK: - Library

    public func artists() async throws -> [LidarrArtist] { try await list(LidarrArtist.self, "artist") }

    public func artist(id: Int) async throws -> LidarrArtist { try await decode(LidarrArtist.self, "artist/\(id)") }

    public func albums(artistId: Int) async throws -> [LidarrAlbum] {
        try await list(LidarrAlbum.self, "album", [URLQueryItem(name: "artistId", value: String(artistId))])
    }

    /// Every track file of the artist (Keep checks where the files really are after a move, A3).
    public func trackFiles(artistId: Int) async throws -> [TrackFile] {
        try await list(TrackFile.self, "trackfile", [URLQueryItem(name: "artistId", value: String(artistId))])
    }

    public func trackFiles(albumId: Int) async throws -> [TrackFile] {
        try await list(TrackFile.self, "trackfile", [URLQueryItem(name: "albumId", value: String(albumId))])
    }

    /// One track file (the write gate reads each file before it lets a delete through, FM1).
    public func trackFile(id: Int) async throws -> TrackFile { try await decode(TrackFile.self, "trackfile/\(id)") }

    // MARK: - Progress

    /// Queue entries for the given albums (all entries when `albumIds` is empty). A14: use `QueueItem.progress`.
    public func queueDetails(albumIds: [Int]) async throws -> [QueueItem] {
        try await list(QueueItem.self, "queue/details", albumIds.map { URLQueryItem(name: "albumIds", value: String($0)) })
    }

    /// Round 12 item 6 (Settings › Downloads in Lidarr): the whole queue, with each row's artist and album names.
    public func queueDetailsNamed() async throws -> [QueueItem] {
        try await list(QueueItem.self, "queue/details", [URLQueryItem(name: "includeArtist", value: "true"),
                                                         URLQueryItem(name: "includeAlbum", value: "true")])
    }

    /// The download clients set up in Lidarr (R17: which ones are Soulseek). Read only; never written (G5).
    public func downloadClients() async throws -> [DownloadClientInfo] {
        try await list(DownloadClientInfo.self, "downloadclient")
    }

    public func historySince(_ date: Date) async throws -> [HistoryEvent] {
        try await list(HistoryEvent.self, "history/since", [URLQueryItem(name: "date", value: LidarrDates.format(date))])
    }

    public func command(id: Int) async throws -> CommandStatus { try await decode(CommandStatus.self, "command/\(id)") }

    public func commands() async throws -> [CommandStatus] { try await list(CommandStatus.self, "command") }

    // MARK: - Filesystem

    /// The folders directly inside `path` on Lidarr's filesystem, as Lidarr spells them (no trailing `/`).
    /// Keep compares these loosely (case, Unicode) against the folder it would move into (G4).
    public func directories(in path: String) async throws -> [String] {
        try await listing(path, files: false).directories.map(Self.trimmed)
    }

    /// The files directly inside `path` on Lidarr's filesystem (Keep checks the moved files are really there:
    /// Lidarr 3.2 doesn't update track file paths when it moves an artist, verified on the dev stack).
    public func files(in path: String) async throws -> [String] {
        try await listing(path, files: true).files.map(Self.trimmed)
    }

    /// The folders and files directly inside `path` on Lidarr's filesystem, in one listing (Not for me walks the
    /// artist folder before it removes the artist: only an empty folder lets it go). A missing `path` lists the
    /// closest existing folder instead, so callers check every entry is inside the folder they asked for.
    public func contents(in path: String) async throws -> (directories: [String], files: [String]) {
        let listing = try await listing(path, files: true)
        return (listing.directories.map(Self.trimmed), listing.files.map(Self.trimmed))
    }

    private func listing(_ path: String, files: Bool) async throws -> FilesystemListing {
        let folder = Self.trimmed(path)
        return try await decode(FilesystemListing.self, "filesystem", [
            URLQueryItem(name: "path", value: folder == "/" ? "/" : folder + "/"),
            URLQueryItem(name: "includeFiles", value: files ? "true" : "false"),
        ])
    }

    private static func trimmed(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Whether a directory exists on Lidarr's filesystem. Lidarr lists the closest existing folder for a missing
    /// path (and answers 200 for an empty folder), so this lists the parent and looks for the directory in it.
    public func filesystemExists(path: String) async throws -> Bool {
        var target = path
        while target.count > 1, target.hasSuffix("/") { target.removeLast() }
        guard target != "/", let slash = target.lastIndex(of: "/") else { return target == "/" }
        let parent = String(target[..<slash]) + "/"
        let listing = try await decode(FilesystemListing.self, "filesystem", [
            URLQueryItem(name: "path", value: parent), URLQueryItem(name: "includeFiles", value: "false"),
        ])
        return listing.directories.contains { entry in
            var e = entry
            while e.count > 1, e.hasSuffix("/") { e.removeLast() }
            return e == target
        }
    }
}
