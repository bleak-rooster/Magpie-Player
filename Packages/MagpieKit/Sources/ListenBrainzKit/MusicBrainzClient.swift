import Foundation
import MagpieCore

public enum MusicBrainzError: Error, Sendable, Equatable {
    case notFound
    case http(status: Int)
    case decoding
}

public struct MBReleaseGroup: Sendable, Hashable {
    public var id: MBID
    /// `Album`, `Single`, `EP`, ... (nil when MusicBrainz has none).
    public var primaryType: String?
    public var secondaryTypes: [String]

    public init(id: MBID, primaryType: String? = nil, secondaryTypes: [String] = []) {
        self.id = id
        self.primaryType = primaryType
        self.secondaryTypes = secondaryTypes
    }
}

public struct MBRelease: Sendable, Hashable {
    public var id: MBID
    public var title: String
    /// MusicBrainz dates are partial: `1985`, `1985-03`, or `1985-03-12`.
    public var date: String?
    public var status: String?
    public var releaseGroup: MBReleaseGroup

    public init(id: MBID, title: String, date: String? = nil, status: String? = nil, releaseGroup: MBReleaseGroup) {
        self.id = id
        self.title = title
        self.date = date
        self.status = status
        self.releaseGroup = releaseGroup
    }
}

public struct MBRecording: Sendable, Hashable {
    public var id: MBID
    public var title: String
    public var releases: [MBRelease]
    public var isrcs: [String]
    /// The credited artists' MBIDs, in credit order (the first is the main artist).
    public var artistIds: [MBID]
    /// Length in seconds, when MusicBrainz knows it.
    public var length: TimeInterval?
    /// Round 19: the credited artists' names, in the order of `artistIds` (empty when MusicBrainz sent none).
    public var artistNames: [String]

    public init(id: MBID, title: String, releases: [MBRelease], isrcs: [String] = [], artistIds: [MBID] = [],
                length: TimeInterval? = nil, artistNames: [String] = []) {
        self.id = id
        self.title = title
        self.releases = releases
        self.isrcs = isrcs
        self.artistIds = artistIds
        self.length = length
        self.artistNames = artistNames
    }
}

/// MusicBrainz WS/2. Called on a Try tap (A8), an outside page opened (R19) or a search's album tracklists (round 14,
/// D95: at most three releases per search), never per search row. Calls are spaced at 1 per second.
public actor MusicBrainzClient {
    /// MusicBrainz asks for an app name, version and contact URL. The caller passes the app's own version.
    public static func userAgent(version: String) -> String { "Magpie/\(version) ( https://github.com/bleak-rooster )" }
    public static let base = URL(string: "https://musicbrainz.org")!

    let transport: HTTPTransport
    let userAgent: String
    let limiter: RateLimiter

    public init(transport: HTTPTransport, userAgent: String,
                limiter: RateLimiter = RateLimiter(perSecond: 1)) {
        self.transport = transport
        self.userAgent = userAgent
        self.limiter = limiter
    }

    /// The recording with its releases. Round 19: a lookup lists at most 25 releases, and a hit is on dozens (Espresso:
    /// 73, most of them compilations), so its own single could be missing; then the whole list is browsed (`allReleases`).
    public func recording(_ mbid: MBID) async throws -> MBRecording {
        let data = try await get("ws/2/recording/\(mbid.rawValue)",
                                 [URLQueryItem(name: "inc", value: "releases+release-groups+isrcs+artist-credits")])
        guard let dto = try? JSONDecoder().decode(RecordingDTO.self, from: data), var recording = dto.recording else {
            throw MusicBrainzError.decoding
        }
        if recording.releases.count >= Self.lookupReleaseCap, let all = try? await allReleases(recording: mbid), !all.isEmpty {
            recording.releases = all
        }
        return recording
    }

    /// The most releases a recording lookup lists.
    static let lookupReleaseCap = 25
    /// Pages of 100 browsed at most for one recording's releases (300 releases).
    static let releasePages = 3

    /// Round 19: every release of the recording (browsed 100 at a time, at most `releasePages`).
    public func allReleases(recording mbid: MBID) async throws -> [MBRelease] {
        var releases: [MBRelease] = []
        for page in 0..<Self.releasePages {
            let data = try await get("ws/2/release", [
                URLQueryItem(name: "recording", value: mbid.rawValue),
                URLQueryItem(name: "inc", value: "release-groups"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "offset", value: String(page * 100)),
            ])
            guard let dto = try? JSONDecoder().decode(ReleaseBrowseDTO.self, from: data) else { throw MusicBrainzError.decoding }
            let batch = dto.releases?.values ?? []
            releases += batch.compactMap(\.release)
            if batch.isEmpty || (page + 1) * 100 >= (dto.releaseCount ?? 0) { break }
        }
        return releases
    }

    /// Round 19: recordings named `title` by `artist` (MusicBrainz's search, both phrases quoted), best first. Callers
    /// check the title, artist and length themselves: the search's own score is never trusted alone.
    public func searchRecordings(title: String, artist: String, limit: Int = 25) async throws -> [MBRecording] {
        func phrase(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: " ").replacingOccurrences(of: "\"", with: " ") + "\""
        }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty, !artist.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }
        return try await search("recording:\(phrase(title)) AND artist:\(phrase(artist))", limit: limit)
    }

    private func search(_ query: String, limit: Int) async throws -> [MBRecording] {
        let data = try await get("ws/2/recording", [URLQueryItem(name: "query", value: query),
                                                    URLQueryItem(name: "limit", value: String(limit))])
        guard let dto = try? JSONDecoder().decode(RecordingSearchDTO.self, from: data) else { throw MusicBrainzError.decoding }
        return dto.recordings?.values.compactMap(\.recording) ?? []
    }

    /// Times a 503 (MusicBrainz busy: its rate limit) is waited out before it is thrown.
    static let busyRetries = 2

    /// One GET, spaced by the limiter; a 503 is waited out (`busyRetries`, 1.5 s, then 3 s) before it is thrown.
    private func get(_ path: String, _ query: [URLQueryItem]) async throws -> Data {
        guard let url = ServerEndpoint(bases: [Self.base]).url(
            Self.base, path: path, query: query + [URLQueryItem(name: "fmt", value: "json")]) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var attempt = 0
        while true {
            try await limiter.wait()
            let (data, response) = try await transport.send(request)
            switch response.statusCode {
            case 200..<300: return data
            case 404: throw MusicBrainzError.notFound
            case 503 where attempt < Self.busyRetries:
                attempt += 1
                try await Task.sleep(for: .milliseconds(1500 * attempt))
            default: throw MusicBrainzError.http(status: response.statusCode)
            }
        }
    }
}

