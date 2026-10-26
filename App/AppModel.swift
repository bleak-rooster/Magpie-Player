import DesignSystem
import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
import MatchIndex
import NavidromeKit
import Observation
import Playback
import Requests
import Search
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
    /// OpenSubsonic extensions the server advertises (A13), fetched once per session.
    private(set) var advertisedExtensions: Set<String>?
    /// A session is saved but the Keychain can't be read yet (before first unlock). Not signed out:
    /// the UI waits, and the session is restored when protected data becomes available.
    private(set) var isWaitingForUnlock = false
    // The request/settings state below is set from AppModel+Requests.swift (internal setters); views only read it.

    /// The owner's Lidarr, when connected. Kept in the Keychain next to the session.
    private(set) var lidarr: LidarrConnection?
    /// "Allow Magpie to change Lidarr" (G1): mirrors the write gate's persisted switch. Off by default.
    var changesAllowed: Bool
    /// Provisioning results and the main root folder for the connected Lidarr.
    var lidarrSetup: LidarrSetup?
    /// The connected Lidarr's setup as last read (speed tier, root folders). Nil until read.
    var lidarrStatus: LidarrAudit?
    /// Try requests, newest last (from the runner).
    var requests: [MagpieRequest] = []
    /// G8 "Count plays": scrobbling on (default) or off.
    var countPlays: Bool
    /// Whether an optional ListenBrainz token is saved.
    var hasListenBrainzToken = false
    /// The scene is active: requests poll every 5 s, otherwise every 30 s.
    var isForeground = true {
        didSet { if isForeground, !oldValue { pollRequests() } }
    }

    @ObservationIgnored private let store: any SessionStoring
    @ObservationIgnored private let lidarrStore: any LidarrConnectionStoring
    @ObservationIgnored let tokenStore: any ListenBrainzTokenStoring
    @ObservationIgnored let setupStore: LidarrSetupStore
    @ObservationIgnored let gateDefaultsSuite: String?
    @ObservationIgnored let gateDefaults: UserDefaults
    @ObservationIgnored let appDefaults: UserDefaults
    /// Where the change log, ledger and requests live (Application Support/Magpie).
    @ObservationIgnored let dataDirectory: URL
    /// The ledger and requests of the connected Lidarr (scoped by `LidarrClient.instanceScope`, so another
    /// server's ids are never acted on). Rebuilt with the runner; the ledger re-reads its file on every call.
    @ObservationIgnored var ledger: Ledger?
    @ObservationIgnored var requestStore: RequestStore?
    @ObservationIgnored var gate: LidarrWriteGate?
    @ObservationIgnored var runner: RequestRunner?
    @ObservationIgnored var runnerTasks: [Task<Void, Never>] = []
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var pollGeneration = 0
    @ObservationIgnored let playCounting: PlayCounting
    @ObservationIgnored let notifications: Bool
    /// The library's match index for the signed-in server and account (nil when signed out).
    @ObservationIgnored private(set) var matchIndex: MatchIndexStore?
    @ObservationIgnored private var matchIndexTask: Task<Void, Never>?
    @ObservationIgnored private let matchIndexDirectory: URL?
    @ObservationIgnored private var musicBrainzClient: MusicBrainzClient?
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?
    @ObservationIgnored let transport: HTTPTransport
    @ObservationIgnored private let probeTransport: HTTPTransport
    @ObservationIgnored private let box: ClientBox
    @ObservationIgnored private var reconnectTask: Task<Bool, Never>?
    @ObservationIgnored private var errorWatch: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?
    #endif

    /// - Parameter matchIndexDirectory: where match-index snapshots go (Application Support); nil keeps
    ///   them in memory only (tests).
    /// - Parameter dataDirectory: where the Lidarr change log, ledger and requests go; nil uses a fresh
    ///   temporary folder (tests).
    /// - Parameter gateDefaultsSuite: UserDefaults suite of the "Allow Magpie to change Lidarr" switch (nil: standard).
    init(store: any SessionStoring = SessionStore.standard,
         lidarrStore: any LidarrConnectionStoring = LidarrConnectionStore.standard,
         tokenStore: any ListenBrainzTokenStoring = ListenBrainzTokenStore.standard,
         matchIndexDirectory: URL? = URL.applicationSupportDirectory,
         dataDirectory: URL? = URL.applicationSupportDirectory,
         gateDefaultsSuite: String? = nil,
         transport: HTTPTransport = URLSessionTransport(),
         probeTransport: HTTPTransport = URLSessionTransport(timeout: 6),
         engine: (any PlaybackEngine)? = nil,
         defaults: UserDefaults = .standard,
         theme: Theme = Theme(),
         systemNowPlaying: Bool = true,
         notifications: Bool = true) {
        let box = ClientBox()
        self.store = store
        self.lidarrStore = lidarrStore
        self.tokenStore = tokenStore
        self.matchIndexDirectory = matchIndexDirectory
        self.lidarr = lidarrStore.load()
        self.transport = transport
        self.probeTransport = probeTransport
        self.box = box
        self.theme = theme
        self.notifications = notifications
        let data = dataDirectory ?? FileManager.default.temporaryDirectory.appending(path: "magpie-\(UUID().uuidString)")
        self.dataDirectory = data
        self.gateDefaultsSuite = gateDefaultsSuite
        self.gateDefaults = gateDefaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.changesAllowed = false
        self.appDefaults = defaults
        self.setupStore = LidarrSetupStore(defaults: defaults)
        self.countPlays = defaults.object(forKey: Self.countPlaysKey) as? Bool ?? true
        self.hasListenBrainzToken = tokenStore.load() != nil
        let counting = PlayCounting(on: defaults.object(forKey: Self.countPlaysKey) as? Bool ?? true)
        self.playCounting = counting
        self.player = Player(engine: engine ?? AVQueueEngine(),
                             scrobbler: NavidromeScrobbler(box: box, counting: counting),
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
        if let scope = lidarrScope, let lidarr {
            changesAllowed = gateDefaults.bool(forKey: LidarrWriteGate.enabledKey(scope: scope))
            lidarrSetup = setupStore.load(base: lidarr.base, scope: scope)
        }
    }

    /// Builds the shared model from what the Keychain holds. `-MagpieResetState YES` signs out first
    /// (UI tests). `-MagpieCharacter classic|signature|immersive` picks the look.
    static func restore(store: any SessionStoring = SessionStore.standard, defaults: UserDefaults = .standard) -> AppModel {
        if defaults.bool(forKey: "MagpieResetState") {
            store.clear()
            LidarrConnectionStore.standard.clear()
        }
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
        startMatchIndex()
        rebuildRunner()
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
        // Security H2: the password never goes over plain http to a public address without the owner's say-so.
        let unencrypted = urls.filter { !plainHTTPConsent.allows($0) }
        guard unencrypted.isEmpty else { throw PlainHTTPConsentRequired(urls: unencrypted) }
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
        advertisedExtensions = nil
        isWaitingForUnlock = false
        stopObservingUnlock()
        ArtworkCache.shared.removeAll()
        session = Session(client: client, endpoint: endpoint, credentials: credentials,
                          activeBase: base, isAdmin: login.isAdmin)
        box.set(client)
        startMatchIndex()
        rebuildRunner()
    }

    /// Stops playback, forgets the server and clears the Keychain.
    func signOut() {
        let retiring = runner, doomed = requestStore
        player.play([], startAt: 0)
        store.clear()
        session = nil
        starOverrides = [:]
        advertisedExtensions = nil
        reconnectTask = nil
        isWaitingForUnlock = false
        stopObservingUnlock()
        box.set(nil)
        ArtworkCache.shared.removeAll()
        stopMatchIndex(erase: true)
        forgetLidarrPermissions()
        lidarrStore.clear()
        lidarr = nil
        lidarrSetup = nil
        lidarrStatus = nil
        rebuildRunner()
        Task {
            await retiring?.stop()
            await doomed?.erase()
        }
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

    /// Nil when `base` answers `/rest/ping` with 2xx and a Subsonic answer (security H2: a router or captive
    /// portal that answers 200 to anything never gets the password); otherwise the error (URLError, HTTP
    /// status, or `unexpectedResponse`).
    func probe(_ base: URL) async -> Error? {
        let url = ServerEndpoint(bases: [base]).url(base, path: "rest/ping", query: [
            URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: "Magpie"),
            URLQueryItem(name: "f", value: "json"),
        ])
        do {
            let (data, response) = try await probeTransport.send(URLRequest(url: url))
            guard (200..<300).contains(response.statusCode) else { return NavidromeError.http(status: response.statusCode) }
            return SubsonicPing.isServerAnswer(data) ? nil : NavidromeError.unexpectedResponse
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

    // MARK: - Match index

    /// Loads the last snapshot for this server and account, then rebuilds the index in the background.
    /// Never blocks the UI; search uses whatever index is complete.
    /// A connection error during the refresh goes through `request`'s failover like any other request.
    private func startMatchIndex() {
        stopMatchIndex(erase: false)
        guard let s = session else { return }
        let url = matchIndexDirectory.map {
            MatchIndexStore.snapshotURL(server: s.endpoint.bases[0].absoluteString, user: s.username, in: $0)
        }
        let store = MatchIndexStore(fileURL: url)
        matchIndex = store
        let fetch = songPages(for: s)
        matchIndexTask = Task {
            await store.loadSnapshot()
            guard !Task.isCancelled else { return }
            do {
                try await store.refresh(fetchPage: fetch)
            } catch {
                Log.logger("matchindex").error("refresh failed: \(Log.category(of: error), privacy: .public)")
            }
        }
    }

    /// `/api/song` pages for this session, through `request`'s failover.
    private func songPages(for s: Session) -> MatchIndexStore.PageFetcher {
        let endpoint = s.endpoint, user = s.username
        return { [weak self] start, end in
            // Never fill this account's index from another session (signed out or in meanwhile).
            guard let self, await self.isSignedIn(to: endpoint, as: user) else { throw CancellationError() }
            return try await self.request { try await $0.songsPage(start: start, end: end) }
        }
    }

    /// Rebuilds the match index now (a request's song may have landed). Shares a refresh already running.
    func refreshMatchIndex() async throws {
        guard let s = session, let store = matchIndex else { return }
        try await store.refresh(fetchPage: songPages(for: s))
    }

    private func isSignedIn(to endpoint: ServerEndpoint, as user: String) -> Bool {
        session?.endpoint == endpoint && session?.username == user
    }

    /// Waits for the current load-and-refresh to finish (tests).
    func matchIndexSettled() async { await matchIndexTask?.value }

    private func stopMatchIndex(erase: Bool) {
        matchIndexTask?.cancel()
        matchIndexTask = nil
        if erase, let store = matchIndex { Task { await store.erase() } }
        matchIndex = nil
    }

    // MARK: - Lidarr

    /// The connected Lidarr's instance (`LidarrClient.instanceScope`: address + API key), if any.
    var lidarrScope: String? { lidarrClient?.instanceScope }

    /// Security M3: the write switch and the setup belong to one Lidarr. Disconnect and sign-out forget both,
    /// so the next Lidarr starts with writes off and is set up afresh.
    func forgetLidarrPermissions() {
        if let scope = lidarrScope {
            gateDefaults.removeObject(forKey: LidarrWriteGate.enabledKey(scope: scope))
            setupStore.clear(scope: scope)
        }
        gateDefaults.removeObject(forKey: LidarrWriteGate.enabledDefaultsKey)   // unscoped switch of older builds
        changesAllowed = false
    }

    /// Owner consent to plain http per address (security H2), kept with the app's settings.
    var plainHTTPConsent: PlainHTTPConsent { PlainHTTPConsent(defaults: appDefaults) }

    /// The owner said yes to sending credentials unencrypted to these addresses.
    func allowPlainHTTP(_ urls: [URL]) { plainHTTPConsent.grant(urls) }

    /// A client for the connected Lidarr, if any.
    var lidarrClient: LidarrClient? {
        lidarr.map { LidarrClient(base: $0.base, apiKey: $0.apiKey, transport: transport) }
    }

    /// Checks the address and key (`/system/status`), reads the setup (audit, no writes) and saves the
    /// connection to the Keychain. Throws `LidarrError.unauthorized` for a wrong key, or the URL error.
    /// A newly connected Lidarr always starts with "Allow Magpie to change Lidarr" off (security M3).
    func connectLidarr(base: URL, apiKey: String) async throws -> LidarrAudit {
        // Security H2: the API key never goes over plain http to a public address without the owner's say-so.
        guard plainHTTPConsent.allows(base) else { throw PlainHTTPConsentRequired(urls: [base]) }
        let connection = LidarrConnection(base: base, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let client = LidarrClient(base: connection.base, apiKey: connection.apiKey, transport: transport)
        _ = try await client.status()
        let audit = await LidarrAudit.run(client)
        try lidarrStore.save(connection)
        if lidarr != nil { forgetLidarrPermissions() }   // the one being replaced
        lidarr = connection
        let scope = client.instanceScope
        gateDefaults.removeObject(forKey: LidarrWriteGate.enabledKey(scope: scope))
        changesAllowed = false
        lidarrStatus = audit
        lidarrSetup = setupStore.load(base: connection.base, scope: scope)
        adoptOnlyRoot(audit)
        rebuildRunner()
        return audit
    }

    /// The connected Lidarr's setup, read again. Nil when not connected.
    func lidarrAudit() async -> LidarrAudit? {
        guard let client = lidarrClient else { return nil }
        let audit = await LidarrAudit.run(client)
        if lidarrClient != nil {
            lidarrStatus = audit
            adoptOnlyRoot(audit)
        }
        return audit
    }

    func disconnectLidarr() {
        forgetLidarrPermissions()
        lidarrStore.clear()
        lidarr = nil
        lidarrSetup = nil
        lidarrStatus = nil
        rebuildRunner()
    }

    // MARK: - Search

    /// Library search merged with ListenBrainz and (when connected) Lidarr. Built per search so it
    /// follows the current session, Lidarr connection and match index.
    func mergedSearch() -> MergedSearch {
        // A9: the token only ever goes to api.listenbrainz.org; the client never sends it to labs.
        var sources: [MergedSearch.Source] = [.listenBrainz(ListenBrainzClient(transport: transport, token: tokenStore.load()))]
        if let lidarr = lidarrClient { sources.append(.lidarr(lidarr)) }
        let index = matchIndex
        return MergedSearch(
            library: { [weak self] q in
                guard let self else { throw NavidromeError.noReachableServer }
                return try await self.request { try await $0.search(q) }
            },
            sources: sources,
            index: { await index?.index ?? .empty })
    }

    /// The one MusicBrainz client (1 request per second across the whole app), made on first use.
    /// Only Try uses it (A8), never search.
    var musicBrainz: MusicBrainzClient {
        if let musicBrainzClient { return musicBrainzClient }
        let client = MusicBrainzClient(transport: transport)
        musicBrainzClient = client
        return client
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

    /// Whether the server advertises the OpenSubsonic extension `name` (e.g. "songLyrics"). Asks once
    /// per session; a failed ask throws and is retried next time.
    func serverAdvertises(_ name: String) async throws -> Bool {
        if let known = advertisedExtensions { return known.contains(name) }
        let found = try await request { try await $0.extensions() }
        advertisedExtensions = found
        return found.contains(name)
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
            Log.logger("session").error("star failed: \(Log.category(of: error), privacy: .public)")
        }
    }
}
