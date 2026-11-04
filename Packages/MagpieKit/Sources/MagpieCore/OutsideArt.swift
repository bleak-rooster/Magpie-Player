import Foundation
import ImageIO

// R15 / R16: artwork for music that isn't in the library yet. Songs and albums show their Cover Art Archive front,
// artists their Lidarr lookup picture, through an ephemeral session with no URLCache and no cookies. B1 (D122, owner,
// replacing R15's memory-only rule): a picture that loaded is also kept in its own folder on the phone
// (`OutsideArtDiskCache`); a miss never is. An album's cover falls back to a release's front, then Lidarr's named cover.

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

    /// HTTPS, no user info, and never Deezer's or Apple's hosts (round 14 A7 fix round 1: the owner's rule holds for
    /// outside art too, both for the first request and every redirect).
    private static func httpsHost(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host()?.lowercased(), !host.isEmpty, !RefusedMediaHosts.refuses(host: host) else { return nil }
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

    /// B1 (D122): an album cover Lidarr's lookup named (the last fallback before the placeholder): HTTPS from a public
    /// host, never Deezer's or Apple's; the transport then looks the host up and refuses the owner's network (D119).
    public static func isAllowedLidarrCover(_ url: URL) -> Bool {
        guard let host = httpsHost(url) else { return false }
        return isPublicHost(host)
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

    /// S14 L4 (D119): whether a looked-up address (4 bytes IPv4, 16 bytes IPv6) is a usable public one: never this
    /// network, loopback, private (RFC 1918), CGNAT, link-local, multicast or reserved, unique-local IPv6, or an IPv4 one of
    /// those inside IPv4-mapped or NAT64 IPv6. Anything else (not 4 or 16 bytes) is refused.
    public static func isPublicAddress(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 16 {
            let prefix = Array(bytes[0..<12])
            if prefix == [UInt8](repeating: 0, count: 10) + [0xff, 0xff]               // ::ffff:a.b.c.d
                || prefix == [0x00, 0x64, 0xff, 0x9b] + [UInt8](repeating: 0, count: 8) {   // 64:ff9b::a.b.c.d
                return isPublicAddress(Array(bytes[12..<16]))
            }
            if bytes.allSatisfy({ $0 == 0 }) || bytes == [UInt8](repeating: 0, count: 15) + [1] { return false }   // :: and ::1
            if bytes[0] & 0xfe == 0xfc { return false }                     // fc00::/7 unique local
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }   // fe80::/10 link-local
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0xc0 { return false }   // fec0::/10 site-local (deprecated)
            if bytes[0] == 0xff { return false }                            // multicast
            if prefix.prefix(12).allSatisfy({ $0 == 0 }) { return false }   // ::a.b.c.d (IPv4-compatible, deprecated)
            return true
        }
        guard bytes.count == 4 else { return false }
        let (a, b) = (bytes[0], bytes[1])
        switch a {
        case 0, 10, 127: return false
        case 100 where b & 0xc0 == 64: return false        // 100.64.0.0/10 CGNAT
        case 169 where b == 254: return false              // link-local
        case 172 where b & 0xf0 == 16: return false        // 172.16.0.0/12
        case 192 where b == 168: return false              // 192.168.0.0/16
        case 192 where b == 0 && bytes[2] == 0: return false   // 192.0.0.0/24 protocol assignments
        case 198 where b & 0xfe == 18: return false        // 198.18.0.0/15 benchmarking
        case 224...255: return false                       // multicast, reserved, broadcast
        default: return true
        }
    }

    /// S14 L4: the host's addresses as the system resolves them (nil when it can't). Blocking: call off the main thread.
    public static func systemResolve(_ host: String) -> [[UInt8]]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        var addresses: [[UInt8]] = []
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let info = next {
            if let addr = info.pointee.ai_addr {
                switch Int32(info.pointee.ai_family) {
                case AF_INET:
                    addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        var a = sin.pointee.sin_addr
                        addresses.append(withUnsafeBytes(of: &a) { Array($0) })
                    }
                case AF_INET6:
                    addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                        var a = sin6.pointee.sin6_addr
                        addresses.append(withUnsafeBytes(of: &a) { Array($0) })
                    }
                default: break
                }
            }
            next = info.pointee.ai_next
        }
        return addresses
    }

    /// Whether a redirect from `original` to `target` is followed: HTTPS only, to archive.org's servers or the same
    /// host. Nowhere else, and never down to http.
    public static func allowsRedirect(from original: URL, to target: URL) -> Bool {
        guard let to = httpsHost(target) else { return false }
        if isArchiveHost(to) { return true }
        return original.host()?.lowercased() == to
    }
}

