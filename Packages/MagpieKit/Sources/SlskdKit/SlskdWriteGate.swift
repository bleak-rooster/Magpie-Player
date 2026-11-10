import CryptoKit
import Foundation
import MagpieCore

// Round 23 (owner, 2026-11-07, D192): slskd's write gate. Round 24 fix round 2 (R1): in its own file, so the pass the
// channel's writes need (`SlskdGatePass`, a fileprivate initialiser) can only be made here.

/// Proof that a write comes from `SlskdWriteGate`: `SlskdConnection.send` takes nothing else, and only this file can make
/// one.
struct SlskdGatePass: Sendable {
    /// Fix round 3 (R2.1): a stored value only this file's initialiser sets, so an initialiser added elsewhere (an
    /// extension in another file) can't make one: it could never initialise `token`.
    private let token: UInt8

    fileprivate init() { token = 0x5D }
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
        let (_, response) = try await client.connection.send(route, pass: SlskdGatePass())
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

    /// Where the owner's "Keep Soulseek connected" record for this slskd is saved (the key carries the address-and-key
    /// scope).
    var keepConnectedRecordKey: String { Self.keepConnectedKey(scope: client.instanceScope) }

    /// The address as it was first recorded (lower case, no trailing slash). Security review D-L1: never stored any
    /// more; only read to recognise a record saved in that old form.
    static func plainRecord(for base: URL) -> String {
        var text = base.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// What the record saves for `base` (security review D-L1): a hash of the address, never the address itself, which
    /// lives only in the Keychain. It still ties the record to this address, so a record copied under another key fails.
    static func keepConnectedRecord(for base: URL) -> String {
        let digest = SHA256.hash(data: Data("slskd-keep-connected|\(plainRecord(for: base))".utf8))
        return "v2:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The record, read for one slskd (`scope` is its client's `instanceScope`). The one place its format lives (fix
    /// round 1 M5): the gate and the app's switch both use these. A record in the old form (the address in plain text)
    /// counts as on, still only under this scope, and is rewritten in the new form at once (D-L1).
    public static func keepConnected(in defaults: UserDefaults, scope: String, base: URL) -> Bool {
        let key = keepConnectedKey(scope: scope)
        guard let saved = defaults.string(forKey: key) else { return false }
        if saved == keepConnectedRecord(for: base) { return true }
        guard saved == plainRecord(for: base) else { return false }
        defaults.set(keepConnectedRecord(for: base), forKey: key)
        return true
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
        let (_, response) = try await client.connection.send(.connect, pass: SlskdGatePass())
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
