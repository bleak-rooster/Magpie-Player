import Foundation
import MagpieCore

/// Round 14 A1 (D79): what this Aurral can do, from `GET /api/health/bootstrap`'s API contract
/// (`api.version`, `api.features`, Aurral 2.13 `config/apiContract.ts`) and its version. Every round-14 route was
/// checked against 2.13.0's source, so each capability needs 2.13 or later, API contract version 1, and its feature
/// flag. Anything else (2.10, which has no contract; 2.11 and 2.12, whose shapes Magpie never checked; a contract
/// version 2) gets `.none`: today's behaviour.
public struct AurralCapabilities: Sendable, Equatable {
    /// `GET /api/discover` (per-user recommended artists).
    public var recommendations = false
    /// `GET /api/discover/trending` and the genre charts.
    public var trending = false
    /// `GET /api/discover/editorial` and `/:id`, and Add flow (`POST /api/discover/editorial/:id/library`).
    public var editorialPlaylists = false
    /// `GET /api/discover/editorial/links` (artist and album MBIDs for a Deezer song).
    public var editorialLinks = false
    /// `GET /api/artists/:mbid/preview` (an artist's top songs with previews).
    public var artistPreview = false
    /// `GET /api/search/unified` and `GET /api/search`.
    public var search = false
    /// `GET /api/artists/release-group/:mbid/tracks`.
    public var releaseGroupTracks = false
    /// `POST /api/discover/feedback` (Not for me).
    public var discoverFeedback = false
    /// `POST /api/playlists/flows/:flowId/download` (Download songs, for a flow made with auto-download off).
    public var flowDownload = false
    /// `POST /api/playlists/shared-playlists/:playlistId/tracks/:jobId/research` (Retry a song that didn't download).
    public var trackResearch = false
    /// `GET /api/playlists/jobs/:playlistId` (one flow's songs and their progress).
    public var playlistJobsById = false
    public var manage = false

    /// Nothing new: Aurral 2.10 (and anything Magpie can't vouch for).
    public static let none = AurralCapabilities()

    /// The minimum version every round-14 route was checked against.
    public static let checkedAgainst = (major: 2, minor: 13)

    init() {}

    public init(appVersion: String?, apiVersion: Int?, features: Set<String>) {
        guard apiVersion == 1, let version = AurralVersion.numbers(appVersion),
              version >= (Self.checkedAgainst.major, Self.checkedAgainst.minor) else { return }
        let discover = features.contains("discover")
        let flows = features.contains("flows")
        recommendations = discover
        editorialPlaylists = discover
        editorialLinks = discover
        artistPreview = discover
        search = discover
        releaseGroupTracks = discover
        discoverFeedback = discover
        trending = features.contains("trending")
        flowDownload = flows && features.contains("flowAutoDownload")
        trackResearch = flows
        playlistJobsById = flows
    }

    public func canManage(as user: AurralUser?) -> Bool { false }

    /// Any of Discover, Recommended or Trending.
    public var anyDiscover: Bool { recommendations || trending || editorialPlaylists }
}

/// One of Aurral's download sources (`downloadSources.<id>`: Soulseek, Usenet, yt-dlp, Deemix...).
public struct AurralDownloadSource: Sendable, Equatable, Hashable {
    public var id: String
    public var label: String?
    public var enabled: Bool
    public var configured: Bool
    /// Lower first (Aurral tries sources in this order).
    public var priority: Int?

    public init(id: String, label: String? = nil, enabled: Bool, configured: Bool, priority: Int? = nil) {
        self.id = id; self.label = label; self.enabled = enabled; self.configured = configured; self.priority = priority
    }
}

/// Round 14 A1 (D79): `GET /api/health/bootstrap`. Open on Aurral, but its `user` and `downloadSources` come only to a
/// signed-in caller, so Magpie sends it with the session (an authorised route, like every other read).
public struct AurralBootstrap: Sendable, Equatable {
    public var appVersion: String?
    /// The API contract's version (`api.version`); nil before 2.11.
    public var apiVersion: Int?
    public var features: Set<String>
    /// The signed-in user with their permissions (absent when the call wasn't signed in).
    public var user: AurralUser?
    /// The download sources in Aurral's priority order; nil when Aurral didn't say (signed out, or 2.10).
    public var downloadSources: [AurralDownloadSource]?

    public init(appVersion: String?, apiVersion: Int?, features: Set<String>, user: AurralUser? = nil,
                downloadSources: [AurralDownloadSource]? = nil) {
        self.appVersion = appVersion; self.apiVersion = apiVersion; self.features = features; self.user = user
        self.downloadSources = downloadSources
    }

    public var capabilities: AurralCapabilities {
        AurralCapabilities(appVersion: appVersion, apiVersion: apiVersion, features: features)
    }

    /// The sources that are set up and switched on, in priority order.
    public var configuredDownloaders: [AurralDownloadSource] { (downloadSources ?? []).filter { $0.configured && $0.enabled } }

    /// Whether Aurral can download songs for a flow: nil when it didn't say (Add flow then doesn't warn).
    public var hasDownloader: Bool? { downloadSources.map { _ in !configuredDownloaders.isEmpty } }

    public static func decode(_ data: Data) throws -> AurralBootstrap {
        guard let o = object(data) as? [String: Any] else { throw AurralError.decoding }
        let api = o.dict("api")
        let features = Set((api?["features"] as? [Any] ?? []).prefix(200).compactMap { $0 as? String }.filter { $0.count <= 100 })
        var sources: [AurralDownloadSource]?
        if let raw = o.dict("downloadSources") {
            sources = raw.compactMap { key, value -> AurralDownloadSource? in
                guard let s = value as? [String: Any], key.count <= 100 else { return nil }
                return AurralDownloadSource(id: s.text("id") ?? key, label: s.text("label"), enabled: s.bool("enabled") == true,
                                            configured: s.bool("configured") == true, priority: s.int("priority"))
            }
            .sorted { ($0.priority ?? .max, $0.id) < ($1.priority ?? .max, $1.id) }
        }
        return AurralBootstrap(appVersion: o.string("appVersion"), apiVersion: api?.int("version"), features: features,
                               user: AurralUser.decode(o["user"]), downloadSources: sources)
    }
}

extension AurralVersion {
    /// `major.minor` of a version like "2.13.0" or "v2.13.0"; nil when it isn't one.
    static func numbers(_ version: String?) -> (Int, Int)? {
        guard var text = version?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let numbers = text.split(separator: ".").prefix(2).map { Int($0.prefix { $0.isNumber }) }
        guard numbers.count == 2, let major = numbers[0], let minor = numbers[1] else { return nil }
        return (major, minor)
    }
}
