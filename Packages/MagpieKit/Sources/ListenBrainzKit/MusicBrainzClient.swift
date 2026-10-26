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

    public init(id: MBID, title: String, releases: [MBRelease], isrcs: [String] = []) {
        self.id = id
        self.title = title
        self.releases = releases
        self.isrcs = isrcs
    }
}

/// MusicBrainz WS/2. Call only on a Try tap, never per search row (A8). Calls are spaced at 1 per second.
public actor MusicBrainzClient {
    public static let defaultUserAgent = "Magpie/0.1 ( https://github.com/bleak-rooster )"
    public static let base = URL(string: "https://musicbrainz.org")!

    private let transport: HTTPTransport
    private let userAgent: String
    private let limiter: RateLimiter

    public init(transport: HTTPTransport, userAgent: String = MusicBrainzClient.defaultUserAgent,
                limiter: RateLimiter = RateLimiter(perSecond: 1)) {
        self.transport = transport
        self.userAgent = userAgent
        self.limiter = limiter
    }

    public func recording(_ mbid: MBID) async throws -> MBRecording {
        try await limiter.wait()
        var request = URLRequest(url: ServerEndpoint(bases: [Self.base]).url(
            Self.base, path: "ws/2/recording/\(mbid.rawValue)",
            query: [URLQueryItem(name: "inc", value: "releases+release-groups+isrcs"),
                    URLQueryItem(name: "fmt", value: "json")]))
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
                           isrcs: (dto.isrcs ?? []).map(\.capped).filter { !$0.isEmpty })
    }
}

private struct RecordingDTO: Decodable {
    var id: String
    var title: String?
    var releases: LossyArray<ReleaseDTO>?
    var isrcs: [String]?

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