private struct ReleaseBrowseDTO: Decodable {
    var releases: LossyArray<RecordingDTO.ReleaseDTO>?
    var releaseCount: Int?
    enum CodingKeys: String, CodingKey { case releases, releaseCount = "release-count" }
}

private struct RecordingSearchDTO: Decodable {
    var recordings: LossyArray<RecordingDTO>?
}

private struct RecordingDTO: Decodable {
    var id: String
    var title: String?
    var releases: LossyArray<ReleaseDTO>?
    var isrcs: [String]?
    var artistCredit: LossyArray<CreditDTO>?
    /// Milliseconds.
    var length: Double?

    enum CodingKeys: String, CodingKey { case id, title, releases, isrcs, length, artistCredit = "artist-credit" }

    struct CreditDTO: Decodable {
        struct ArtistDTO: Decodable { var id: String?; var name: String? }
        var artist: ArtistDTO?
        /// The name as credited ("ROSÉ"); the artist's own name when missing.
        var name: String?
    }

    var recording: MBRecording? {
        guard let id = MBID(id) else { return nil }
        let credits = artistCredit?.values.filter { $0.artist?.id.flatMap(MBID.init) != nil } ?? []
        return MBRecording(id: id, title: (title ?? "").capped,
                           releases: releases?.values.compactMap(\.release) ?? [],
                           isrcs: (isrcs ?? []).map(\.capped).filter { !$0.isEmpty },
                           artistIds: credits.compactMap { $0.artist?.id.flatMap(MBID.init) },
                           length: length.flatMap { $0 > 0 ? $0 / 1000 : nil },
                           artistNames: credits.map { ($0.name ?? $0.artist?.name ?? "").capped })
    }

    struct ReleaseDTO: Decodable {
        var id: String?
        var title: String?
        var date: String?
        var status: String?
        var releaseGroup: GroupDTO?

        enum CodingKeys: String, CodingKey { case id, title, date, status, releaseGroup = "release-group" }

        var release: MBRelease? {
            guard let id = id.flatMap(MBID.init), let group = releaseGroup?.group else { return nil }
            let date = date?.capped
            let status = status?.capped
            return MBRelease(id: id, title: (title ?? "").capped,
                             date: (date?.isEmpty == false) ? date : nil,
                             status: (status?.isEmpty == false) ? status : nil, releaseGroup: group)
        }
    }

    struct GroupDTO: Decodable {
        var id: String?
        var primaryType: String?
        var secondaryTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case id, primaryType = "primary-type", secondaryTypes = "secondary-types"
        }

        var group: MBReleaseGroup? {
            guard let id = id.flatMap(MBID.init) else { return nil }
            let primary = primaryType?.capped
            return MBReleaseGroup(id: id, primaryType: (primary?.isEmpty == false) ? primary : nil,
                                  secondaryTypes: (secondaryTypes ?? []).map(\.capped))
        }
    }
}
