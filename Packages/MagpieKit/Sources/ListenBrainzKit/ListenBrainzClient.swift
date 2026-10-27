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
    private let apiTimeout: TimeInterval
    private let limiter: RateLimiter?

    /// `token` is only ever attached to `api.listenbrainz.org` requests. Labs gets no credentials (A9).
    /// - Parameters:
    ///   - apiTimeout: the deadline of each `api.listenbrainz.org` call ("Made for you" degrades silently, like search).
    ///   - limiter: spaces the `api.listenbrainz.org` calls (shared app-wide). Labs search never waits on it.
    public init(transport: HTTPTransport, token: String?, labsTimeout: TimeInterval = 5, apiTimeout: TimeInterval = 5,
                limiter: RateLimiter? = nil) {
        self.transport = transport
        self.token = (token?.isEmpty == false) ? token : nil
        self.labsTimeout = labsTimeout
        self.apiTimeout = apiTimeout
        self.limiter = limiter
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

    /// The user name the token belongs to (`/1/validate-token`). Throws `unauthorized` without a valid token;
    /// with no token nothing is asked.
    public func tokenUser() async throws -> String {
        guard token != nil else { throw ListenBrainzError.unauthorized }
        let data = try await api("1/validate-token")
        guard let reply = try? JSONDecoder().decode(ValidateReply.self, from: data) else { throw ListenBrainzError.decoding }
        guard reply.valid == true, let name = reply.user_name?.capped, !name.isEmpty else {
            throw ListenBrainzError.unauthorized
        }
        return name
    }

    public func createdForPlaylists(user: String, count: Int = 25) async throws -> [LBPlaylistRef] {
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        let data = try await api("1/user/\(name)/playlists/createdfor",
                                 query: [URLQueryItem(name: "count", value: String(max(1, min(count, 100))))])
        guard let page = try? JSONDecoder().decode(CreatedForPage.self, from: data) else { throw ListenBrainzError.decoding }
        return page.playlists.values.compactMap(\.ref)
    }

    /// A playlist's songs (`/1/playlist/{mbid}`, JSPF), in order. Tracks without a title or artist are dropped.
    public func playlistTracks(_ id: MBID) async throws -> [ExternalRecording] {
        let data = try await api("1/playlist/\(id.rawValue)")
        guard let page = try? JSONDecoder().decode(PlaylistPage.self, from: data) else { throw ListenBrainzError.decoding }
        return page.playlist.track?.values.compactMap(\.recording) ?? []
    }

    /// A GET to `api.listenbrainz.org` with the token (when set), spaced by the limiter, within `apiTimeout`.
    private func api(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var request = URLRequest(url: ServerEndpoint(bases: [Self.apiBase]).url(Self.apiBase, path: path, query: query))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = apiTimeout
        if let token { request.setValue("Token \(token)", forHTTPHeaderField: "Authorization") }
        Log.request(request, category: "listenbrainz")
        let limiter = self.limiter
        return try await sendWithDeadline(request, seconds: apiTimeout, before: { try await limiter?.wait() })
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
    /// `before` (the limiter's wait) runs inside the deadline.
    private func sendWithDeadline(_ request: URLRequest, seconds: TimeInterval,
                                  before: @escaping @Sendable () async throws -> Void = {}) async throws -> Data {
        let transport = self.transport
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await before()
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

private struct ValidateReply: Decodable {
    var valid: Bool?
    var user_name: String?
}

private struct PlaylistPage: Decodable {
    var playlist: Body

    struct Body: Decodable { var track: LossyArray<Track>? }

    struct Track: Decodable {
        var title: String?
        var creator: String?
        var album: String?
        /// Milliseconds.
        var duration: Double?
        /// `https://musicbrainz.org/recording/<mbid>`: a string, or (newer servers) an array of them.
        var identifier: Identifiers?
        var `extension`: [String: TrackExt]?

        var recording: ExternalRecording? {
            guard let title = title?.capped, !title.isEmpty,
                  let artist = creator?.capped, !artist.isEmpty else { return nil }
            let album = album?.capped
            let ext = self.extension?["https://musicbrainz.org/doc/jspf#track"]
            return ExternalRecording(recordingMBID: identifier?.values.lazy.compactMap { Self.mbid($0, kind: "recording") }.first,
                                     artistMBID: ext?.artist_identifiers?.lazy.compactMap { Self.mbid($0, kind: "artist") }.first,
                                     title: title, artist: artist,
                                     releaseTitle: (album?.isEmpty == false) ? album : nil,
                                     duration: duration.flatMap { $0 > 0 && $0.isFinite ? $0 / 1000 : nil },
                                     source: .listenBrainz)
        }

        /// The MBID at the end of a `https://musicbrainz.org/<kind>/<mbid>` URL.
        static func mbid(_ url: String, kind: String) -> MBID? {
            let parts = url.split(separator: "/")
            guard parts.count >= 2, parts[parts.count - 2] == kind else { return nil }
            return MBID(String(parts[parts.count - 1]))
        }
    }

    struct TrackExt: Decodable { var artist_identifiers: [String]? }

    struct Identifiers: Decodable {
        var values: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let one = try? c.decode(String.self) { values = [one] } else { values = (try? c.decode([String].self)) ?? [] }
        }
    }
}