/// Loads outside artwork for one result set (a search, a request screen, an artist page). `reset()` when the results
/// change or the screen closes: what is held in memory is dropped and fetches in flight are cancelled. Offline (or
/// Offline mode On) nothing is sent. An outage, a 404 or a refusal is nil: the placeholder.
///
/// B1 (D122, owner): with a `disk` cache, every picture that loaded is kept on the phone and shown at once next time;
/// a miss is never kept, so a later look (or a pull to refresh) tries again. An album's cover falls back, in order:
/// the release group's front, a release's front, the cover Lidarr's lookup names, then the placeholder. Network loads
/// share `limiter` (at most a few at once) and each key's whole chain is bounded by `timeout`. A load is not tied to the
/// view that asked: a row scrolled away doesn't cancel it, so a cancelled view never leaves a half-fetched picture.
@MainActor
public final class OutsideArtLoader {
    /// An artist's picture URL (Lidarr's lookup), or nil.
    public typealias ArtistImage = @Sendable (MBID) async throws -> URL?

    private let transport: HTTPTransport
    private let userAgent: String
    private let artistImage: ArtistImage?
    private let isOffline: @MainActor () -> Bool
    private let maxPixel: Int
    private let maxArtistLookups: Int
    private let covers: OutsideCoverFallbacks
    private let disk: OutsideArtDiskCache?
    private let limiter: AsyncLimiter?
    private let timeout: Duration
    private var images: [OutsideArtKey: CGImage] = [:]
    private var inFlight: [OutsideArtKey: Task<CGImage?, Never>] = [:]
    private var artistLookups = 0
    private var generation = 0

    /// - Parameters:
    ///   - userAgent: the app's MusicBrainz User-Agent; no personal identifier.
    ///   - artistImage: nil without Lidarr: artists keep the placeholder.
    ///   - maxPixel: images are decoded downsampled to at most this many pixels on the long side.
    ///   - maxArtistLookups: Lidarr lookups per result set (a search's visible artist rows); a page of recommended
    ///     artists passes more.
    public init(transport: HTTPTransport = OutsideArtTransport(), userAgent: String, artistImage: ArtistImage?,
                isOffline: @escaping @MainActor () -> Bool, maxPixel: Int = 500,
                maxArtistLookups: Int = OutsideArtPolicy.maxArtistLookups, covers: OutsideCoverFallbacks = .init(),
                disk: OutsideArtDiskCache? = nil, limiter: AsyncLimiter? = nil, timeout: Duration = .seconds(30)) {
        self.transport = transport; self.userAgent = userAgent; self.artistImage = artistImage
        self.isOffline = isOffline; self.maxPixel = maxPixel; self.maxArtistLookups = maxArtistLookups
        self.covers = covers; self.disk = disk; self.limiter = limiter; self.timeout = timeout
    }

    /// Images held now (tests).
    public var cachedCount: Int { images.count }

    /// New results, or the screen closed: drop what is held in memory and cancel what's in flight (the disk copy,
    /// if any, stays).
    public func reset() {
        generation += 1
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        images = [:]
        artistLookups = 0
    }

    /// The picture for `key` without any network: memory, else the disk copy. Lets a page show what it has at once.
    public func cached(_ key: OutsideArtKey) -> CGImage? {
        if let hit = images[key] { return hit }
        guard let data = disk?.data(for: key), let image = Self.decode(data, maxPixel: maxPixel) else { return nil }
        images[key] = image
        return image
    }

