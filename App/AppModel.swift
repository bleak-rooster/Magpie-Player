import DesignSystem
import Foundation
import MagpieCore
import NavidromeKit
import Observation
import Playback
#if os(iOS)
import UIKit
#endif

/// A signed-in Navidrome session.
struct Session {
    let client: NavidromeClient
    /// The addresses as entered, in order (what is saved).
    let endpoint: ServerEndpoint
    let credentials: NavidromeCredentials
    /// The address the client is using now.
    var activeBase: URL
    var isAdmin: Bool
    var username: String { credentials.username }
}

/// Why signing in failed, before any copy is applied (see `ConnectErrorCopy`).
enum SignInError: Error {
    case noAddress
    case invalidAddress(String)
    /// No address answered. One failure per address, in order.
    case unreachable([ProbeFailure])
}

struct ProbeFailure {
    let url: URL
    let error: Error
}

/// App-wide state: the session, the player and the look. Owns no UI, so the CarPlay scene can share
/// `AppModel.shared` with the phone UI.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel.restore()

    private(set) var session: Session?
    let player: Player
    var theme: Theme
    /// Star changes made this session, by song id (the queue's copies of songs are not edited).
    private(set) var starOverrides: [String: Bool] = [:]
    /// A session is saved but the Keychain can't be read yet (before first unlock). Not signed out:
    /// the UI waits, and the session is restored when protected data becomes available.
    private(set) var isWaitingForUnlock = false

    @ObservationIgnored private let store: any SessionStoring
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?
    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private let probeTransport: HTTPTransport
    @ObservationIgnored private let box: ClientBox
    @ObservationIgnored private var reconnectTask: Task<Bool, Never>?
    @ObservationIgnored private var errorWatch: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?
    #endif

    init(store: any SessionStoring = SessionStore.standard,
         transport: HTTPTransport = URLSessionTransport(),
         probeTransport: HTTPTransport = URLSessionTransport(timeout: 6),
         engine: (any PlaybackEngine)? = nil,
         defaults: UserDefaults = .standard,
         theme: Theme = Theme(),
         systemNowPlaying: Bool = true) {
        let box = ClientBox()
        self.store = store
        self.transport = transport
        self.probeTransport = probeTransport
        self.box = box
        self.theme = theme
        self.player = Player(engine: engine ?? AVQueueEngine(), scrobbler: NavidromeScrobbler(box: box),
                             urls: NavidromeStreamURLs(box: box), defaults: defaults)
        #if os(iOS)
        if systemNowPlaying {
            nowPlaying = NowPlayingBridge(
                player: player,
                artworkURL: { [weak self] song in self?.coverArtURL(song.coverArtId, size: 600) },
                onLike: { [weak self] song in Task { await self?.toggleStar(song) } })
        }
        #endif
        watchPlaybackErrors()
    }

    /// Builds the shared model from what the Keychain holds. `-MagpieResetState YES` signs out first
    /// (UI tests). `-MagpieCharacter classic|signature|immersive` picks the look.
    static func restore(store: any SessionStoring = SessionStore.standard, defaults: UserDefaults = .standard) -> AppModel {
        if defaults.bool(forKey: "MagpieResetState") { store.clear() }
        var theme = Theme()
        if let raw = defaults.string(forKey: "MagpieCharacter"), let c = Character(rawValue: raw) { theme.character = c }
        let model = AppModel(store: store, defaults: defaults, theme: theme)
        model.resumeSavedSession()
        return model
    }

    /// Starts using the saved session without waiting for the network, then connects in the background.
    /// If the Keychain is locked, waits for `protectedDataDidBecomeAvailable` and tries again.
    func resumeSavedSession() {
        let saved: SavedSession
        switch store.load() {
        case .none:
            isWaitingForUnlock = false
            return
        case .unavailable:
            isWaitingForUnlock = true
            observeUnlock()
            return
        case .session(let s):
            saved = s
        }
        isWaitingForUnlock = false
        stopObservingUnlock()
        guard session == nil else { return }
        let client = makeClient(saved.endpoint, saved.credentials)
        session = Session(client: client, endpoint: saved.endpoint, credentials: saved.credentials,
                          activeBase: saved.endpoint.bases[0], isAdmin: false)
        box.set(client)
        Task { await reconnect(rebuildAlways: true) }
    }

    /// Protected data (the Keychain) became readable: retry the restore.
    func protectedDataBecameAvailable() {
        guard isWaitingForUnlock else { return }
        resumeSavedSession()
    }

    private func observeUnlock() {
        #if os(iOS)
        guard unlockObserver == nil else { return }
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.protectedDataBecameAvailable() }
            } else {
                Task { @MainActor in self?.protectedDataBecameAvailable() }
            }
        }
        #endif
    }

    private func stopObservingUnlock() {
        if let unlockObserver { NotificationCenter.default.removeObserver(unlockObserver) }
        unlockObserver = nil
    }

    // MARK: - Sign in / out

    /// Tries each address in order; the first that answers is used. Saves to the Keychain on success.
    func signIn(urls: [URL], username: String, password: String) async throws {
        guard !urls.isEmpty else { throw SignInError.noAddress }
        let endpoint = ServerEndpoint(bases: urls)
        var failures: [ProbeFailure] = []
        var reached: URL?
        for base in urls {
            if let error = await probe(base) {
                failures.append(ProbeFailure(url: base, error: error))
            } else {
                reached = base
                break
            }
        }
        guard let base = reached else { throw SignInError.unreachable(failures) }
        let credentials = NavidromeCredentials(username: username, password: password)
        let client = makeClient(Self.preferring(base, in: endpoint), credentials)
        let login = try await client.connect()
        try store.save(endpoint: endpoint, credentials: credentials)
        reconnectTask = nil
        starOverrides = [:]
        isWaitingForUnlock = false
        stopObservingUnlock()
        ArtworkCache.shared.removeAll()
        session = Session(client: client, endpoint: endpoint, credentials: credentials,
                          activeBase: base, isAdmin: login.isAdmin)
        box.set(client)
    }

    /// Stops playback, forgets the server and clears the Keychain.
    func signOut() {
        player.play([], startAt: 0)
        store.clear()
        session = nil
        starOverrides = [:]
        reconnectTask = nil
        isWaitingForUnlock = false
        stopObservingUnlock()
        box.set(nil)
        ArtworkCache.shared.removeAll()
    }

    // MARK: - Requests with failover

    /// Runs `op` against the current client. On a connection error, re-probes the addresses, moves
    /// to the first that answers (rebuilding the client and the player's stream URLs) and retries once.
    func request<T: Sendable>(_ op: @Sendable (NavidromeClient) async throws -> T) async throws -> T {
        guard let client = session?.client else { throw NavidromeError.noReachableServer }
        do {
            return try await op(client)
        } catch where Self.isConnectionError(error) {
            guard await reconnect(rebuildAlways: false), let retry = session?.client else { throw error }
            return try await op(retry)
        }
    }

    nonisolated static func isConnectionError(_ error: Error) -> Bool {
        if let e = error as? NavidromeError { return e == .noReachableServer }
        guard let e = error as? URLError else { return false }
        return [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed,
                .notConnectedToInternet, .internationalRoamingOff, .cannotLoadFromNetwork].contains(e.code)
    }

    /// Single-flight. Returns true when the session is on an address that answers.
    @discardableResult
    func reconnect(rebuildAlways: Bool) async -> Bool {
        if let task = reconnectTask { return await task.value }
        let task = Task { await performReconnect(rebuildAlways: rebuildAlways) }
        reconnectTask = task
        let ok = await task.value
        if reconnectTask == task { reconnectTask = nil }
        return ok
    }

    private func performReconnect(rebuildAlways: Bool) async -> Bool {
        guard let old = session else { return false }
        var reached: URL?
        for base in old.endpoint.bases where await probe(base) == nil {
            reached = base
            break
        }
        guard let base = reached else { return false }
        if base == old.activeBase, !rebuildAlways { return true }   // a blip; the same address answers again
        let client = makeClient(Self.preferring(base, in: old.endpoint), old.credentials)
        guard let login = try? await client.connect() else { return false }
        guard let current = session, current.client === old.client else { return false }   // signed out/in meanwhile
        session = Session(client: client, endpoint: old.endpoint, credentials: old.credentials,
                          activeBase: base, isAdmin: login.isAdmin)
        box.set(client)
        if base != old.activeBase {
            Log.logger("session").info("switched server address")
            player.urlsInvalidated()
        }
        return true
    }

    /// When the current song fails to stream, check whether another address answers.
    private func watchPlaybackErrors() {
        errorWatch = Task { [weak self, player] in
            let errors = Observations { @MainActor in player.lastError }
            for await error in errors where error != nil {
                guard let self else { return }
                guard self.session != nil else { continue }
                await self.reconnect(rebuildAlways: false)
            }
        }
    }

    /// Nil when `base` answers `/rest/ping` with 2xx; otherwise the error (URLError or HTTP status).
    func probe(_ base: URL) async -> Error? {
        let url = ServerEndpoint(bases: [base]).url(base, path: "rest/ping", query: [
            URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: "Magpie"),
            URLQueryItem(name: "f", value: "json"),
        ])
        do {
            let (_, response) = try await probeTransport.send(URLRequest(url: url))
            return (200..<300).contains(response.statusCode) ? nil : NavidromeError.http(status: response.statusCode)
        } catch {
            return error
        }
    }

    private func makeClient(_ endpoint: ServerEndpoint, _ credentials: NavidromeCredentials) -> NavidromeClient {
        NavidromeClient(endpoint: endpoint, credentials: credentials, transport: transport)
    }

    /// The same addresses with `base` first, so the client tries the one that just answered.
    nonisolated static func preferring(_ base: URL, in endpoint: ServerEndpoint) -> ServerEndpoint {
        ServerEndpoint(bases: [base] + endpoint.bases.filter { $0 != base })
    }

    // MARK: - Library helpers

    /// Identifies the server and account cover art belongs to, so cached art never crosses accounts.
    /// Stable across address failover (same server, different route).
    var artworkScope: String? {
        guard let s = session else { return nil }
        return "\(s.endpoint.bases[0].absoluteString)|\(s.username)"
    }

    func coverArtURL(_ id: String?, size: Int) -> URL? {
        guard let id, let client = session?.client else { return nil }
        return client.coverArtURL(id: id, size: size)
    }

    func play(_ songs: [Song], startAt: Int) {
        guard !songs.isEmpty else { return }
        player.play(songs, startAt: startAt)
    }

    func shuffle(_ songs: [Song]) {
        play(songs.shuffled(), startAt: 0)
    }

    func isStarred(_ song: Song) -> Bool { starOverrides[song.id] ?? song.starred }

    /// Optimistic: flips at once, reverts if the server says no.
    func toggleStar(_ song: Song) async {
        let target = !isStarred(song)
        starOverrides[song.id] = target
        do {
            try await request { client in
                target ? try await client.star(id: song.id) : try await client.unstar(id: song.id)
            }
        } catch {
            starOverrides[song.id] = !target
            Log.logger("session").error("star failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
