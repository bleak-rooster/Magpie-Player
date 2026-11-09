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

// MARK: - The gate

/// One clean-up write (see `SlskdRoute`).
public enum SlskdWrite: Sendable, Equatable {
    /// A finished transfer's record (`remove=true`).
    case removeTransfer(username: String, id: UUID)
    /// One file of a folder directly inside slskd's downloads folder.
    case deleteFile(folder: String, file: String)
    /// An empty folder directly inside slskd's downloads folder (fix round 1 M2).
    case deleteFolder(String)
    /// Round 24 (D218): ask slskd to connect to the Soulseek network (`PUT /api/v0/server`, no body). Only while
    /// "Keep Soulseek connected" is on for this address and key, only when slskd says it is down, at most once a minute.
    case connect
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
/// - a folder goes only when it is empty now (fix round 1 M2: slskd's folder delete is recursive, so its files go one by
///   one under the file rule first).
/// Names are one level deep and never `.`/`..` or a separator (`SlskdRoute.isSafeName`), so nothing outside the
/// downloads folder can be named. Which downloads are an artist's, the runner decides (`SlskdLeftovers`); this gate
/// keeps that decision from reaching anything in progress or anything slskd didn't download.
/// Round 24 (D218): one more shape, `connect` (ask slskd to reconnect to Soulseek), with its own switch ("Keep Soulseek
/// connected", a record saved per slskd naming its address) instead of "Allow Magpie to change Soulseek": it changes
/// no data. Refused unless that record is on for this address and key, slskd reads disconnected and not transitioning
/// just now, and the last ask is a minute old; the time of the ask is saved before it is sent.
public actor SlskdWriteGate {
    public static let enabledDefaultsKey = "magpie.slskd.writesEnabled"
    public static func enabledKey(scope: String) -> String { "\(enabledDefaultsKey).\(scope)" }

    private let client: SlskdClient
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    public init(client: SlskdClient, defaultsSuite: String? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.defaults = defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.now = now
    }

    /// "Allow Magpie to change Soulseek". Persisted per slskd; false until the owner turns it on.
    public var enabled: Bool { defaults.bool(forKey: Self.enabledKey(scope: client.instanceScope)) }

    public func setEnabled(_ on: Bool) { defaults.set(on, forKey: Self.enabledKey(scope: client.instanceScope)) }

    /// Checks `write` on fresh reads and sends it. Throws `SlskdGateError` (nothing sent) or `SlskdError` (slskd's
    /// answer; a 404 means it was already gone).
    public func perform(_ write: SlskdWrite) async throws {
        if write == .connect { return try await connect() }   // Round 24 (D218): its own switch and proofs, below
        guard enabled else { throw SlskdGateError.disabled }
        let route: SlskdRoute
        switch write {
        case .removeTransfer(let username, let id): route = .removeTransfer(username: username, id: id)
        case .deleteFile(let folder, let file): route = .deleteFile(folder: folder, file: file)
        case .deleteFolder(let folder): route = .deleteFolder(folder)
        case .connect: throw SlskdGateError.refused("not a clean-up")
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
        case .connect:
            throw SlskdGateError.refused("not a clean-up")
        case .deleteFolder(let folder):
            // Fix round 1 M2: slskd deletes a folder with everything in it, so only an empty one, read just now.
            let listing = try await readFolder(folder)
            guard listing.folders.isEmpty, listing.files.isEmpty else { throw SlskdGateError.refused("the folder isn't empty") }
        }
        guard enabled else { throw SlskdGateError.disabled }   // turned off during the reads
        let (_, response) = try await client.connection.send(route)
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw SlskdError.unauthorized
        default: throw SlskdError.http(status: response.statusCode)
        }
    }

    // MARK: Round 24: Keep Soulseek connected (D218)

    public static let keepConnectedDefaultsKey = "magpie.slskd.keepConnected"
    public static func keepConnectedKey(scope: String) -> String { "\(keepConnectedDefaultsKey).\(scope)" }
    public static func lastConnectKey(scope: String) -> String { "magpie.slskd.lastConnect.\(scope)" }
    /// Fix round 1 M3: slskd refused this address and key's ask (401/403); no more asks until the key changes.
    public static func keyRefusedKey(scope: String) -> String { "magpie.slskd.connectRefused.\(scope)" }