    /// `key`'s image, else `fallback`'s (a request's cover, else its artist's picture), else nil: the placeholder.
    public func image(_ key: OutsideArtKey?, fallback: OutsideArtKey?) async -> CGImage? {
        let started = generation
        if let key, let image = await image(key) { return image }
        // New results or a closed screen meanwhile: nothing more is asked for (no artist lookup for a screen that's gone).
        guard generation == started, !Task.isCancelled, let fallback, fallback != key else { return nil }
        return await image(fallback)
    }

    public func image(_ key: OutsideArtKey) async -> CGImage? {
        if let hit = cached(key) { return hit }
        if let task = inFlight[key] { return await task.value }
        guard !isOffline() else { return nil }
        if case .artist = key {
            guard artistImage != nil, artistLookups < maxArtistLookups else { return nil }
            artistLookups += 1
        }
        let started = generation
        let transport = transport, userAgent = userAgent, artistImage = artistImage, maxPixel = maxPixel
        let covers = covers, disk = disk, limiter = limiter, timeout = timeout
        let task = Task<CGImage?, Never> {
            let data = await Self.bounded(timeout) {
                try await Self.loadData(key, transport: transport, userAgent: userAgent, artistImage: artistImage,
                                        covers: covers, limiter: limiter)
            }
            guard let data, let image = Self.decode(data, maxPixel: maxPixel) else { return nil }
            disk?.save(data, for: key)   // only a picture that loaded and decoded is kept
            return image
        }
        inFlight[key] = task
        let image = await task.value
        guard generation == started else { return nil }   // a new search meanwhile
        inFlight[key] = nil
        if let image { images[key] = image } else if case .artist = key { artistLookups -= 1 }
        return image
    }

    /// Loads every key not held yet, a few at a time (through `limiter`), so a page's pictures are there before they
    /// scroll into view. Returns once all have been tried.
    public func prefetch(_ keys: [OutsideArtKey]) async {
        var seen = Set<OutsideArtKey>()
        let wanted = keys.filter { seen.insert($0).inserted && cached($0) == nil }
        let loads = wanted.map { key in Task { @MainActor in _ = await self.image(key) } }
        for load in loads { await load.value }
    }

