import CryptoKit
import Foundation
import MagpieCore

/// Round 14 A7 (D111): a picture Aurral's image proxy holds: its path on Aurral, `/api/image-proxy/<sha256>[.<ext>]`.
public struct AurralProxiedImage: Sendable, Hashable, Codable {
    public let path: String

    /// Only Aurral's own image-proxy path (the exact shape the allow-list takes); nil for anything else.
    public init?(path: String) {
        guard path.hasPrefix("/"), AurralRoute.route(method: "GET", path: String(path.dropFirst())) == .imageProxyFile
        else { return nil }
        self.path = path
    }
}

extension AurralClient {
    /// `POST /api/image-proxy` with exactly `{"src": <url>}`: Aurral fetches and caches the picture (it refuses
    /// private hosts) and answers its local path. Only for a link an Aurral answer named this session (D111): any other
    /// is refused before anything is sent. A 404 (Aurral couldn't fetch it) is `AurralError.notFound`.
    public func proxyImage(_ image: AurralImage) async throws -> AurralProxiedImage {
        guard AurralImageProxy.isLink(image.raw), await session.knowsImageSource(image.raw) else {
            throw AurralError.forbidden("image-proxy: a picture Aurral didn't name")
        }
        let body = try JSONSerialization.data(withJSONObject: ["src": image.raw], options: [.withoutEscapingSlashes])
        let data = try await ok(method: AurralRoute.imageProxyMethod, path: "api/image-proxy", body: body)
        guard let object = JSONNesting.object(with: data) as? [String: Any], let url = object["url"] as? String,
              let proxied = AurralProxiedImage(path: url) else { throw AurralError.decoding }
        return proxied
    }
}