    /// Where the owner's "Keep Soulseek connected" record for this slskd is saved: the address it was turned on for.
    var keepConnectedRecordKey: String { Self.keepConnectedKey(scope: client.instanceScope) }

    /// What the record saves for `base`: the address, lower case, without a trailing slash.
    static func keepConnectedRecord(for base: URL) -> String {
        var text = base.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// The record, read for one slskd (`scope` is its client's `instanceScope`). The one place its format lives (fix
    /// round 1 M5): the gate and the app's switch both use these.
    public static func keepConnected(in defaults: UserDefaults, scope: String, base: URL) -> Bool {
        defaults.string(forKey: keepConnectedKey(scope: scope)) == keepConnectedRecord(for: base)
    }

    /// Saves (or removes) the record for one slskd. Turned on, it names this address; a new address or key starts off.
    public static func setKeepConnected(_ on: Bool, in defaults: UserDefaults, scope: String, base: URL) {
        if on {
            defaults.set(keepConnectedRecord(for: base), forKey: keepConnectedKey(scope: scope))
        } else {
            defaults.removeObject(forKey: keepConnectedKey(scope: scope))
        }
    }

    /// "Keep Soulseek connected": on only when its record, saved before any ask, names this address (and lives under
    /// this address and key's scope). False until the owner turns it on.
    public var keepConnected: Bool {
        Self.keepConnected(in: defaults, scope: client.instanceScope, base: client.connection.base)
    }

    public func setKeepConnected(_ on: Bool) {
        Self.setKeepConnected(on, in: defaults, scope: client.instanceScope, base: client.connection.base)
    }

    /// When Magpie last asked this slskd to connect (saved before the ask was sent).
    public var lastConnect: Date? { defaults.object(forKey: Self.lastConnectKey(scope: client.instanceScope)) as? Date }

    /// slskd refused this key's ask to reconnect (fix round 1 M3). Cleared only with the key (a new scope).
    public var keyRefused: Bool { defaults.bool(forKey: Self.keyRefusedKey(scope: client.instanceScope)) }

    /// The switch is on, the key hasn't been refused, and the last ask is at least `SlskdKeepConnected.connectCooldown`
    /// old. Fix round 1 M1: a last ask in the future (the clock was set back) counts as made now, so the minute starts
    /// again rather than never ending.
    public func mayAskToConnect() -> Bool {
        guard keepConnected, !keyRefused else { return false }
        guard let lastConnect else { return true }
        let now = now()
        if lastConnect > now {
            defaults.set(now, forKey: Self.lastConnectKey(scope: client.instanceScope))
            return false
        }
        return now.timeIntervalSince(lastConnect) >= SlskdKeepConnected.connectCooldown
    }

    /// The `connect` shape: refused unless the owner's record is on for this address and key, the key wasn't refused,
    /// the last ask is a minute old, and slskd, read just now, says it is disconnected and not transitioning. The time of
    /// the ask is saved before it is sent (M6), so a lost answer is never followed by another ask within the minute.
    /// Never a disconnect.
    private func connect() async throws {
        guard keepConnected else { throw SlskdGateError.refused("Keep Soulseek connected is off for this slskd") }
        guard mayAskToConnect() else { throw SlskdGateError.refused("asked less than a minute ago") }
        let state: SlskdServerState
        do { state = try await client.serverState() } catch { throw SlskdGateError.unconfirmed }
        guard state.condition == .down else { throw SlskdGateError.refused("slskd isn't disconnected now") }
        guard mayAskToConnect() else { throw SlskdGateError.refused("turned off during the read") }
        defaults.set(now(), forKey: Self.lastConnectKey(scope: client.instanceScope))
        let (_, response) = try await client.connection.send(.connect)
        switch response.statusCode {
        case 200..<300: return
        case 401, 403:
            defaults.set(true, forKey: Self.keyRefusedKey(scope: client.instanceScope))
            throw SlskdError.unauthorized
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