    /// `op`'s answer, or nil once `limit` passes: the work is cancelled and not waited for, so a source that never
    /// answers can't hold a page up.
    nonisolated static func bounded(_ limit: Duration, _ op: @escaping @Sendable () async throws -> Data?) async -> Data? {
        let once = FirstAnswer()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                let work = Task { once.finish((try? await op()) ?? nil) }
                let timer = Task {
                    do { try await Task.sleep(for: limit) } catch { return }
                    once.finish(nil)
                }
                once.start(continuation, cancelling: [work, timer])
            }
        } onCancel: {
            once.finish(nil)
        }
    }

    /// The first answer wins; both tasks are then cancelled.
    private final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var early: Data??
        private var tasks: [Task<Void, Never>] = []
        private var done = false

        func start(_ continuation: CheckedContinuation<Data?, Never>, cancelling tasks: [Task<Void, Never>]) {
            lock.lock()
            if let early {
                lock.unlock()
                tasks.forEach { $0.cancel() }
                continuation.resume(returning: early)
                return
            }
            self.continuation = continuation
            self.tasks = tasks
            lock.unlock()
        }

        func finish(_ data: Data?) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            guard let continuation else { early = .some(data); lock.unlock(); return }
            self.continuation = nil
            let tasks = self.tasks
            lock.unlock()
            tasks.forEach { $0.cancel() }
            continuation.resume(returning: data)
        }
    }

    /// The first of `key`'s sources that answers with a picture: its bytes, or nil.
    nonisolated private static func loadData(_ key: OutsideArtKey, transport: HTTPTransport, userAgent: String,
                                             artistImage: ArtistImage?, covers: OutsideCoverFallbacks,
                                             limiter: AsyncLimiter?) async throws -> Data? {
        func fetch(_ url: URL, allowed: Bool) async -> Data? {
            guard allowed, !Task.isCancelled else { return nil }
            if let limiter {
                return try? await limiter.run { await Self.get(url, transport: transport, userAgent: userAgent) }
            }
            return await get(url, transport: transport, userAgent: userAgent)
        }
        switch key {
        case .release:
            guard let url = OutsideArtPolicy.coverURL(key) else { return nil }
            return await fetch(url, allowed: OutsideArtPolicy.isAllowed(url, for: key))
        case .artist(let mbid):
            guard let artistImage else { return nil }
            // The lookup takes a turn too, so a page of recommended artists never sends dozens at once.
            let looked: URL?? = if let limiter { try? await limiter.run { try await artistImage(mbid) } }
                                else { try? await artistImage(mbid) }
            guard let picture = looked ?? nil else { return nil }
            return await fetch(picture, allowed: OutsideArtPolicy.isAllowed(picture, for: key))
        case .releaseGroup(let rg):
            if let url = OutsideArtPolicy.coverURL(key), let data = await fetch(url, allowed: OutsideArtPolicy.isAllowed(url, for: key)) {
                return data
            }
            if let releases = covers.releases, let ids = try? await releases(rg) {
                for release in ids.prefix(OutsideCoverFallbacks.releasesTried) {
                    let next = OutsideArtKey.release(release)
                    if let url = OutsideArtPolicy.coverURL(next),
                       let data = await fetch(url, allowed: OutsideArtPolicy.isAllowed(url, for: next)) { return data }
                }
            }
            if let lidarrCover = covers.lidarrCover {
                let named: URL?? = if let limiter { try? await limiter.run { try await lidarrCover(rg) } }
                                   else { try? await lidarrCover(rg) }
                guard let url = named ?? nil else { return nil }
                return await fetch(url, allowed: OutsideArtPolicy.isAllowedLidarrCover(url))
            }
            return nil
        }
    }

    /// One GET: the image bytes when it answered 200 with a picture-sized body from where it may come from.
    nonisolated private static func get(_ url: URL, transport: HTTPTransport, userAgent: String) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200,
              response.expectedContentLength <= OutsideArtPolicy.maxBytes, data.count <= OutsideArtPolicy.maxBytes,
              !data.isEmpty, !Task.isCancelled else { return nil }
        // Belt and braces: an answer that ended up anywhere the redirect policy wouldn't follow is dropped.
        if let final = response.url, final != url, !OutsideArtPolicy.allowsRedirect(from: url, to: final) { return nil }
        if let final = response.url, final.scheme?.lowercased() != "https" { return nil }
        return data
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
    private let resolve: @Sendable (String) -> [[UInt8]]?

    public init() {
        session = Self.shared
        resolve = OutsideArtPolicy.systemResolve
    }

    /// Tests: the same transport over `configuration` (a local URLProtocol stub in place of the internet), and the host
    /// lookup given (S14 L4: tests never ask DNS).
    public init(configuration: URLSessionConfiguration,
                resolve: @escaping @Sendable (String) -> [[UInt8]]? = OutsideArtPolicy.systemResolve) {
        session = URLSession(configuration: configuration, delegate: OutsideArtRedirects.shared, delegateQueue: nil)
        self.resolve = resolve
    }

    /// S14 L4 (D119): an artist picture's host (any host but the Cover Art Archive's, which are fixed) is looked up
    /// first; when it can't be, or any of its addresses is on the owner's network, nothing is sent. (The system looks
    /// the host up again to connect, so a name that changes its answer in between isn't caught: the name rules in
    /// `isPublicHost` and HTTPS stay the main guard.)
    private func refusesHost(of url: URL?) async -> Bool {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return true }
        if host == "coverartarchive.org" || OutsideArtPolicy.isArchiveHost(host) { return false }
        let resolve = resolve
        let addresses = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: resolve(host)) }
        }
        guard let addresses, !addresses.isEmpty else { return true }
        return !addresses.allSatisfy(OutsideArtPolicy.isPublicAddress)
    }

    /// The configuration in use (tests check it keeps nothing).
    public var sessionConfiguration: URLSessionConfiguration { session.configuration }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if await refusesHost(of: request.url) { throw URLError(.cannotFindHost) }
        try Task.checkCancellation()
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