/// Round 14 A7 (D111, D112, plan decision 11: no direct calls to Deezer or Apple from the phone): shows the pictures
/// Aurral names (Deezer's and Apple's covers) through Aurral's image proxy, never from their hosts.
/// - A link is sent to `POST /api/image-proxy` only when an Aurral answer named it this session
///   (`AurralSession.knowsImageSource`).
/// - The link → local path mapping is kept on disk per server (`directory/<server hash>.json`, at most
///   `maxMappings`), so a picture already proxied is asked for by its Aurral path alone.
/// - The picture is fetched from the Aurral host itself (`GET /api/image-proxy/<key>`, open: no login, no cookie,
///   no cache), never through a redirect, and only as answered by that host.
/// - At most `maxConcurrent` pictures are asked for at once; a caller cancelled while waiting asks nothing.
/// - Any failure is nil: the placeholder.
public actor AurralImageProxy {
    public static let maxConcurrent = 4
    public static let maxMappings = 2_000
    /// Aurral's pictures are about 150 KB (its `library` profile); anything past this isn't one.
    public static let maxBytes = 2 * 1024 * 1024

    public nonisolated let base: URL
    /// The server, however its address is spelt (fix round 1 M2).
    public nonisolated let server: String
    private let file: URL?
    private let openTransport: HTTPTransport
    private var mappings: [String: String]?
    private var order: [String] = []
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    /// `directory` holds the mappings (nil: in memory only); `openTransport` fetches the pictures (its default never
    /// follows a redirect and keeps no cookie or cache).
    public init(base: URL, directory: URL?, openTransport: HTTPTransport = AurralOpenTransport()) {
        self.base = base
        self.server = Self.serverKey(base)
        self.file = directory?.appending(path: server + ".json")
        self.openTransport = openTransport
    }

    /// The picture's bytes, through Aurral; nil when it can't be had (the placeholder).
    public func imageData(for image: AurralImage, client: AurralClient) async -> Data? {
        guard Self.serverKey(client.base) == server else { return nil }
        if image.raw.hasPrefix("/") {
            // Already a picture on Aurral (its image-proxy path); no other Aurral path is a picture Magpie fetches.
            guard let proxied = AurralProxiedImage(path: image.raw) else { return nil }
            return await limited { try? await Self.fetch(proxied, base: self.base, transport: self.openTransport) }
        }
        guard Self.isLink(image.raw) else { return nil }
        return await limited {
            if let path = self.mapping(for: image.raw), let proxied = AurralProxiedImage(path: path) {
                do {
                    return try await Self.fetch(proxied, base: self.base, transport: self.openTransport)
                } catch AurralError.notFound {
                    self.forget(image.raw)   // Aurral forgot its copy: ask again below, if this session may
                } catch {
                    return nil
                }
            }
            guard let proxied = try? await client.proxyImage(image) else { return nil }
            self.remember(image.raw, as: proxied.path)
            return try? await Self.fetch(proxied, base: self.base, transport: self.openTransport)
        }
    }

    /// `GET <base>/api/image-proxy/<key>`: no login, no cookie, no cache; 200 with a picture from the Aurral host
    /// only. A 404 is `AurralError.notFound` (Aurral's copy is gone); anything else is refused.
    public static func fetch(_ image: AurralProxiedImage, base: URL, transport: HTTPTransport) async throws -> Data {
        let path = String(image.path.dropFirst())
        guard AurralRoute.isAllowed(method: "GET", path: path, query: []),
              let url = ServerEndpoint(bases: [base]).url(base, path: path) else { throw AurralError.forbidden("image-proxy") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        if let landed = response.url, !landed.isSameOrigin(as: url) { throw AurralError.forbidden("image-proxy: moved") }
        switch response.statusCode {
        case 200:
            let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard type.hasPrefix("image/"), !data.isEmpty, data.count <= maxBytes else { throw AurralError.decoding }
            return data
        case 404: throw AurralError.notFound
        default: throw AurralError.http(status: response.statusCode)   // every 3xx included: never followed
        }
    }

    // MARK: - Links Aurral named

    /// An absolute http(s) picture link (`AurralImage`'s rules), the only kind the proxy is asked for.
    static func isLink(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return (lower.hasPrefix("https://") || lower.hasPrefix("http://")) && AurralImage(raw)?.raw == raw
    }

    /// Every absolute http(s) link in an Aurral answer (at most 5,000), as the session remembers them.
    static func pictureLinks(in data: Data) -> [String] {
        guard let root = JSONNesting.object(with: data) else { return [] }
        var links: [String] = []
        var stack: [Any] = [root]
        while let next = stack.popLast(), links.count < 5_000 {
            switch next {
            case let s as String where isLink(s): links.append(s)
            case let a as [Any]: stack.append(contentsOf: a)
            case let d as [String: Any]: stack.append(contentsOf: d.values)
            default: break
            }
        }
        return links
    }

    // MARK: - The bound

    /// Callers waiting for a slot (tests).
    var waiting: Int { waiters.count }

    /// Runs `work` in one of the slots. A caller cancelled while it waited takes no slot and frees none (fix round 1
    /// I1: the bound holds however many rows scroll away).
    private func limited(_ work: () async -> Data?) async -> Data? {
        guard await acquire() else { return nil }
        defer { release() }
        guard !Task.isCancelled else { return nil }
        return await work()
    }

    /// True with a slot held (the caller must `release()` it); false when the caller was cancelled while waiting
    /// (it holds nothing).
    private func acquire() async -> Bool {
        if running < Self.maxConcurrent { running += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in waiters.append((id, continuation)) }
        } onCancel: {
            Task { await self.leave(id) }
        }
    }

    /// A cancelled waiter leaves the line without a slot (it then asks nothing and releases nothing).
    private func leave(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Hands the slot to the next waiter (it then holds it), or frees it.
    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().continuation.resume(returning: true) }
    }

    // MARK: - The mapping, on disk per server

    private func mapping(for src: String) -> String? {
        load()
        return mappings?[src]
    }

    private func remember(_ src: String, as path: String) {
        load()
        if mappings?[src] == nil { order.append(src) }
        mappings?[src] = path
        while order.count > Self.maxMappings { mappings?[order.removeFirst()] = nil }
        save()
    }

    private func forget(_ src: String) {
        load()
        guard mappings?.removeValue(forKey: src) != nil else { return }
        order.removeAll { $0 == src }
        save()
    }

    private struct Saved: Codable {
        var entries: [[String]]   // [src, path], oldest first
    }

    private func load() {
        guard mappings == nil else { return }
        mappings = [:]
        guard let file, let data = try? Data(contentsOf: file), data.count <= 4 * 1024 * 1024,
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        for entry in saved.entries.suffix(Self.maxMappings) where entry.count == 2 {
            guard Self.isLink(entry[0]), AurralProxiedImage(path: entry[1]) != nil, mappings?[entry[0]] == nil else { continue }
            mappings?[entry[0]] = entry[1]
            order.append(entry[0])
        }
    }

    private func save() {
        guard let file, let mappings else { return }
        let saved = Saved(entries: order.compactMap { src in mappings[src].map { [src, $0] } })
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Log.logger("aurral").error("couldn't save the image mapping: \(Log.category(of: error), privacy: .public)")
        }
    }

    /// One file per server: a hash of its address (scheme, host and port lower-cased, and its path).
    public static func serverKey(_ base: URL) -> String {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        var text = parts.string ?? base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
