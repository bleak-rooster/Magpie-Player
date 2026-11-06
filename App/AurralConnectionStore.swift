import AurralKit
import Foundation
import MagpieCore
import NavidromeKit
import Observation

/// Round 13 item 1 (supersedes round 12's API key): the owner's Aurral (Discover), signed in as a user (Aurral's
/// playlists are per user). Its address, the username, the session Aurral handed out, and the password, kept so Magpie
/// can log in again when the session ends (Aurral 2.10 has no refresh route). All of it lives only in the Keychain
/// (same item and protection class as before: after first unlock, this device only), is never logged and never shown.
struct AurralConnection: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
                        CustomReflectable {
    var base: URL
    var username: String
    /// Kept only to log in again on a 401 or after `login.expiresAt`; nil once Aurral refused it (Z1 fix I1: saved
    /// so, with `login` nil too, so nothing is sent again until the owner signs in).
    var password: String?
    /// The session token and the user Aurral named, as last logged in.
    var login: AurralLogin?

    /// Which Aurral and which user (a new login for the same one isn't another connection).
    var account: Account { Account(base: base, username: username.lowercased()) }
    struct Account: Equatable, Sendable {
        var base: URL
        var username: String
    }

    // Fix M6: never prints the password or the token.
    var description: String { "AurralConnection(\(Redactor.sanitize(base)), \(username))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["base": Redactor.sanitize(base), "username": username]) }
}

/// Round 12's saved shape (address and API key), read only to delete it on upgrade.
private struct LegacyAurralConnection: Decodable {
    var base: URL
    var apiKey: String
}

/// One song's lookup for its main-library copy (fix M1): the copy, or none, and when it was looked up.
struct DiscoverLookup: Equatable {
    var copy: Song?
    var at: Date
}

/// A Refresh Flow Magpie sent (fix I3): when, and the flow's last run then (a change says the run finished).
struct RefreshLatch: Equatable {
    var startedAt: Date
    var lastRunAt: Date?
}

/// Where the Aurral connection is kept. Tests substitute their own.
protocol AurralConnectionStoring: Sendable {
    func save(_ connection: AurralConnection) throws
    func load() -> AurralConnection?
    func clear()
    /// Round 13: deletes a round-12 connection (address and API key) and hands back its address, so Settings can
    /// ask to sign in there; nil when there is none.
    func removeLegacyKey() -> URL?
}

/// Kept in the Keychain next to the Navidrome session and Lidarr (same service), never in UserDefaults.
struct AurralConnectionStore: AurralConnectionStoring {
    let keychain: KeychainStore

    static let standard = AurralConnectionStore(keychain: SessionStore.standard.keychain)

    private static let key = "aurral.connection"

    func save(_ connection: AurralConnection) throws {
        try keychain.set(JSONEncoder().encode(connection), for: Self.key)
    }

    func load() -> AurralConnection? {
        guard let data = try? keychain.get(Self.key) else { return nil }
        return try? JSONDecoder().decode(AurralConnection.self, from: data)
    }

    func clear() { try? keychain.remove(Self.key) }

    func removeLegacyKey() -> URL? {
        guard let data = try? keychain.get(Self.key), (try? JSONDecoder().decode(AurralConnection.self, from: data)) == nil
        else { return nil }
        let legacy = try? JSONDecoder().decode(LegacyAurralConnection.self, from: data)
        try? keychain.remove(Self.key)   // the API key (or anything unreadable) goes, whatever it was
        return legacy?.base
    }
}

/// Discover's state for the signed-in account (AppModel+Discover.swift): the Aurral connection, what Aurral last said,
/// the playlists that are its flows, and the main library's copies found for flow songs.
@MainActor @Observable final class DiscoverState {
    @ObservationIgnored let store: any AurralConnectionStoring
    /// The saved Aurral, if any. Discover shows only while there is one.
    var connection: AurralConnection?
    /// Round 13: the session every client is made from (re-logins shared), for `connection`'s account.
    @ObservationIgnored var session: AurralSession?
    /// Round 13: Aurral ended the session and Magpie couldn't log in again (no password, or Aurral refused it):
    /// Settings asks to sign in again.
    var needsSignIn = false
    /// Round 13: the address of a round-12 connection (API key) deleted on upgrade, until the owner signs in.
    var upgradedAddress: URL?
    /// Round 13: the logout last sent at sign-out (tests wait for it).
    @ObservationIgnored var pendingLogout: Task<Void, Never>?
    /// `/api/health`, as last read (Settings shows the version).
    var health: AurralHealth?
    /// Round 14 fix M3: `/api/health/bootstrap`, as last read signed in (capabilities, the user's permissions, the
    /// download sources: `AppModel+AurralCapabilities.swift`).
    var bootstrap: AurralBootstrap?
    /// When `bootstrap` was read.
    @ObservationIgnored var bootstrapReadAt: Date?
    /// Round 14 (D79 amendment): Aurral 2.13 refused the flow reads (403: this user has no accessFlow). Discover's
    /// shelves hide quietly; what was learnt (its playlists, its library) is kept, so they stay out of Playlists and
    /// the lists (D75, D76). Cleared by the next read Aurral allows.
    var flowsNotPermitted = false
    /// `/api/playlists/status`, as last read (the flows, the worker's progress).
    var status: AurralStatus?
    /// When `status` was read.
    @ObservationIgnored var statusReadAt: Date?
    /// Every flow song Aurral knows, as last read (empty when its route is missing).
    var jobs: [AurralJob] = []
    /// The Navidrome playlists that are Aurral's flows, as last matched.
    var playlists: [DiscoverPlaylist] = []
    /// Every song id seen in a Discover playlist (Aurral's copies): never a "library copy" of anything.
    var flowSongIds: Set<String> = []
    /// The main library's copy of a flow song, by the flow song's id (what Discover shows and plays in its place).
    var copies: [String: Song] = [:]
    /// Album ids of Aurral's copies (an artist page hides one whose every song has a library copy).
    var flowAlbumSongs: [String: Set<String>] = [:]
    /// The clock (tests move it).
    @ObservationIgnored var now: () -> Date = { Date() }
    /// A Refresh Flow just sent, per flow, until Aurral's status speaks for it (`AppModel.noteStatus`).
    var refreshing: [String: RefreshLatch] = [:]
    /// Round 16: recipe flows deleted here whose queued delete Aurral hasn't run yet (kept out of Your flows).
    var deletingFlowIds: Set<String> = []
    /// Round 13 Z2: the read of Aurral under way, shared by every screen that asks (`refreshDiscover(waitingAtMost:)`).
    @ObservationIgnored var refreshTask: (id: UUID, task: Task<Void, Never>)?
    /// Every song in Aurral's library, as last read this session (fix I2; saved per account too).
    var aurralSongIds: Set<String> = []
    /// Each song's library-copy lookup this session (fix M1).
    @ObservationIgnored var lookups: [String: DiscoverLookup] = [:]
    /// Round 23 R23F (D189): the matched playlists that are other users' flows' or playlists', as last read.
    var othersPlaylistIds: Set<String> = []
    /// Round 23 R23F (D190): bumped when "Show everyone's flows" changes (Library › Discover lists again).
    var everyoneRevision = 0
    /// Round 23 R23F (D199): "Search again for missing songs", per flow or playlist id, this session.
    var searchAgain: [String: SearchAgainRun] = [:]

    init(store: any AurralConnectionStoring) {
        self.store = store
        self.upgradedAddress = store.removeLegacyKey()
        self.connection = store.load()
        self.session = connection.map(makeSession)
        self.needsSignIn = connection.map { $0.password == nil && $0.login == nil } ?? false   // fix I1: after a refusal
    }

    /// A session for `connection`; each new login is saved to the Keychain (for the same account only).
    func makeSession(_ connection: AurralConnection) -> AurralSession {
        AurralSession(username: connection.username, password: connection.password, login: connection.login,
                      onLogin: { [weak self] login in Task { @MainActor in self?.renewed(login, for: connection.account) } },
                      onRefused: { [weak self] in Task { @MainActor in self?.refused(for: connection.account) } })
    }

    /// Z1 fix I1: Aurral refused the saved password. It and the token are forgotten in the Keychain (the address and
    /// username stay, to sign in again), so no later launch sends it again.
    func refused(for account: AurralConnection.Account) {
        needsSignIn = true
        guard var current = connection, current.account == account else { return }
        current.password = nil
        current.login = nil
        do { try store.save(current) } catch {
            Log.logger("aurral").error("couldn't save the signed-out Aurral: \(Log.category(of: error), privacy: .public)")
        }
        connection = current
    }

    /// Aurral logged Magpie in again: the new session replaces the old one in the Keychain.
    func renewed(_ login: AurralLogin, for account: AurralConnection.Account) {
        guard var current = connection, current.account == account else { return }
        current.login = login
        do { try store.save(current) } catch {   // fix M6
            Log.logger("aurral").error("couldn't save the renewed Aurral session: \(Log.category(of: error), privacy: .public)")
        }
        connection = current
        needsSignIn = false
    }

    /// Signed in (or out): the connection and its session.
    func use(_ connection: AurralConnection?) {
        self.connection = connection
        session = connection.map(makeSession)
        needsSignIn = false
        if connection != nil { upgradedAddress = nil }
    }

    /// Forgets everything read for the account (sign-out, another Aurral).
    func forgetReads() {
        health = nil
        bootstrap = nil
        bootstrapReadAt = nil
        flowsNotPermitted = false
        status = nil
        statusReadAt = nil
        jobs = []
        playlists = []
        flowSongIds = []
        copies = [:]
        flowAlbumSongs = [:]
        refreshing = [:]
        aurralSongIds = []
        lookups = [:]
        othersPlaylistIds = []   // R23F
        searchAgain = [:]   // R23F
        refreshTask?.task.cancel()   // Round 13 Z2: the next account's first ask starts its own read
        refreshTask = nil
    }
}
