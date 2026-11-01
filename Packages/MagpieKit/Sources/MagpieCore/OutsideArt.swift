import Foundation
import ImageIO

// R15 / R16: artwork for music that isn't in the library yet. Songs and albums show their Cover Art Archive front,
// artists their Lidarr lookup picture. Never cached (owner): an ephemeral session with no URLCache and no cookies,
// held in memory for the current results only, fetched again for every new search or screen, never on disk.

/// What outside artwork is for.
public enum OutsideArtKey: Hashable, Sendable {
    /// An album (release group): `coverartarchive.org/release-group/<mbid>/front-250`.
    case releaseGroup(MBID)
    /// A song from ListenBrainz's search, which names its release: `coverartarchive.org/release/<mbid>/front-250`.
    case release(MBID)
    /// An artist: the picture from Lidarr's `artist/lookup?term=lidarr:<mbid>`.
    case artist(MBID)

    /// A song's or album's cover: the release group when known (a request's plan), else the release the search named.
    public static func cover(releaseGroup: MBID?, release: MBID?) -> OutsideArtKey? {
        if let releaseGroup { return .releaseGroup(releaseGroup) }
        return release.map { .release($0) }
    }

    /// CarPlay rows carry their art as a string key; outside art is told apart from a library cover id by this prefix.
    public static let tokenPrefix = "outside:"

    public var token: String {
        switch self {
        case .releaseGroup(let id): "\(Self.tokenPrefix)rg:\(id.rawValue)"
        case .release(let id): "\(Self.tokenPrefix)release:\(id.rawValue)"
        case .artist(let id): "\(Self.tokenPrefix)artist:\(id.rawValue)"
        }
    }

    public init?(token: String) {
        guard token.hasPrefix(Self.tokenPrefix) else { return nil }
        let parts = token.dropFirst(Self.tokenPrefix.count).split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = MBID(parts[1]) else { return nil }
        switch parts[0] {
        case "rg": self = .releaseGroup(id)
        case "release": self = .release(id)
        case "artist": self = .artist(id)
        default: return nil
        }
    }
}

/// Where outside artwork may come from, and how much of it.
public enum OutsideArtPolicy {
    /// Bigger answers are dropped (and the real transport stops reading).
    public static let maxBytes = 2 * 1024 * 1024
    /// Lidarr lookups per search: about the visible artist rows.
    public static let maxArtistLookups = 8
    /// Wider or taller than this is refused before decoding (a small file can declare a huge canvas).
    public static let maxDimension = 8000
    /// The image types covers come in; anything else is refused before decoding.
    static let coverTypes: Set<String> = ["public.jpeg", "public.png", "org.webmproject.webp", "public.heic"]
    public static let coverArtArchive = URL(string: "https://coverartarchive.org")!

    /// The Cover Art Archive front for a release group or release; nil for an artist.
    public static func coverURL(_ key: OutsideArtKey) -> URL? {
        switch key {
        case .releaseGroup(let id): coverArtArchive.appending(path: "release-group/\(id.rawValue)/front-250")
        case .release(let id): coverArtArchive.appending(path: "release/\(id.rawValue)/front-250")
        case .artist: nil
        }
    }

    /// Cover Art Archive answers with a redirect to archive.org's servers.
    static func isArchiveHost(_ host: String) -> Bool {
        host == "coverartarchive.org" || host == "archive.org" || host.hasSuffix(".archive.org")
    }

    private static func httpsHost(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// Whether the first request for `key` may go to `url`: HTTPS always; a cover only from the Cover Art Archive, an
    /// artist picture from the image host Lidarr returned.
    public static func isAllowed(_ url: URL, for key: OutsideArtKey) -> Bool {
        guard let host = httpsHost(url) else { return false }
        switch key {
        case .releaseGroup, .release: return host == "coverartarchive.org"
        case .artist: return isPublicHost(host)
        }
    }

    /// A Lidarr answer names the artist picture's host: never an IP address or a local-network name, so a tampered
    /// answer can't point the phone at the owner's network (X5 fix round 1).
    static func isPublicHost(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard name.contains("."), !name.contains(":"), name != "localhost" else { return false }
        if name.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }   // IPv4 literal
        let local = [".local", ".lan", ".home", ".home.arpa", ".internal", ".localhost", ".localdomain", ".intranet", ".corp"]
        return !local.contains { name.hasSuffix($0) }
    }

    /// Whether a redirect from `original` to `target` is followed: HTTPS only, to archive.org's servers or the same
    /// host. Nowhere else, and never down to http.
    public static func allowsRedirect(from original: URL, to target: URL) -> Bool {
        guard let to = httpsHost(target) else { return false }
        if isArchiveHost(to) { return true }
        return original.host()?.lowercased() == to
    }
}

/// Loads outside artwork for one result set (a search, a request screen), in memory only. `reset()` when the results
/// change or the screen closes: everything held is dropped and fetches in flight are cancelled, so the next search
/// fetches again. Offline (or Offline mode On) nothing is sent. An outage, a 404 or a refusal is nil: the placeholder.
@MainActor
public final class OutsideArtLoader {
    /// An artist's picture URL (Lidarr's lookup), or nil.
    public typealias ArtistImage = @Sendable (MBID) async throws -> URL?

