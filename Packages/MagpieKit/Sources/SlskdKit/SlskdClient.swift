import CryptoKit
import Foundation
import MagpieCore

// Round 23 (owner, 2026-11-07, D192): the optional slskd connection. The HTTP channel (`SlskdConnection`) is defined
// in this file so that `fileprivate` keeps its writes to `SlskdWriteGate`: `SlskdClient` can only read.

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
    fileprivate let base: URL
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
        return try await send(route)
    }

    fileprivate func send(_ route: SlskdRoute) async throws -> (Data, HTTPURLResponse) {
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

// MARK: - The gate

/// One clean-up write (see `SlskdRoute`).
public enum SlskdWrite: Sendable, Equatable {
    /// A finished transfer's record (`remove=true`).
    case removeTransfer(username: String, id: UUID)
    /// One file of a folder directly inside slskd's downloads folder.
    case deleteFile(folder: String, file: String)
    /// A folder directly inside slskd's downloads folder, with its files, when every file in it is one of `only`.
    case deleteFolder(String, only: Set<String>)
}

public enum SlskdGateError: Error, Sendable, Equatable {
    /// "Allow Magpie to change Soulseek" is off. Nothing was sent.
    case disabled
    /// Not something Magpie may change (see `SlskdWriteGate`). Nothing was sent.
    case refused(String)
    /// slskd couldn't be read to check it. Nothing was sent.
    case unconfirmed
}

/// The only way Magpie changes slskd (D192). Off until the owner turns on "Allow Magpie to change Soulseek" (per slskd:
/// a new address or key starts off). Each write is checked against slskd's own state, read fresh right before it:
/// - a transfer record goes only when slskd lists it now, for that user, finished;
/// - a file goes only when it is in the named folder directly inside the downloads folder now, a finished, complete
///   download of that name is in slskd's list, and no unfinished download of that name is;
/// - a folder goes only when it holds no folder, at least one file, every file is one of the caller's (`only`) and each
///   passes the file rule.
/// Names are one level deep and never `.`/`..` or a separator (`SlskdRoute.isSafeName`), so nothing outside the
/// downloads folder can be named. Which downloads are an artist's, the runner decides (`SlskdLeftovers`); this gate
/// keeps that decision from reaching anything in progress or anything slskd didn't download.
public actor SlskdWriteGate {
    public static let enabledDefaultsKey = "magpie.slskd.writesEnabled"
    public static func enabledKey(scope: String) -> String { "\(enabledDefaultsKey).\(scope)" }

    private let client: SlskdClient
    private let defaults: UserDefaults

    public init(client: SlskdClient, defaultsSuite: String? = nil) {
        self.client = client
        self.defaults = defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// "Allow Magpie to change Soulseek". Persisted per slskd; false until the owner turns it on.
    public var enabled: Bool { defaults.bool(forKey: Self.enabledKey(scope: client.instanceScope)) }

    public func setEnabled(_ on: Bool) { defaults.set(on, forKey: Self.enabledKey(scope: client.instanceScope)) }

    /// Checks `write` on fresh reads and sends it. Throws `SlskdGateError` (nothing sent) or `SlskdError` (slskd's
    /// answer; a 404 means it was already gone).
    public func perform(_ write: SlskdWrite) async throws {
        guard enabled else { throw SlskdGateError.disabled }
        let route: SlskdRoute
        switch write {
        case .removeTransfer(let username, let id): route = .removeTransfer(username: username, id: id)
        case .deleteFile(let folder, let file): route = .deleteFile(folder: folder, file: file)
        case .deleteFolder(let folder, _): route = .deleteFolder(folder)
        }
        guard route.segments != nil else { throw SlskdGateError.refused("not a name inside the downloads folder") }
        let transfers: [SlskdTransfer]
        do { transfers = try await client.downloads() } catch { throw SlskdGateError.unconfirmed }
        switch write {
        case .removeTransfer(let username, let id):
            guard transfers.contains(where: { $0.id == id && $0.username == username && $0.isFinished }) else {
                throw SlskdGateError.refused("not a finished download slskd lists now")
            }
        case .deleteFile(let folder, let file):
            let listing = try await readFolder(folder)
            guard listing.files.contains(file) else { throw SlskdGateError.refused("no such file there now") }
            try Self.mayDelete(file, transfers)
        case .deleteFolder(let folder, let only):
            let listing = try await readFolder(folder)
            guard listing.folders.isEmpty, !listing.files.isEmpty, listing.files.allSatisfy(only.contains) else {
                throw SlskdGateError.refused("the folder holds something else")
            }
            for file in listing.files { try Self.mayDelete(file, transfers) }
        }
        guard enabled else { throw SlskdGateError.disabled }   // turned off during the reads
        let (_, response) = try await client.connection.send(route)
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw SlskdError.unauthorized
        default: throw SlskdError.http(status: response.statusCode)
        }
    }

    private func readFolder(_ name: String) async throws -> SlskdFolder {
        let listing: SlskdFolder?
        do { listing = try await client.folder(name) } catch { throw SlskdGateError.unconfirmed }
        guard let listing else { throw SlskdGateError.refused("no such folder now") }
        return listing
    }

    private static func mayDelete(_ file: String, _ transfers: [SlskdTransfer]) throws {
        let named = transfers.filter { $0.fileName == file }
        guard named.contains(where: \.succeeded) else { throw SlskdGateError.refused("not a file slskd finished downloading") }
        guard !named.contains(where: { !$0.isFinished }) else { throw SlskdGateError.refused("a download of that name is under way") }
    }
}
