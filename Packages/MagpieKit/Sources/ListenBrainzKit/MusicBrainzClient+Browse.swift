import Foundation
import MagpieCore

/// A release group as an artist's browse lists it (R19's outside artist page).
public struct MBReleaseGroupSummary: Sendable, Hashable {
    public var id: MBID
    public var title: String
    /// `Album`, `EP`, `Single`, ... (nil when MusicBrainz has none).
    public var primaryType: String?
    /// `Live`, `Compilation`, `Soundtrack`, ... (empty: a studio release).
    public var secondaryTypes: [String]
    /// Partial ISO date: `2019`, `2019-03` or `2019-03-15`.
    public var firstReleaseDate: String?

    public init(id: MBID, title: String, primaryType: String?, secondaryTypes: [String], firstReleaseDate: String?) {
        self.id = id; self.title = title; self.primaryType = primaryType; self.secondaryTypes = secondaryTypes
        self.firstReleaseDate = firstReleaseDate
    }
}

public struct MBTrack: Sendable, Hashable {
    public var recording: MBID
    public var title: String
    /// Seconds, when MusicBrainz knows it.
    public var length: TimeInterval?

    public init(recording: MBID, title: String, length: TimeInterval?) {
        self.recording = recording; self.title = title; self.length = length
    }
}

/// A release of a release group, with its tracklist (all media, in order).
public struct MBReleaseDetail: Sendable, Hashable {
    public var id: MBID
    public var title: String
    public var date: String?
    public var status: String?
    public var tracks: [MBTrack]

    public init(id: MBID, title: String, date: String?, status: String?, tracks: [MBTrack]) {
        self.id = id; self.title = title; self.date = date; self.status = status; self.tracks = tracks
    }
}

/// R19: browsing for the outside artist and album pages. Same client, so the same 1 request/s and app UA. Official
/// releases only.
extension MusicBrainzClient {
    /// Most releases read per page, and pages read per artist (an artist with more lists the first 200).
    public static let browsePage = 100
    public static let browsePages = 2

    /// The artist's release groups with at least one official Album, EP or Single release, each once.
    public func officialReleaseGroups(artist: MBID) async throws -> [MBReleaseGroupSummary] {
        var seen = Set<MBID>()
        var groups: [MBReleaseGroupSummary] = []
        for page in 0..<Self.browsePages {
            let dto: BrowseDTO = try await browse([
                URLQueryItem(name: "artist", value: artist.rawValue),
                URLQueryItem(name: "status", value: "official"),
                URLQueryItem(name: "type", value: "album|ep|single"),
                URLQueryItem(name: "inc", value: "release-groups"),
                URLQueryItem(name: "limit", value: String(Self.browsePage)),
                URLQueryItem(name: "offset", value: String(page * Self.browsePage)),
            ])
            let releases = dto.releases?.values ?? []
            for g in releases.compactMap(\.releaseGroup?.summary) where seen.insert(g.id).inserted { groups.append(g) }
            let total = dto.releaseCount ?? 0
            if releases.isEmpty || (page + 1) * Self.browsePage >= total { break }
        }
        return groups
    }

    /// The release group's official releases with their tracks.
    public func officialReleases(releaseGroup: MBID) async throws -> [MBReleaseDetail] {
        let dto: BrowseDTO = try await browse([
            URLQueryItem(name: "release-group", value: releaseGroup.rawValue),
            URLQueryItem(name: "status", value: "official"),
            URLQueryItem(name: "inc", value: "recordings"),
            URLQueryItem(name: "limit", value: "25"),
        ])
        return dto.releases?.values.compactMap(\.detail) ?? []
    }

    private func browse<T: Decodable>(_ query: [URLQueryItem]) async throws -> T {
        try await limiter.wait()
        guard let url = ServerEndpoint(bases: [Self.base]).url(
            Self.base, path: "ws/2/release", query: query + [URLQueryItem(name: "fmt", value: "json")]) else {
            throw URLError(.badURL)
        }
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
        guard let dto = try? JSONDecoder().decode(T.self, from: data) else { throw MusicBrainzError.decoding }
        return dto
    }
}

private struct BrowseDTO: Decodable {
    var releases: LossyArray<ReleaseDTO>?
    var releaseCount: Int?

    enum CodingKeys: String, CodingKey { case releases, releaseCount = "release-count" }

    struct ReleaseDTO: Decodable {
        var id: String?
        var title: String?
        var date: String?
        var status: String?
        var releaseGroup: GroupDTO?
        var media: LossyArray<MediumDTO>?

        enum CodingKeys: String, CodingKey { case id, title, date, status, media, releaseGroup = "release-group" }

        var detail: MBReleaseDetail? {
            guard let id = id.flatMap(MBID.init) else { return nil }
            let tracks = (media?.values ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }.flatMap { medium in
                (medium.tracks?.values ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }.compactMap(\.track)
            }
            return MBReleaseDetail(id: id, title: (title ?? "").capped, date: date?.capped.nonEmpty,
                                   status: status?.capped.nonEmpty, tracks: tracks)
        }
    }

    struct MediumDTO: Decodable {
        var position: Int?
        var tracks: LossyArray<TrackDTO>?
    }

    struct TrackDTO: Decodable {
        struct RecordingDTO: Decodable { var id: String? }
        var position: Int?
        var title: String?
        var length: Double?
        var recording: RecordingDTO?

        var track: MBTrack? {
            guard let id = recording?.id.flatMap(MBID.init) else { return nil }
            return MBTrack(recording: id, title: (title ?? "").capped,
                           length: length.flatMap { $0 > 0 && $0.isFinite ? $0 / 1000 : nil })
        }
    }

    struct GroupDTO: Decodable {
        var id: String?
        var title: String?
        var primaryType: String?
        var secondaryTypes: [String]?
        var firstReleaseDate: String?

        enum CodingKeys: String, CodingKey {
            case id, title, primaryType = "primary-type", secondaryTypes = "secondary-types",
                 firstReleaseDate = "first-release-date"
        }

        var summary: MBReleaseGroupSummary? {
            guard let id = id.flatMap(MBID.init) else { return nil }
            return MBReleaseGroupSummary(id: id, title: (title ?? "").capped, primaryType: primaryType?.capped.nonEmpty,
                                         secondaryTypes: (secondaryTypes ?? []).prefix(20).map(\.capped).filter { !$0.isEmpty },
                                         firstReleaseDate: firstReleaseDate?.capped.nonEmpty)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