    private let transport: HTTPTransport
    private let userAgent: String
    private let artistImage: ArtistImage?
    private let isOffline: @MainActor () -> Bool
    private let maxPixel: Int
    private var images: [OutsideArtKey: CGImage] = [:]
    private var inFlight: [OutsideArtKey: Task<CGImage?, Never>] = [:]
    private var artistLookups = 0
    private var generation = 0

    /// - Parameters:
    ///   - userAgent: the app's MusicBrainz User-Agent; no personal identifier.
    ///   - artistImage: nil without Lidarr: artists keep the placeholder.
    ///   - maxPixel: images are decoded downsampled to at most this many pixels on the long side.
    public init(transport: HTTPTransport = OutsideArtTransport(), userAgent: String, artistImage: ArtistImage?,
                isOffline: @escaping @MainActor () -> Bool, maxPixel: Int = 500) {
        self.transport = transport; self.userAgent = userAgent; self.artistImage = artistImage
        self.isOffline = isOffline; self.maxPixel = maxPixel
    }

    /// Images held now (tests).
    public var cachedCount: Int { images.count }

    /// New results, or the screen closed: drop everything and cancel what's in flight.
    public func reset() {
        generation += 1
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        images = [:]
        artistLookups = 0
    }

    public func image(_ key: OutsideArtKey) async -> CGImage? {
        if let hit = images[key] { return hit }
        if let task = inFlight[key] { return await task.value }
        guard !isOffline() else { return nil }
        if case .artist = key {
            guard artistImage != nil, artistLookups < OutsideArtPolicy.maxArtistLookups else { return nil }
            artistLookups += 1
        }
        let started = generation
        let transport = transport, userAgent = userAgent, artistImage = artistImage, maxPixel = maxPixel
        let task = Task<CGImage?, Never> {
            await Self.load(key, transport: transport, userAgent: userAgent, artistImage: artistImage, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let image = await task.value
        guard generation == started else { return nil }   // a new search meanwhile
        inFlight[key] = nil
        if let image { images[key] = image }
        return image
    }

    nonisolated private static func load(_ key: OutsideArtKey, transport: HTTPTransport, userAgent: String,
                                         artistImage: ArtistImage?, maxPixel: Int) async -> CGImage? {
        let url: URL
        if let cover = OutsideArtPolicy.coverURL(key) {
            url = cover
        } else if case .artist(let mbid) = key, let artistImage, let picture = try? await artistImage(mbid) {
            url = picture
        } else {
            return nil
        }
        guard !Task.isCancelled, OutsideArtPolicy.isAllowed(url, for: key) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200,
              response.expectedContentLength <= OutsideArtPolicy.maxBytes, data.count <= OutsideArtPolicy.maxBytes,
              !Task.isCancelled else { return nil }
        // Belt and braces: an answer that ended up anywhere the redirect policy wouldn't follow is dropped.
        if let final = response.url, final != url, !OutsideArtPolicy.allowsRedirect(from: url, to: final) { return nil }
        if let final = response.url, final.scheme?.lowercased() != "https" { return nil }
        return decode(data, maxPixel: maxPixel)
    }

    /// Hostile data: only JPEG, PNG, WebP or HEIC, at most `OutsideArtPolicy.maxDimension` on each side (read from the
    /// header, before anything is decoded), then decoded downsampled.
    nonisolated public static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, OutsideArtPolicy.coverTypes.contains(type),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= OutsideArtPolicy.maxDimension, height <= OutsideArtPolicy.maxDimension
        else { return nil }
        return downsample(data, maxPixel: maxPixel)
    }

    /// Decodes at most `maxPixel` on the long side, without decoding the full image first.
    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The real transport for outside artwork: an ephemeral session with no URLCache, no cookies and no credentials, so
/// nothing is written to disk; redirects only as `OutsideArtPolicy.allowsRedirect` says; reading stops past 2 MB.
public struct OutsideArtTransport: HTTPTransport {
    public static var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        return config
    }

    private static let shared = URLSession(configuration: configuration, delegate: OutsideArtRedirects.shared,
                                           delegateQueue: nil)
    private let session: URLSession

    public init() { session = Self.shared }

    /// Tests: the same transport over `configuration` (a local URLProtocol stub in place of the internet).
    public init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration, delegate: OutsideArtRedirects.shared, delegateQueue: nil)
    }

    /// The configuration in use (tests check it keeps nothing).
    public var sessionConfiguration: URLSessionConfiguration { session.configuration }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: OutsideArtRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { return (Data(), http) }
        guard http.expectedContentLength <= OutsideArtPolicy.maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        data.reserveCapacity(Int(min(max(http.expectedContentLength, 64 * 1024), Int64(OutsideArtPolicy.maxBytes))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > OutsideArtPolicy.maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return (data, http)
    }
}

/// Follows a redirect only as `OutsideArtPolicy.allowsRedirect` allows (Cover Art Archive to archive.org, HTTPS).
final class OutsideArtRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = OutsideArtRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let original = task.originalRequest?.url ?? response.url, let target = request.url,
              OutsideArtPolicy.allowsRedirect(from: original, to: target) else { return nil }
        return request
    }
}
