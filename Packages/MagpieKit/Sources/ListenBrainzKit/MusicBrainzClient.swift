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

    public init(id: MBID, title: String, releases: [MBRelease], isrcs: [String] = [], artistIds: [MBID] = [],
                length: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.releases = releases
        self.isrcs = isrcs
        self.artistIds = artistIds
        self.length = length
    }
}

/// MusicBrainz WS/2. Call only on a Try tap, never per search row (A8). Calls are spaced at 1 per second.
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

    public func recording(_ mbid: MBID) async throws -> MBRecording {
        try await limiter.wait()
        guard let url = ServerEndpoint(bases: [Self.base]).url(
            Self.base, path: "ws/2/recording/\(mbid.rawValue)",
            query: [URLQueryItem(name: "inc", value: "releases+release-groups+isrcs+artist-credits"),
                    URLQueryItem(name: "fmt", value: "json")]) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 404: throw MusicBrainzError.notFound
        default: throw MusicBrainzError.http(status: response.statusCode)
        }
        guard let dto = try? JSONDecoder().decode(RecordingDTO.self, from: data),
              let id = MBID(dto.id) else { throw MusicBrainzError.decoding }
        return MBRecording(id: id, title: (dto.title ?? "").capped,
                           releases: dto.releases?.values.compactMap(\.release) ?? [],
                           isrcs: (dto.isrcs ?? []).map(\.capped).filter { !$0.isEmpty },
                           artistIds: dto.artistCredit?.values.compactMap { $0.artist?.id.flatMap(MBID.init) } ?? [],
                           length: dto.length.flatMap { $0 > 0 ? $0 / 1000 : nil })
    }
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
        struct ArtistDTO: Decodable { var id: String? }
        var artist: ArtistDTO?
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
