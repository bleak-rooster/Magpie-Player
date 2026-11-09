import CryptoKit
import Foundation
import MagpieCore

// Round 23 (owner, 2026-11-07, D192): the optional slskd connection. The HTTP channel (`SlskdConnection`) reads
// (`get`, GETs only) for anyone in SlskdKit; it writes (`send`) only for a holder of an `SlskdGatePass`, which only
// `SlskdWriteGate` (its own file) can make (round 24 fix round 2, R1): `SlskdClient` can only read.

public enum SlskdError: Error, Sendable, Equatable {
    case http(status: Int)
    case unauthorized
    case decoding
    /// Not one of `SlskdRoute`'s calls (a name that isn't safe); nothing was sent.
    case forbidden
}

/// One file slskd downloaded or is downloading, as `GET /api/v0/transfers/downloads` lists it.
public struct SlskdTransfer: Sendable, Equatable {
    public var id: UUID
    public var username: String
    /// The remote path as the sharing user named it (`@@share\Music\Artist\Album\01 - Song.flac`).
    public var filename: String
    /// The remote folder it came from (slskd's grouping).
    public var directory: String
    /// slskd's state flags, e.g. `Completed, Succeeded`, `InProgress`, `Queued, Remotely`.
    public var state: String

    public init(id: UUID, username: String, filename: String, directory: String = "", state: String) {
        self.id = id; self.username = username; self.filename = filename; self.directory = directory; self.state = state
    }

    /// The file's own name (the last part of the remote path, `\` or `/` separated): slskd saves it under this name.
    public var fileName: String { Self.lastComponent(filename) }

    /// Finished one way or another (`Completed, …`): nothing will be written to it any more.
    public var isFinished: Bool { state.localizedCaseInsensitiveContains("Completed") }

    /// Finished and the whole file arrived.
    public var succeeded: Bool { isFinished && state.localizedCaseInsensitiveContains("Succeeded") }

    static func lastComponent(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
    }
}

/// One folder directly inside slskd's downloads folder: the names of the files and folders in it.
public struct SlskdFolder: Sendable, Equatable {
    public var files: [String]
    public var folders: [String]
    public init(files: [String], folders: [String]) { self.files = files; self.folders = folders }
}

/// The one HTTP channel to an slskd server.
struct SlskdConnection: Sendable {
    let base: URL
    fileprivate let apiKey: String
    fileprivate let transport: HTTPTransport

    /// Answers are capped (a downloads list of a busy slskd can be large, never unbounded).
    static let maxResponseBytes = 16 * 1024 * 1024

    var instanceScope: String {
        var text = base.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        let digest = SHA256.hash(data: Data("slskd|\(text)|\(apiKey)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func get(_ route: SlskdRoute) async throws -> (Data, HTTPURLResponse) {
        guard route.method == "GET" else { throw SlskdError.forbidden }
        return try await exchange(route)
    }

    /// A write: only with the gate's pass (round 24 fix round 2, R1), which nothing but `SlskdWriteGate` can make.
    func send(_ route: SlskdRoute, pass: SlskdGatePass) async throws -> (Data, HTTPURLResponse) {
        try await exchange(route)
    }

    private func exchange(_ route: SlskdRoute) async throws -> (Data, HTTPURLResponse) {
        guard let url = route.url(base: base) else { throw SlskdError.forbidden }
        var request = URLRequest(url: url)
        // G1 allowlist: slskd clean-up (only `SlskdRoute`'s methods; writes only from `SlskdWriteGate.perform`)
        request.httpMethod = route.method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Log.request(request, category: "slskd")
        return try await transport.send(request, maxBytes: Self.maxResponseBytes)
    }
}

/// Reads from slskd (GETs only). Writes go through `SlskdWriteGate`.
public struct SlskdClient: Sendable {
    let connection: SlskdConnection

    /// `base` is slskd's address, optionally with a reverse-proxy path (`https://host/slskd`); it is preserved.
    public init(base: URL, apiKey: String, transport: HTTPTransport) {
        connection = SlskdConnection(base: base, apiKey: apiKey, transport: transport)
    }

    /// A hash of the address and key: the write switch belongs to one slskd (a new key starts with it off).
    public var instanceScope: String { connection.instanceScope }

    private func ok(_ route: SlskdRoute) async throws -> Data {
        let (data, response) = try await connection.get(route)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw SlskdError.unauthorized
        default: throw SlskdError.http(status: response.statusCode)
        }
    }

    /// Every download slskd knows (its records, not its files). Also the connection test: it needs the key.
    public func downloads() async throws -> [SlskdTransfer] {
        let data = try await ok(.downloads)
        guard let users = try? JSONSerialization.jsonObject(with: data) as? [Any] else { throw SlskdError.decoding }
        var out: [SlskdTransfer] = []
        for case let user as [String: Any] in users {
            let username = user["username"] as? String ?? ""
            for case let dir as [String: Any] in user["directories"] as? [Any] ?? [] {
                let directory = dir["directory"] as? String ?? ""
                for case let file as [String: Any] in dir["files"] as? [Any] ?? [] {
                    guard let idText = file["id"] as? String, let id = UUID(uuidString: idText),
                          let filename = file["filename"] as? String, let state = file["state"] as? String else { continue }
                    let name = (file["username"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? username
                    out.append(SlskdTransfer(id: id, username: name, filename: filename, directory: directory, state: state))
                }
            }
        }
        return out
    }

    /// Round 24 (D217): slskd's connection to the Soulseek network (`GET /api/v0/server`), read leniently.
    public func serverState() async throws -> SlskdServerState {
        try SlskdServerState.decode(try await ok(.serverState))
    }

    /// One folder directly inside slskd's downloads folder; nil when there is none of that name.
    public func folder(_ name: String) async throws -> SlskdFolder? {
        do {
            let data = try await ok(.downloadsFolder(name))
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SlskdError.decoding }
            let names = { (key: String) in
                (object[key] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String }
            }
            return SlskdFolder(files: names("files"), folders: names("directories"))
        } catch SlskdError.http(status: 404) {
            return nil
        }
    }
}
