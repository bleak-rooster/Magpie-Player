import Foundation
import MagpieCore

public enum LidarrError: Error, Sendable, Equatable {
    case http(status: Int)
    case unauthorized
    case decoding
}

/// Read-only Lidarr v1 client. It issues GET requests only; writes arrive in Task 5.1 behind the write gate.
public struct LidarrClient: Sendable {
    private let endpoint: ServerEndpoint
    private let base: URL
    private let apiKey: String
    private let transport: HTTPTransport

    /// `base` is the Lidarr root, optionally with a reverse-proxy path (`https://host/lidarr`); it is preserved.
    public init(base: URL, apiKey: String, transport: HTTPTransport) {
        self.endpoint = ServerEndpoint(bases: [base])
        self.base = base
        self.apiKey = apiKey
        self.transport = transport
    }

    // MARK: - Plumbing

    private func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint.url(base, path: "api/v1/" + path, query: query))
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Log.request(request, category: "lidarr")
        return try await transport.send(request)
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
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return items.map { Self.strings(in: $0).joined(separator: " ").lowercased() }
    }

    /// A15: `/system/plugins` answering 404 means "not detected". A 200 with no plugins is not detected either.
    public func pluginsDetected() async throws -> Bool {
        !(try await pluginTexts() ?? []).isEmpty
    }

    /// G3: `config/mediamanagement.recycleBin`. `nil` when empty, which means deletes are permanent.
    public func recycleBin() async throws -> String? {
        let data = try await ok("config/mediamanagement")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    public func trackFiles(albumId: Int) async throws -> [TrackFile] {
        try await list(TrackFile.self, "trackfile", [URLQueryItem(name: "albumId", value: String(albumId))])
    }

    // MARK: - Progress

    /// Queue entries for the given albums (all entries when `albumIds` is empty). A14: use `QueueItem.progress`.
    public func queueDetails(albumIds: [Int]) async throws -> [QueueItem] {
        try await list(QueueItem.self, "queue/details", albumIds.map { URLQueryItem(name: "albumIds", value: String($0)) })
    }

    public func historySince(_ date: Date) async throws -> [HistoryEvent] {
        try await list(HistoryEvent.self, "history/since", [URLQueryItem(name: "date", value: LidarrDates.format(date))])
    }

    public func command(id: Int) async throws -> CommandStatus { try await decode(CommandStatus.self, "command/\(id)") }

    public func commands() async throws -> [CommandStatus] { try await list(CommandStatus.self, "command") }

    // MARK: - Filesystem

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
