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
    /// T3: a connection to `url` was seen held back by iOS's Local Network setting.
    var localNetworkDenied = false
}

/// App-wide state: the session, the player and the look. Owns no UI, so the CarPlay scene can share
/// `AppModel.shared` with the phone UI.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel.restore()

    private(set) var session: Session?
    let player: Player
    var theme: Theme
    /// Layout, playback, downloads, scrobbling and genres; change it through `updatePreferences`.
    var preferences: Preferences
    @ObservationIgnored let preferencesStore: PreferencesStore
    /// Star changes made this session, by song id (the queue's copies of songs are not edited).
    private(set) var starOverrides: [String: Bool] = [:]
    /// OpenSubsonic extensions the server advertises (A13), fetched once per session.
    private(set) var advertisedExtensions: Set<String>?
    /// A session is saved but the Keychain can't be read yet (before first unlock). Not signed out:
    /// the UI waits, and the session is restored when protected data becomes available.
    private(set) var isWaitingForUnlock = false
    /// T2 fix C1: a saved session none of whose addresses may get the password yet (see AppModel+Consent).
    var savedSessionAwaitingConsent: SavedSessionAwaitingConsent?
    /// Bumped when consent is given, so views that depend on it (Settings › Lidarr) update.
    var plainHTTPConsentRevision = 0
    /// T3: iOS's Local Network permission (asked at first launch by RootView, and before signing in).
    let localNetwork: LocalNetworkAccess
    // The request/settings state below is set from AppModel+Requests.swift (internal setters); views only read it.

    /// The owner's Lidarr, when connected. Kept in the Keychain next to the session.
    private(set) var lidarr: LidarrConnection?
    /// "Allow Magpie to change Lidarr" (G1): mirrors the write gate's persisted switch. Off by default.
    var changesAllowed: Bool
    /// Provisioning results and the main root folder for the connected Lidarr.
    var lidarrSetup: LidarrSetup?
    /// The connected Lidarr's setup as last read (speed tier, root folders). Nil until read.
    var lidarrStatus: LidarrAudit?
    /// Finds mode's setup for this Lidarr and Navidrome account (AppModel+Finds.swift). Nil unless both are connected.
    var findsSetup: FindsSetup? { didSet { syncFindsIdentity() } }
    /// The songs of the Finds library, as last read (`refreshFinds`).
    var findSongs: [Song] = [] { didSet { syncFindsIdentity() } }
    /// Finds let go (Not for me, Task 6.2c) that the Finds library may still list until its scan catches up:
    /// kept off the shelf until a read no longer lists them.
    @ObservationIgnored var lettingGoSongIds: Set<String> = []
    /// Finds already played on this account: they are no longer New finds.
    var playedFinds: Set<String> = []
    /// Try requests, newest last (from the runner).
    var requests: [MagpieRequest] = [] {
        didSet {
            syncRequestFinds()
            forgetEndedStarts()
        }
    }
    /// D6: a find that became ready went next in the queue; the in-app "Play now" banner (AppModel+Landing.swift).
    var playNowBanner: PlayNowBanner?
    /// Wait screens on screen now, per request (a request's screen may be shown twice, e.g. sheet and Requests).
    @ObservationIgnored var waitScreens: [RequestID: Int] = [:]
    /// Requests already landed (D6): each lands once.
    @ObservationIgnored var landedRequests: Set<RequestID> = []
    /// Car Try it next with nothing to play first (final fix 2 B-M7): these start when they land on a still-idle queue.
    @ObservationIgnored var startsWhenLanded: Set<RequestID> = []
    @ObservationIgnored var bannerWatch: Task<Void, Never>?
    /// G8 "Count plays": scrobbling on (default) or off.
    var countPlays: Bool
    /// Whether an optional ListenBrainz token is saved.
    var hasListenBrainzToken = false
    /// Changes whenever the token is saved, replaced or removed: Home's "Made for you" reads again (Task 7.1c).
    var listenBrainzTokenGeneration = 0
    /// Home's "Made for you" shelf for the saved token (AppModel+MadeForYou.swift). Empty without a token.
    var madeForYouShelf: [MadeForYou.Playlist] = []
    /// The scene is active: requests poll every 5 s, otherwise every 30 s.
    var isForeground = true {
        didSet {
            guard isForeground, !oldValue else { return }
            // I3: the Lidarr item may still have been unreadable when the session was restored.
            if session != nil, reloadKeychainItems() { rebuildRunner() }
            pollRequests()
        }
    }

    @ObservationIgnored private let store: any SessionStoring
    @ObservationIgnored private let lidarrStore: any LidarrConnectionStoring
    @ObservationIgnored let tokenStore: any ListenBrainzTokenStoring
    @ObservationIgnored let setupStore: LidarrSetupStore
    @ObservationIgnored let findsStore: FindsSetupStore
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
    /// D29: what the player treats as a find (never scrobbled). Kept in step with `findsSetup` and `findSongs`.
    @ObservationIgnored let findsIdentity = FindsIdentity()
    @ObservationIgnored var findPlaysWatch: Task<Void, Never>?
    /// The Finds library's song ids for the current account and library, as last read or saved
    /// (`findSongIdsKey`); `ids` nil when never read. Keyed so another account or library reloads it.
    @ObservationIgnored var findIdsCache: (key: String, ids: Set<String>?)?
    @ObservationIgnored let notifications: Bool
    /// The library's match index for the signed-in server and account (nil when signed out).
    @ObservationIgnored private(set) var matchIndex: MatchIndexStore?
    @ObservationIgnored private var matchIndexTask: Task<Void, Never>?
    @ObservationIgnored private let matchIndexDirectory: URL?
    @ObservationIgnored private var musicBrainzClient: MusicBrainzClient?
    /// Spaces the app's `api.listenbrainz.org` calls ("Made for you"); labs search never waits on it.
    @ObservationIgnored let listenBrainzLimiter = RateLimiter(perSecond: 2)
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?
    @ObservationIgnored let transport: HTTPTransport
    @ObservationIgnored private let probeTransport: HTTPTransport
    @ObservationIgnored private let box: ClientBox
    @ObservationIgnored private var reconnectTask: Task<Bool, Never>?
    @ObservationIgnored private var reconnectGeneration = 0
    /// Bumped by sign-in, a resumed session and sign-out: a sign-out's late clean-up only runs while it is unchanged.
    @ObservationIgnored private var sessionGeneration = 0
    /// This build's ATS allows plain http anywhere (every build since T2; the consent gate is the control). False:
    /// a build without arbitrary loads, where `atsBlocksPlainHTTP` pre-refuses.
    @ObservationIgnored var atsAllowsArbitraryLoads = AppModel.bundleAllowsArbitraryLoads()
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
         notifications: Bool = true,
         localNetworkProber: (any LocalNetworkProbing)? = nil) {
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
        let preferencesStore = PreferencesStore(defaults: defaults)
        self.preferencesStore = preferencesStore
        self.preferences = preferencesStore.load()
        self.notifications = notifications
        let data = dataDirectory ?? FileManager.default.temporaryDirectory.appending(path: "magpie-\(UUID().uuidString)")
        self.dataDirectory = data
        self.gateDefaultsSuite = gateDefaultsSuite
        self.gateDefaults = gateDefaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.changesAllowed = false
        self.appDefaults = defaults
        // Hosted tests never meet the system prompt (C-I1's environment check).
        let prober = localNetworkProber ?? (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                                            ? NWBrowserLocalNetworkProber() : NotNeededProber())
        self.localNetwork = LocalNetworkAccess(prober: prober, defaults: defaults)
        self.setupStore = LidarrSetupStore(defaults: defaults)
        self.findsStore = FindsSetupStore(defaults: defaults)
        self.countPlays = defaults.object(forKey: Self.countPlaysKey) as? Bool ?? true
        self.hasListenBrainzToken = tokenStore.load() != nil
        let counting = PlayCounting(on: defaults.object(forKey: Self.countPlaysKey) as? Bool ?? true)
        self.playCounting = counting
        let findsIdentity = self.findsIdentity
        self.player = Player(engine: engine ?? AVQueueEngine(),
                             scrobbler: NavidromeScrobbler(box: box, counting: counting),
                             urls: NavidromeStreamURLs(box: box),
                             isFind: { findsIdentity.isFind($0) })
        #if os(iOS)
        if systemNowPlaying {
            nowPlaying = NowPlayingBridge(
                player: player,
                artworkURL: { [weak self] song in self?.coverArtURL(song.coverArtId, size: 600) },
                onLike: { [weak self] song in Task { await self?.toggleStar(song) } },
                isLiked: { [weak self] song in self?.isStarred(song) ?? song.starred })
        }
        #endif
        watchPlaybackErrors()
        watchFindPlays()
        watchBanner()
        readLidarrPermissions()
    }

    /// The write switch and setup of the connected Lidarr (both are kept per instance).
    private func readLidarrPermissions() {
        if let scope = lidarrScope, let lidarr {
            changesAllowed = gateDefaults.bool(forKey: LidarrWriteGate.enabledKey(scope: scope))
            lidarrSetup = setupStore.load(base: lidarr.base, scope: scope)
        }
    }

    /// Final review I3: a launch before first unlock (CarPlay cold start, prewarming) reads the Lidarr connection
    /// and the ListenBrainz token as absent. Reads them again; true when Lidarr turned up (the runner needs rebuilding).
    @discardableResult
    func reloadKeychainItems() -> Bool {
        let hasToken = tokenStore.load() != nil
        if hasToken != hasListenBrainzToken {   // no needless view updates
            hasListenBrainzToken = hasToken
            listenBrainzTokenChanged()
        }
        guard lidarr == nil, let saved = lidarrStore.load() else { return false }
        lidarr = saved
        readLidarrPermissions()
        return true
    }

    /// Builds the shared model from what the Keychain holds. `-MagpieResetState YES` signs out first
    /// (UI tests). `-MagpieCharacter classic|signature|immersive` picks the look.
    ///
    /// Final fix 2 C-I1 (G0): as the host of hosted unit tests (`XCTestConfigurationFilePath` set) it resumes no
    /// saved session and builds no runner, so tests never talk to whatever server the simulator is signed in to.
    /// A test opts in with `MAGPIE_TEST_HOST_RESTORE=1`.
    static func restore(store: any SessionStoring = SessionStore.standard, defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> AppModel {
        if defaults.bool(forKey: "MagpieResetState") {
            store.clear()
            LidarrConnectionStore.standard.clear()
        }
        let model = AppModel(store: store, defaults: defaults, theme: savedTheme(defaults))
        if resumesSavedSession(environment: environment) { model.resumeSavedSession() }
        return model
    }

    /// False while the app is a unit-test host, unless the test opted in (C-I1).
    nonisolated static func resumesSavedSession(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil || environment["MAGPIE_TEST_HOST_RESTORE"] == "1"
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
        // T2 fix C1: a saved address may predate consent (build 1, a reinstall); none usable → ask, send nothing.
        guard let made = makeClient(saved.endpoint, saved.credentials) else { return awaitConsent(for: saved) }
        savedSessionAwaitingConsent = nil
        sessionGeneration += 1
        let client = made.client
        session = Session(client: client, endpoint: saved.endpoint, credentials: saved.credentials,
                          activeBase: made.first, isAdmin: false)
        box.set(client)
        // O3: started now, so every call made meanwhile waits for it (`request`): one login per launch.
        startReconnect(rebuildAlways: true)
        startMatchIndex()
        reloadKeychainItems()
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
        // H4: when ATS would refuse every address, say so before anything is tried.
        let blocked = urls.filter(atsBlocks)
        guard blocked.count < urls.count else {
            throw SignInError.unreachable(blocked.map { ProbeFailure(url: $0, error: Self.atsError($0)) })
        }
        // Security H2: the password never goes over plain http to a public address without the owner's say-so.
        // Every address is checked (T2 fix C1): all of them are saved, and a later build may reach them.
        let unencrypted = urls.filter { !plainHTTPConsent.allows($0) }
        guard unencrypted.isEmpty else { throw PlainHTTPConsentRequired(urls: unencrypted) }
        let endpoint = ServerEndpoint(bases: urls)
        // T3: the Local Network prompt (if not answered yet) comes before the first request to a home address.
        _ = await localNetwork.ensureAccess(for: urls)
        var failures: [ProbeFailure] = []
        var reached: URL?
        for base in urls {
            if atsBlocks(base) {
                failures.append(ProbeFailure(url: base, error: Self.atsError(base)))
            } else if let error = await probe(base) {
                var failure = ProbeFailure(url: base, error: error)
                if ServerAddress.needsLocalNetworkPermission(base), Self.isConnectionError(error) {
                    failure.localNetworkDenied = await localNetwork.checkDenied(for: base)
                }
                failures.append(failure)
            } else {
                reached = base
                break
            }
        }
        guard let base = reached else { throw SignInError.unreachable(failures) }
        let credentials = NavidromeCredentials(username: username, password: password)
        guard let client = makeClient(Self.preferring(base, in: endpoint), credentials)?.client else {
            throw PlainHTTPConsentRequired(urls: urls.filter { !plainHTTPConsent.allows($0) })
        }
        let login = try await client.connect()
        try store.save(endpoint: endpoint, credentials: credentials)
        savedSessionAwaitingConsent = nil
        reconnectTask = nil
        sessionGeneration += 1
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

    /// Stops playback, forgets the server and clears the Keychain, recent searches, every Lidarr's requests and the
    /// ledgers with nothing open (`Ledger.forgetFinished`). Keeps the change log.
    func signOut() {
        let retiring = runner, doomed = requestStore
        player.play([], startAt: 0)
        if let navidromeScope {
            findsStore.clear(navidromeScope: navidromeScope)
            appDefaults.removeObject(forKey: Self.playedFindsKey(navidromeScope))
            appDefaults.removeObject(forKey: Self.findsLibraryKey(navidromeScope))
            let prefix = Self.findSongIdsKeyPrefix + navidromeScope + "."
            for key in appDefaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                appDefaults.removeObject(forKey: key)
            }
        }
        startsWhenLanded = []
        findIdsCache = nil
        findsIdentity.forgetAccount()
        findSongs = []
        lettingGoSongIds = []
        playedFinds = []
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
        RecentSearches(defaults: appDefaults).clear()   // shared with the car
        // Every Lidarr's requests, and the ledgers with nothing open, now. Never the change log (the owner's undo map).
        let data = dataDirectory
        RequestStore.eraseAll(in: data)
        Ledger.forgetFinished(in: data)
        // Again once the old runner has stopped (a save under way may have rewritten its file), unless a newer
        // session has started meanwhile: its files are never touched.
        sessionGeneration += 1
        let generation = sessionGeneration
        Task { [weak self] in
            await retiring?.stop()
            guard let self, self.sessionGeneration == generation else { return }
            await doomed?.erase()
            guard self.sessionGeneration == generation else { return }
            RequestStore.eraseAll(in: data)
            Ledger.forgetFinished(in: data)
        }
    }

    // MARK: - Requests with failover

    /// Runs `op` against the current client. On a connection error, re-probes the addresses, moves
    /// to the first that answers (rebuilding the client and the player's stream URLs) and retries once.
    func request<T: Sendable>(_ op: @Sendable (NavidromeClient) async throws -> T) async throws -> T {
        // A reconnect under way (a resumed launch, a failover) is about to replace the client: use its result, so
        // the client it retires never logs in on its own (O3).
        if let pending = reconnectTask { _ = await pending.value }
        guard let client = session?.client else { throw NavidromeError.noReachableServer }
        do {
            return try noteLocalSuccess(await op(client))
        } catch where Self.isConnectionError(error) {
            guard await reconnect(rebuildAlways: false), let retry = session?.client else { throw error }
            return try noteLocalSuccess(await op(retry))
        }
    }

    /// T3: a request to a home address worked, so the Local Network setting is on (fix M1: only an IP literal or a
    /// `.local` name proves it; a single-label name may have gone over Tailscale).
    private func noteLocalSuccess<T>(_ value: T) -> T {
        if let base = session?.activeBase, ServerAddress.provesLocalNetworkAccess(base) { localNetwork.noteLocalSuccess() }
        return value
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
        await startReconnect(rebuildAlways: rebuildAlways).value
    }

    /// The reconnect under way, or a new one; `reconnectTask` is set before this returns.
    @discardableResult
    private func startReconnect(rebuildAlways: Bool) -> Task<Bool, Never> {
        if let task = reconnectTask { return task }
        reconnectGeneration += 1
        let generation = reconnectGeneration
        // Main-actor isolated: it starts after `reconnectTask` is set, and clears it before anyone sees the result.
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let ok = await self.performReconnect(rebuildAlways: rebuildAlways)
            if self.reconnectGeneration == generation { self.reconnectTask = nil }
            return ok
        }
        reconnectTask = task
        return task
    }

    private func performReconnect(rebuildAlways: Bool) async -> Bool {
        guard let old = session else { return false }
        var reached: URL?
        for base in sendableBases(old.endpoint) where await probe(base) == nil {   // T2 fix C1
            reached = base
            break
        }
        guard let base = reached else { return false }
        if base == old.activeBase, !rebuildAlways { return true }   // a blip; the same address answers again
        guard let client = makeClient(Self.preferring(base, in: old.endpoint), old.credentials)?.client,
              let login = try? await client.connect() else { return false }
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

    /// T2 fix C1: the client only ever knows the addresses credentials may go to, so its login, failover, stream
    /// and artwork URLs can't reach any other. Nil when none remains; otherwise the client and its first address.
    private func makeClient(_ endpoint: ServerEndpoint, _ credentials: NavidromeCredentials) -> (client: NavidromeClient, first: URL)? {
        let bases = sendableBases(endpoint)
        guard let first = bases.first else { return nil }
        return (NavidromeClient(endpoint: ServerEndpoint(bases: bases), credentials: credentials, transport: transport), first)
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
    /// Read from the saved connection, not `lidarrClient`: nothing is sent, and it stays known while consent is pending.
    var lidarrScope: String? { lidarr.map { LidarrClient(base: $0.base, apiKey: $0.apiKey, transport: transport).instanceScope } }

    /// Security M3: the write switch and the setup belong to one Lidarr. Disconnect and sign-out forget both,
    /// so the next Lidarr starts with writes off and is set up afresh.
    func forgetLidarrPermissions() {
        if let scope = lidarrScope {
            gateDefaults.removeObject(forKey: LidarrWriteGate.enabledKey(scope: scope))
            setupStore.clear(scope: scope)
            findsStore.clear(lidarrScope: scope)
        }
        findsSetup = nil
        gateDefaults.removeObject(forKey: LidarrWriteGate.enabledDefaultsKey)   // unscoped switch of older builds
        changesAllowed = false
    }

    /// H4: this build's App Transport Security would refuse plain http to `url`.
    func atsBlocks(_ url: URL) -> Bool {
        ServerAddress.atsBlocksPlainHTTP(url, allowsArbitraryLoads: atsAllowsArbitraryLoads)
    }

    nonisolated static func atsError(_ url: URL) -> URLError {
        URLError(.appTransportSecurityRequiresSecureConnection, userInfo: [NSURLErrorFailingURLErrorKey: url])
    }

    /// Whether the app's Info.plist allows arbitrary loads with nothing that makes iOS ignore it (every build, T2).
    nonisolated static func bundleAllowsArbitraryLoads(_ bundle: Bundle = .main) -> Bool {
        allowsArbitraryLoads(ats: bundle.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
    }

    /// B2: an ATS dictionary allows plain http anywhere only with arbitrary loads and none of the keys that make
    /// iOS ignore it (local networking, web content, media).
    nonisolated static func allowsArbitraryLoads(ats: [String: Any]?) -> Bool {
        guard let ats else { return false }
        return ats["NSAllowsArbitraryLoads"] as? Bool == true && ats["NSAllowsLocalNetworking"] == nil
            && ats["NSAllowsArbitraryLoadsInWebContent"] == nil && ats["NSAllowsArbitraryLoadsForMedia"] == nil
    }

    /// Owner consent to plain http per address (security H2), kept with the app's settings.
    var plainHTTPConsent: PlainHTTPConsent { PlainHTTPConsent(defaults: appDefaults) }

    /// The owner said yes to sending credentials unencrypted to these addresses.
    func allowPlainHTTP(_ urls: [URL]) {
        plainHTTPConsent.grant(urls)
        plainHTTPConsentRevision += 1
    }

    /// A client for the connected Lidarr, if any. T2 fix round 2: nil while its address is plain http to a public
    /// host without consent (a reinstall), so no path can send the API key there (`lidarrAwaitingConsent`).
    var lidarrClient: LidarrClient? {
        guard let lidarr, plainHTTPConsent.allows(lidarr.base) else { return nil }
        return LidarrClient(base: lidarr.base, apiKey: lidarr.apiKey, transport: transport)
    }

    /// Checks the address and key (`/system/status`), reads the setup (audit, no writes) and saves the
    /// connection to the Keychain. Throws `LidarrError.unauthorized` for a wrong key, or the URL error.
    /// A newly connected Lidarr always starts with "Allow Magpie to change Lidarr" off (security M3).
    func connectLidarr(base: URL, apiKey: String) async throws -> LidarrAudit {
        if atsBlocks(base) { throw Self.atsError(base) }   // H4: named before trying
        // Security H2: the API key never goes over plain http to a public address without the owner's say-so.
        guard plainHTTPConsent.allows(base) else { throw PlainHTTPConsentRequired(urls: [base]) }
        let connection = LidarrConnection(base: base, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let client = LidarrClient(base: connection.base, apiKey: connection.apiKey, transport: transport)
        _ = try await client.status()
        let audit = await LidarrAudit.run(client)
        // A-M4: the audit read `client`, and `connection` is what is saved and adopted into below (the ids belong to it).
        try lidarrStore.save(connection)
        if lidarr != nil { forgetLidarrPermissions() }   // the one being replaced
        lidarr = connection
        let scope = client.instanceScope
        gateDefaults.removeObject(forKey: LidarrWriteGate.enabledKey(scope: scope))
        changesAllowed = false
        lidarrStatus = audit
        lidarrSetup = setupStore.load(base: connection.base, scope: scope)
        adoptOnlyRoot(audit)
        adoptFindTag(audit)
        adoptLosslessProfile(audit)
        rebuildRunner()
        return audit
    }

    /// The connected Lidarr's setup, read again. Nil when not connected.
    func lidarrAudit() async -> LidarrAudit? {
        guard let client = lidarrClient else { return nil }
        let scope = lidarrScope
        let audit = await LidarrAudit.run(client)
        // Final fix 2 A-M4: only into the Lidarr it read. Another one connected (or none) meanwhile: adopt nothing.
        if lidarrClient != nil, lidarrScope == scope {
            lidarrStatus = audit
            adoptOnlyRoot(audit)
            adoptFindTag(audit)
            adoptLosslessProfile(audit)
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
    /// - Parameters:
    ///   - libraryTimeout: the library search's deadline (CarPlay passes a longer one).
    ///   - sourceTimeout: each outside source's deadline (CarPlay passes a shorter one).
    func mergedSearch(libraryTimeout: Duration = MergedSearch.libraryTimeout,
                      sourceTimeout: Duration = MergedSearch.sourceTimeout) -> MergedSearch {
        // A9: the token only ever goes to api.listenbrainz.org; the client never sends it to labs.
        var sources: [MergedSearch.Source] = [.listenBrainz(ListenBrainzClient(transport: transport, token: tokenStore.load()),
                                                            timeout: sourceTimeout)]
        if let lidarr = lidarrClient { sources.append(.lidarr(lidarr, timeout: sourceTimeout)) }
        let index = matchIndex
        return MergedSearch(
            library: { [weak self] q in
                guard let self else { throw NavidromeError.noReachableServer }
                return try await self.request { try await $0.search(q) }
            },
            libraryTimeout: libraryTimeout,
            sources: sources,
            index: { await index?.index ?? .empty })
    }

    /// The one MusicBrainz client (1 request per second across the whole app), made on first use.
    /// Only Try uses it (A8), never search.
    var musicBrainz: MusicBrainzClient {
        if let musicBrainzClient { return musicBrainzClient }
        let client = MusicBrainzClient(transport: transport, userAgent: MusicBrainzClient.userAgent(version: Self.marketingVersion))
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
