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
public struct SharedLoginTransport: HTTPTransport {
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
        guard request.httpMethod == "POST", request.url?.path.hasSuffix("/auth/login") == true, let url = request.url else {
            let (data, response) = try await inner.send(request)
            if response.statusCode == 401, let url = request.url { forget(host: url) }
            return (data, response)
        }
        let file = cacheFile(url: url, body: request.httpBody ?? Data())
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
    /// keep one key order across processes).
    private func cacheFile(url: URL, body: Data) -> URL {
        let canonical = (try? JSONSerialization.jsonObject(with: body))
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? body
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8) + canonical).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "magpie-it-login-\(hostKey(url))-\(digest.prefix(24)).json")
    }

    private func hostKey(_ url: URL) -> String { "\(url.host ?? "x")_\(url.port ?? 0)" }

    /// The server turned a kept login down: drop every kept login for it.
    private func forget(host url: URL) {
        let prefix = "magpie-it-login-\(hostKey(url))-"
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
    }

    func unlock() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
