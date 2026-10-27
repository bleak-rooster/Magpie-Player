import Foundation
import MagpieCore

public enum ListenBrainzError: Error, Sendable, Equatable {
    case http(status: Int)
    case unauthorized
    case timedOut
    case decoding
}

public struct LBPlaylistRef: Sendable, Hashable {
    public var id: MBID
    public var title: String
    public var date: String?
    public var expiresAt: String?
    /// `daily-jams`, `weekly-jams`, `weekly-exploration`, ...
    public var sourcePatch: String?

    public init(id: MBID, title: String, date: String? = nil, expiresAt: String? = nil, sourcePatch: String? = nil) {
        self.id = id; self.title = title; self.date = date; self.expiresAt = expiresAt; self.sourcePatch = sourcePatch
    }
}

public struct ListenBrainzClient: Sendable {
    public static let labsBase = URL(string: "https://labs.api.listenbrainz.org")!
    public static let apiBase = URL(string: "https://api.listenbrainz.org")!

    private let transport: HTTPTransport
    private let token: String?
    private let labsTimeout: TimeInterval

    /// `token` is only ever attached to `api.listenbrainz.org` requests. Labs gets no credentials (A9).
    public init(transport: HTTPTransport, token: String?, labsTimeout: TimeInterval = 5) {
        self.transport = transport
        self.token = (token?.isEmpty == false) ? token : nil
        self.labsTimeout = labsTimeout
    }

    // MARK: - Labs recording search (no token, 5 s)

    public func searchRecordings(_ q: String, limit: Int = 15) async throws -> [ExternalRecording] {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        var request = URLRequest(url: ServerEndpoint(bases: [Self.labsBase])
            .url(Self.labsBase, path: "recording-search/json", query: [URLQueryItem(name: "query", value: query)]))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = labsTimeout
        let data = try await sendWithDeadline(request, seconds: labsTimeout)
        guard let rows = try? JSONDecoder().decode(LossyArray<LabsRow>.self, from: data) else {
            throw ListenBrainzError.decoding
        }
        return rows.values.compactMap(\.recording).prefix(limit).map { $0 }
    }

    // MARK: - "Made for you" (token, api.listenbrainz.org)

    public func createdForPlaylists(user: String, count: Int = 25) async throws -> [LBPlaylistRef] {
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        var request = URLRequest(url: ServerEndpoint(bases: [Self.apiBase]).url(
            Self.apiBase, path: "1/user/\(name)/playlists/createdfor",
            query: [URLQueryItem(name: "count", value: String(max(1, min(count, 100))))]))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Token \(token)", forHTTPHeaderField: "Authorization") }
        Log.request(request, category: "listenbrainz")
        let (data, response) = try await transport.send(request)
        try Self.check(response)
        guard let page = try? JSONDecoder().decode(CreatedForPage.self, from: data) else { throw ListenBrainzError.decoding }
        return page.playlists.values.compactMap(\.ref)
    }

    // MARK: - Plumbing

    static func check(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw ListenBrainzError.unauthorized
        default: throw ListenBrainzError.http(status: response.statusCode)
        }
    }

    /// The transport's own timeout may differ (URLSessionTransport applies its default), so the deadline is enforced here.
    private func sendWithDeadline(_ request: URLRequest, seconds: TimeInterval) async throws -> Data {
        let transport = self.transport
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (data, response) = try await transport.send(request)
                try Self.check(response)
                return data
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ListenBrainzError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Data()
        }
    }
}

// MARK: - DTOs (decoded defensively)

private struct LabsRow: Decodable {
    var recording_name: String?
    var recording_mbid: String?
    var release_name: String?
    var artist_credit_name: String?

    var recording: ExternalRecording? {
        guard let title = recording_name?.capped, !title.isEmpty,
              let artist = artist_credit_name?.capped, !artist.isEmpty else { return nil }
        let release = release_name?.capped
        return ExternalRecording(recordingMBID: recording_mbid.flatMap(MBID.init), artistMBID: nil,
                                 title: title, artist: artist,
                                 releaseTitle: (release?.isEmpty == false) ? release : nil,
                                 duration: nil, source: .listenBrainz)
    }
}

private struct CreatedForPage: Decodable {
    var playlists: LossyArray<Item>

    struct Item: Decodable {
        var playlist: Playlist?
        var ref: LBPlaylistRef? {
            guard let p = playlist, let identifier = p.identifier,
                  let last = identifier.split(separator: "/").last, let id = MBID(String(last)),
                  let title = p.title?.capped, !title.isEmpty else { return nil }
            let ext = p.extension?["https://musicbrainz.org/doc/jspf#playlist"]?.additional_metadata
            return LBPlaylistRef(id: id, title: title, date: p.date?.capped,
                                 expiresAt: ext?.expires_at?.capped, sourcePatch: ext?.algorithm_metadata?.source_patch?.capped)
        }
    }

    struct Playlist: Decodable {
        var identifier: String?
        var title: String?
        var date: String?
        var `extension`: [String: Ext]?
    }

    struct Ext: Decodable { var additional_metadata: Meta? }
    struct Meta: Decodable {
        var expires_at: String?
        var algorithm_metadata: Algo?
    }
    struct Algo: Decodable { var source_patch: String? }
}
