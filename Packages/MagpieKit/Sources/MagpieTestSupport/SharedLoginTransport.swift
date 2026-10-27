import CryptoKit
import Foundation
import MagpieCore

/// Integration tests only (Task H1): the dev Navidrome rate-limits `POST /auth/login` (about 5 per 20 s; it answers
/// 429), and `swift test` runs each test target in its own process, often side by side. This transport shares one
/// login across every IT client in every test process: the first `/auth/login` for an address and account goes to
/// the server and its answer is kept for `lifetime` in a file in the temporary folder (owner-only, locked across
/// processes); later logins get that answer back without asking the server again. A 401 from that server drops
/// the kept answer, so the client's own re-login really logs in. A 429 is retried a few times with backoff.
/// Everything else goes to `inner` unchanged.
///
/// G0, structurally (H2b): every request, login or not, is refused unless its host is exactly `127.0.0.1` or
/// `localhost` (`NotLocal`), so a caller that forgot its own check can't reach (or cache a login for) a real
/// server. Expired kept logins and stale lock files are deleted on use. The file names hash the login with a
/// random salt kept beside them (`magpie-it-login.salt`, owner-only), so a name doesn't follow from the password.
public struct SharedLoginTransport: HTTPTransport {
    /// The request was for a host other than 127.0.0.1 or localhost. Nothing was sent.
    public struct NotLocal: Error, CustomStringConvertible {
        public let host: String?
        public var description: String { "SharedLoginTransport only talks to 127.0.0.1 or localhost, not \(host ?? "?")" }
    }

    static let localHosts: Set<String> = ["127.0.0.1", "localhost"]
    private static let prefix = "magpie-it-login-"

    public let inner: HTTPTransport
    public let lifetime: TimeInterval
    private let directory: URL

    public init(inner: HTTPTransport = URLSessionTransport(), lifetime: TimeInterval = 10 * 60,
                directory: URL = FileManager.default.temporaryDirectory) {
        self.inner = inner
        self.lifetime = lifetime
        self.directory = directory
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let host = request.url?.host(percentEncoded: false), Self.localHosts.contains(host.lowercased()) else {
            throw NotLocal(host: request.url?.host(percentEncoded: false))
        }
        guard request.httpMethod == "POST", request.url?.path.hasSuffix("/auth/login") == true, let url = request.url else {
            let (data, response) = try await inner.send(request)
            if response.statusCode == 401, let url = request.url { forget(host: url) }
            return (data, response)
        }
        sweep()
        let file = try cacheFile(url: url, body: request.httpBody ?? Data())
        let lock = try FileLock(file.appendingPathExtension("lock"))
        defer { lock.unlock() }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < lifetime,
           let kept = try? Data(contentsOf: file) {
            return (kept, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "application/json"])!)
        }
        var attempt = 0
        while true {
            let (data, response) = try await inner.send(request)
            if response.statusCode == 429, attempt < 5 {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 4))
                continue
            }
            if response.statusCode == 200 {
                FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
            }
            return (data, response)
        }
    }

    /// Keyed by the address and the credentials (the JSON body with its keys sorted: the client's encoder doesn't
    /// keep one key order across processes), hashed with the folder's salt.
    private func cacheFile(url: URL, body: Data) throws -> URL {
        let canonical = (try? JSONSerialization.jsonObject(with: body))
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? body
        let digest = SHA256.hash(data: try salt() + Data(url.absoluteString.utf8) + canonical)
            .map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(Self.prefix)\(hostKey(url))-\(digest.prefix(24)).json")
    }

    /// The folder's random salt, made once (atomically: the first process to link its file wins).
    private func salt() throws -> Data {
        let file = directory.appending(path: "magpie-it-login.salt")
        if let salt = try? Data(contentsOf: file), salt.count == 32 { return salt }
        let mine = directory.appending(path: "magpie-it-login.salt.\(UUID().uuidString)")
        let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        guard FileManager.default.createFile(atPath: mine.path, contents: bytes, attributes: [.posixPermissions: 0o600])
        else { throw URLError(.cannotCreateFile) }
        defer { unlink(mine.path) }
        _ = link(mine.path, file.path)   // fails when another process made it first: theirs is used
        guard let salt = try? Data(contentsOf: file), salt.count == 32 else { throw URLError(.cannotOpenFile) }
        return salt
    }

    /// Deletes kept logins older than `lifetime`, and lock files as old that nobody holds.
    private func sweep() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.prefix) && (name.hasSuffix(".json") || name.hasSuffix(".json.lock")) {
            let file = directory.appending(path: name)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) >= lifetime else { continue }
            if name.hasSuffix(".lock") {
                guard let lock = FileLock(tryLocking: file) else { continue }   // held: in use
                unlink(file.path)
                lock.unlock()
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func hostKey(_ url: URL) -> String { "\(url.host ?? "x")_\(url.port ?? 0)" }

    /// The server turned a kept login down: drop every kept login for it.
    private func forget(host url: URL) {
        let prefix = "\(Self.prefix)\(hostKey(url))-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

/// An exclusive `flock` on a file, across processes.
private final class FileLock: @unchecked Sendable {
    private let fd: Int32

    init(_ url: URL) throws {
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw URLError(.cannotOpenFile) }
        flock(fd, LOCK_EX)
        futimes(fd, nil)   // in use now: not stale
    }

    /// Locks an existing file only if nobody holds it; nil otherwise.
    init?(tryLocking url: URL) {
        fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
    }

    func unlock() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
