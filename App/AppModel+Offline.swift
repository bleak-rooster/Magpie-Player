import Foundation
import MagpieCore
import NavidromeKit
import Observation
import os
import Playback
#if os(iOS)
import UIKit
#endif

/// Whether the app is offline, readable from any context: the stream URLs and the scrobble router ask on every use.
/// Written on the main actor when offline mode is applied.
final class OfflineBox: Sendable {
    private let lock: OSAllocatedUnfairLock<Bool>
    init(_ offline: Bool = false) { lock = OSAllocatedUnfairLock(initialState: offline) }
    var isOffline: Bool { lock.withLock { $0 } }
    func set(_ offline: Bool) { lock.withLock { $0 = offline } }
}

/// Round 28 O1 (owner, 2026-11-15): what the screens say about offline (D329, D330). `isOffline` keeps its meaning
/// (`.automatic` or `.manual`).
enum OfflineState: Equatable {
    case online
    /// A try went unanswered; Magpie is checking (nothing changes on screen).
    case suspect
    /// The library is out of reach: Magpie went offline by itself.
    case automatic
    /// Offline mode is on (the owner's switch).
    case manual
}

/// The bookkeeping behind offline mode (one object, so `AppModel` holds a single property for it). Round 28 O1
/// (owner, 2026-11-15): the reachability machine (D324–D326) replaces the failure count and the 10 s rule, and runs on
/// an injectable clock; the notice and Settings observe it.
@MainActor @Observable final class ReachabilityState {
    /// Offline, and forced On, as last applied to playback and downloads.
    @ObservationIgnored var appliedOffline = false
    @ObservationIgnored var appliedForced = false
    /// Round 28 O1 (D324): the machine. Only `AppModel.reachabilityEvent` changes it.
    var machine = ReachabilityMachine()
    /// A reconnect check the machine asked for (or Try again) is running: the notice says "Trying…" (D329).
    var checking = false
    /// Round 28 O1 (D323): Go offline automatically as remembered while Offline mode is on (unset reads as on).
    var automaticChoice = true
    /// Seconds, on this clock, for the machine and its timer. Tests set a clock they move by hand
    /// (`AppModel.useReachabilityClock`).
    @ObservationIgnored var clock: any ReachabilityClock = ContinuousReachabilityClock()
    /// The one wake the machine asked for (`nextWake`); re-armed after every event.
    @ObservationIgnored var timer: Task<Void, Never>?
    /// The probe the machine asked for, while it runs.
    @ObservationIgnored var probeTask: Task<Void, Never>?
    /// Watches the network path and Low Power Mode (D326).
    @ObservationIgnored var inputsWatch: Task<Void, Never>?
    @ObservationIgnored var lastInputs: ReachabilityInputs?
    /// `offlineInputsChanged` is bringing the machine in line with the preference (its own effects don't re-enter).
    @ObservationIgnored var syncing = false
    /// Set once `init` is done: from then on each switch to or from offline is announced to VoiceOver (D329).
    @ObservationIgnored var started = false
    @ObservationIgnored var announce: @MainActor (String) -> Void = ReachabilityState.postAnnouncement
    /// Failed reconnects (each probes every address) since the server last answered.
    @ObservationIgnored var failures = 0
    /// The last reconnect's login was refused (401/403): the server answers, the password doesn't work.
    @ObservationIgnored var authRejected = false
    /// When the library last answered (a probe or an authenticated request), on `clock`.
    @ObservationIgnored var lastAnswerAt: Double?
    /// When a failed download, or a failed stream, last asked for a probe (fix round 3; D325): at most one each per
    /// `probeRequestSpacing`.
    @ObservationIgnored var lastDownloadProbe: Double?
    @ObservationIgnored var lastStreamProbe: Double?
    nonisolated static let probeRequestSpacing: Double = 5

    var isSuspect: Bool { machine.isSuspect }
    /// A wake (probe or 30 s mark) is set.
    var hasScheduledWake: Bool { timer != nil }

    static func postAnnouncement(_ text: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }
}

/// What the machine watches besides the library's answers: the network path and Low Power Mode.
struct ReachabilityInputs: Equatable, Sendable {
    var status: NetworkStatus
    var lowPower: Bool
}

/// Offline mode (spec §6, Task 14). Automatic follows whether the server answers; On forces it; Off never goes
/// offline. While offline only songs on the phone play (downloads and cache), nothing is fetched, no original is
/// tried, files that fail are kept, Lidarr waits, and the screens show what's on the phone. Forced On sends nothing
/// at all: no request, stream, artwork, scrobble or probe.
///
/// Round 28 O1 (owner, 2026-11-15): Automatic goes offline when the library hasn't answered for 30 s (D324), or at
/// once with no network path (Q1); while suspect nothing is skipped and a song that failed plays again when the server
/// answers. Reconnect checks run only while suspect or automatically offline (D326). Every send goes through
/// `offlineGate` (D328).
extension AppModel {
    nonisolated static let offlineCopy = "You're offline"
    /// The error `request` throws while Offline mode is On: a connection error, so callers treat it as unreachable.
    nonisolated static let forcedOfflineError = URLError(.notConnectedToInternet)
    /// Round 28 O1 (D323): Go offline automatically, remembered while Offline mode is on (its own key; unset is on).
    nonisolated static let automaticChoiceKey = "magpie.offline.automaticChoice"

    var isOffline: Bool {
        switch preferences.downloads.offlineMode {
        case .on: true
        case .off: false
        case .automatic: !serverReachable
        }
    }

    /// Offline mode is On: nothing goes to the network.
    var isForcedOffline: Bool { preferences.downloads.offlineMode == .on }

    /// `request`'s gate: Offline mode On makes no request.
    func requireNotForcedOffline() throws {
        if isForcedOffline { throw Self.forcedOfflineError }
    }

    // MARK: - Round 28 O1: state for others (D330)

    /// Online, checking, offline by itself, or Offline mode on.
    var offlineState: OfflineState {
        if isForcedOffline { return .manual }
        if isOffline { return .automatic }
        return reachability.machine.isDown ? .suspect : .online
    }

    /// The notice's Go online: Offline mode off (D329).
    func goOnline() { setOfflineMode(on: false) }

    /// Try again and pull to refresh (D326): a reconnect check now, waited for. Nothing in manual offline.
    func reconnectNow() async { await checkReachability() }

    /// `request`'s second gate (D328): automatically offline, a request fails at once like a connection error; the
    /// machine's own checks (and Try again) bring Magpie back, not each screen's request.
    func requireNotAutomaticallyOffline() throws {
        if !isForcedOffline, isOffline { throw Self.forcedOfflineError }
    }

    /// D325: a 502, 503 or 504 (a proxy whose server has stopped), 511 or any other non-Subsonic answer (a captive
    /// portal or a proxy's sign-in page: `unexpectedResponse`), or a redirect `SameOriginRedirects` refused (the 3xx
    /// itself comes back, which the client surfaces as `NavidromeError.http(status: 3xx)`): the library didn't answer.
    nonisolated static func isServerPathFailure(_ error: Error) -> Bool {
        switch error as? NavidromeError {
        case .unexpectedResponse?: true
        case .http(let status)?: [502, 503, 504, 511].contains(status) || (300..<400).contains(status)
        default: false
        }
    }

    /// D325: an answer from the library itself: a Subsonic error, JSON Magpie can't read, a refused sign-in, or any
    /// other HTTP status that isn't a server-path failure.
    nonisolated static func isLibraryAnswer(_ error: Error) -> Bool {
        switch error as? NavidromeError {
        case .api?, .unexpectedData?, .badCredentials?: true
        case .http?: !isServerPathFailure(error)
        default: false
        }
    }

    /// An authenticated answer came back (D325): the library answers. While suspect that ends it (a login worked, so
    /// D46's "a ping isn't enough" holds).
    func noteLibraryAnswered<T>(_ value: T) -> T {
        reachability.lastAnswerAt = reachability.clock.now()
        if reachability.machine.isDown, session != nil { noteReachable() }
        return value
    }

    /// `request` failed with something the library said: an answer all the same.
    func noteLibraryAnswer(in error: Error) {
        if Self.isLibraryAnswer(error) { _ = noteLibraryAnswered(()) }
    }

    // MARK: - Round 28 O1: the switch (D323)

    /// Offline mode on: `.on`, remembering whether Go offline automatically was on; off: `.automatic` or `.off` by
    /// that remembered choice. Nothing in `Preferences` changes shape.
    func setOfflineMode(on: Bool) {
        let mode = preferences.downloads.offlineMode
        if on {
            guard mode != .on else { return }
            rememberAutomaticChoice(mode == .automatic)
            updatePreferences { $0.downloads.offlineMode = .on }
        } else {
            guard mode == .on else { return }
            let automatic = reachability.automaticChoice
            updatePreferences { $0.downloads.offlineMode = automatic ? .automatic : .off }
        }
    }

    /// Go offline automatically: with Offline mode on only the remembered choice changes.
    func setGoOfflineAutomatically(_ on: Bool) {
        rememberAutomaticChoice(on)
        guard preferences.downloads.offlineMode != .on else { return offlineInputsChanged() }
        updatePreferences { $0.downloads.offlineMode = on ? .automatic : .off }
    }

    /// The switch's state: Offline mode on.
    var offlineModeOn: Bool { isForcedOffline }

    /// The second switch's state: the remembered choice while Offline mode is on, else the mode itself (an existing
    /// `.off` reads as off, `.on` as on with automatic on).
    var goesOfflineAutomatically: Bool {
        switch preferences.downloads.offlineMode {
        case .on: reachability.automaticChoice
        case .automatic: true
        case .off: false
        }
    }

    private func rememberAutomaticChoice(_ on: Bool) {
        reachability.automaticChoice = on
        appDefaults.set(on, forKey: Self.automaticChoiceKey)
    }

    // MARK: - Round 28 O1: the machine (D324–D327)

    /// Called once from `init`, after the preference is applied: the remembered choice, the network and Low Power Mode,
    /// and from now on VoiceOver hears each switch.
    func startReachability() {
        let r = reachability
        r.automaticChoice = appDefaults.object(forKey: Self.automaticChoiceKey) as? Bool ?? true
        offlineInputsChanged()
        let network = self.network
        reachabilityInputsChanged(ReachabilityInputs(status: network.status, lowPower: network.isLowPowerMode))
        r.inputsWatch = Task { [weak self] in
            let inputs = Observations { @MainActor in ReachabilityInputs(status: network.status, lowPower: network.isLowPowerMode) }
            for await input in inputs {
                guard let self else { return }
                self.reachabilityInputsChanged(input)
            }
        }
        r.started = true
    }

    /// Tests: runs the machine on `clock` from now on (the path is read again, so its times are on the new clock).
    func useReachabilityClock(_ clock: any ReachabilityClock) {
        let r = reachability
        r.clock = clock
        r.lastAnswerAt = nil
        let connected = network.status.isConnected
        if !connected { reachabilityEvent(.pathChanged(connected: true)) }
        reachabilityEvent(.pathChanged(connected: connected))
    }

    /// The path came back or changed interface, it went away, or Low Power Mode changed (D326, Q1).
    private func reachabilityInputsChanged(_ input: ReachabilityInputs) {
        let r = reachability
        let last = r.lastInputs
        r.lastInputs = input
        if last?.lowPower != input.lowPower { reachabilityEvent(.lowPower(input.lowPower)) }
        let pathChanged = last.map {
            $0.status.isConnected != input.status.isConnected || $0.status.isCellular != input.status.isCellular
        } ?? true
        if pathChanged { reachabilityEvent(.pathChanged(connected: input.status.isConnected)) }
    }

    /// Feeds one event to the machine and does what it says; the timer then follows the machine's next wake.
    func reachabilityEvent(_ event: ReachabilityMachine.Event) {
        let r = reachability
        let now = r.clock.now()
        var effects: [ReachabilityMachine.Effect] = []
        let signedIn = session != nil
        if signedIn != r.machine.hasSession { effects += r.machine.handle(signedIn ? .signedIn : .signedOut, now: now) }
        effects += r.machine.handle(event, now: now)
        for effect in effects {
            switch effect {
            case .goOffline: if serverReachable { serverReachable = false }
            case .goOnline: if !serverReachable { serverReachable = true }
            case .probeNow: startMachineProbe()
            case .cancelProbes, .scheduleProbe, .scheduleTick: break   // the timer below follows `nextWake`
            }
        }
        armReachabilityTimer()
    }

    private func armReachabilityTimer() {
        let r = reachability
        r.timer?.cancel()
        guard let wake = r.machine.nextWake else { r.timer = nil; return }
        let clock = r.clock
        r.timer = Task { [weak self] in
            do { try await clock.sleep(until: wake) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.reachabilityEvent(.tick)
        }
    }

    /// The machine's probe: today's reconnect (every address, `rest/ping` without credentials, 6 s each, then a login
    /// on the one that answered), one at a time. Online (coming to the front) it is a ping, with a login only on another
    /// address. Its verdict reaches the machine through `noteReachable` / `reconnectFailed`; its end, always, here.
    private func startMachineProbe() {
        let r = reachability
        r.checking = true
        let ping = r.machine.state == .online
        let gate = offlineGate
        r.probeTask = Task { [weak self] in
            gate.beginReconnect()   // automatic offline lets this reconnect's login out (D328)
            await self?.reconnect(rebuildAlways: !ping)
            gate.endReconnect()
            guard let self else { return }
            self.reachability.checking = false
            self.reachability.probeTask = nil
            self.reachabilityEvent(.probeFinished)
        }
    }

    /// Coming to the front (D326): the window restarts while suspect; offline it probes; online it pings when the
    /// library hasn't answered for a minute. Nothing in manual offline or without a session.
    func reachabilitySceneChanged(active: Bool) {
        guard active, session != nil, !isForcedOffline else { return }
        reachabilityEvent(.becameActive(lastAnswer: reachability.lastAnswerAt))
    }

    // MARK: - Reachability

    /// A reconnect probed every address and none answered: one more failure towards going offline.
    func reconnectFailed() {
        guard !isForcedOffline else { return }
        reachability.failures += 1
        reachability.authRejected = false   // a real outage now: "isn't answering", not the sign-in error
        downloads?.serverDropConfirmed()
        noteUnreachable()
    }

    /// The server didn't answer (D325): suspect, and probed on the D326 schedule until it answers; Automatic goes
    /// offline 30 s after the first unanswered try (D324).
    func noteUnreachable() {
        guard session != nil, !isForcedOffline else { return }
        let wasDown = reachability.machine.isDown
        reachabilityEvent(.failure)
        if !wasDown { downloads?.networkChanged() }   // manual downloads wait for the server from now
    }

    /// The server answered (or there is no session to reach): back online, the probes stop, and what waited on it
    /// goes again: a song that failed while it was suspect, and downloads.
    func noteReachable() {
        let r = reachability
        let wasDown = r.machine.isDown || !serverReachable
        r.failures = 0
        r.authRejected = false
        r.lastAnswerAt = session == nil ? nil : r.clock.now()
        reachabilityEvent(session == nil ? .signedOut : .answered)
        if !serverReachable { serverReachable = true }
        // Downloads that failed meanwhile count as attempts, and the rest go again.
        if wasDown || downloads?.hasAwaitingVerdict == true { downloads?.serverAnswered() }
        guard wasDown else { return }
        serverAnsweredGeneration += 1   // P5: Home reads what failed
        player.retryAfterFailure()
        drainScrobblesSoon()   // plays queued while it was down (T17)
    }

    /// A reconnect's login (fix round 2, B). A refusal (401/403) means the server answered: it is reachable, and
    /// `request` throws the sign-in error instead of going offline. Any other failure counts as a failed reconnect.
    func reconnectLogin(_ client: NavidromeClient, replacing old: NavidromeClient) async -> LoginResult? {
        do {
            let login = try await client.connect()
            reachability.authRejected = false
            return login
        } catch {
            guard session?.client === old else { return nil }   // signed out or in meanwhile
            if Self.isAuthRejection(error) {
                noteReachable()
                reachability.authRejected = true
            } else {
                reconnectFailed()
            }
            return nil
        }
    }

    nonisolated static func isAuthRejection(_ error: Error) -> Bool {
        switch error as? NavidromeError {
        case .badCredentials?: true
        case .http(let status)?: status == 401 || status == 403
        default: false
        }
    }

    /// `request` after a failed reconnect whose login was refused: the sign-in error, not the connection one.
    func rethrowAuthRejection() throws {
        if reachability.authRejected { throw NavidromeError.badCredentials }
    }

    /// A download couldn't connect (fix round 3): probe the server, at most once per 5 s and without logging in again
    /// while the session works. A failure inside that window marks the server suspect and waits for that probe's
    /// verdict, or the machine's.
    func downloadCouldNotConnect() {
        guard session != nil, !isForcedOffline else { return }
        let r = reachability
        let now = r.clock.now()
        if let last = r.lastDownloadProbe, now - last < ReachabilityState.probeRequestSpacing {
            noteUnreachable()
            return
        }
        r.lastDownloadProbe = now
        if r.machine.isDown { return reachabilityEvent(.probeRequested) }
        Task { [weak self] in await self?.reconnect(rebuildAlways: false) }
    }

    /// Round 28 O1 (D325): the current song failed to stream. Online, check whether another address answers (as
    /// before); suspect or offline, ask the machine for a probe. At most one each 5 s.
    func streamCouldNotConnect() async {
        guard session != nil, !isForcedOffline else { return }
        let r = reachability
        let now = r.clock.now()
        if let last = r.lastStreamProbe, now - last < ReachabilityState.probeRequestSpacing { return }
        r.lastStreamProbe = now
        guard r.machine.isDown else { return _ = await reconnect(rebuildAlways: false) }
        reachabilityEvent(.probeRequested)
        await r.probeTask?.value
    }

    /// Pull to refresh and Try again (D326): probes the session's addresses now. While suspect or offline it is the
    /// machine's probe (one at a time); online, a reconnect as before. One that answers is moved to and logged in to
    /// afresh (a launch with no network never logged in, and stream URLs need it), which marks the server reachable.
    /// Nothing while forced On.
    func checkReachability() async {
        guard session != nil, !isForcedOffline else { return }
        reachabilityEvent(.probeRequested)
        if let probe = reachability.probeTask { return await probe.value }
        let gate = offlineGate
        gate.beginReconnect()
        await reconnect(rebuildAlways: true)
        gate.endReconnect()
    }

    // MARK: - Applying offline mode

    /// Applies `isOffline` when it changed. Each of its inputs calls this (the reachability, the preference), so
    /// playback is right before anything else runs: offline only songs on the phone play, online every song does.
    func offlineInputsChanged() {
        let r = reachability
        guard !r.syncing else { return }   // the machine's own effects, while it is brought in line below
        r.syncing = true
        syncReachabilityMode()
        r.syncing = false
        let offline = isOffline, forced = isForcedOffline
        offlineGate.setMode(forced ? .manual : offline ? .automatic : .open)   // Round 28 O1 (D328)
        let leftForced = r.appliedForced && !forced
        r.appliedForced = forced
        guard offline != r.appliedOffline else {
            if leftForced { restoreAfterOffline(reconnecting: true) }   // On to Off with the server reachable
            return
        }
        r.appliedOffline = offline
        offlineBox.set(offline)
        if r.started { r.announce(offline ? OfflineNoticeCopy.announceOffline : OfflineNoticeCopy.announceOnline) }   // D329
        player.isPlayable = offline ? { [localFiles] in localFiles.hasFile($0.id) } : { _ in true }
        player.upcomingURLsChanged()
        downloads?.networkChanged()   // manual downloads wait while offline, pre-downloads stop; both go again after
        if forced {
            // On sends nothing: a song still streaming gives way to the next one on the phone, or pauses.
            player.stopUnplayableCurrent(message: Self.offlineCopy)
        }
        if offline {
            player.retryAfterFailure()   // a song that failed while the server was suspect: on to the next one here
        } else {
            restoreAfterOffline(reconnecting: leftForced)
        }
    }

    /// Round 28 O1 (D323): the machine follows the preference: manual is `.on`; automatic is `.automatic`, or the
    /// remembered choice while `.on`.
    private func syncReachabilityMode() {
        let mode = preferences.downloads.offlineMode
        let automatic = mode == .on ? reachability.automaticChoice : mode == .automatic
        if reachability.machine.automaticEnabled != automatic { reachabilityEvent(.automatic(enabled: automatic)) }
        if (reachability.machine.state == .manualOffline) != (mode == .on) { reachabilityEvent(.manual(on: mode == .on)) }
    }

    /// Back online (I4): what offline held back. Leaving On logs in first (nothing was sent while it was on).
    private func restoreAfterOffline(reconnecting: Bool) {
        Task { [weak self] in
            if reconnecting { await self?.checkReachability() }
            guard let self, !self.isOffline else { return }
            self.drainScrobblesSoon()
            self.pollRequests()
            Task { await self.refreshFinds() }
            Task { try? await self.refreshMatchIndex() }
            if self.madeForYouShelf.isEmpty { Task { await self.refreshMadeForYou() } }
            if self.lidarr != nil { Task { _ = await self.lidarrAudit() } }
        }
    }

    // MARK: - What's on the phone

    /// What's on the phone now (empty when signed out).
    var offlineCatalog: OfflineCatalog {
        get async {
            guard let store = downloads?.store else { return OfflineCatalog(entries: [], playlists: []) }
            return OfflineCatalog(entries: await store.entries(), playlists: await store.playlists())
        }
    }

    /// Where the cover saved with a download is (one per album or playlist), shown before asking the server. Not
    /// checked here: the caller reads it off the main actor, and a missing file reads as no image.
    func localCoverURL(_ coverArtId: String?) -> URL? {
        guard let coverArtId, let store = downloads?.store else { return nil }
        return store.coverPath(coverArtId: coverArtId)
    }

    /// The lock screen's artwork: offline only a cover saved on the phone (none if it isn't), online the server's.
    func nowPlayingArtworkURL(_ song: Song) -> URL? {
        isOffline ? localCoverURL(song.coverArtId) : coverArtURL(song.coverArtId, size: 600)
    }

    /// What offline pages load again on: the mode, and offline the songs on the phone (the store may only become
    /// readable after first unlock).
    var offlinePageKey: String { isOffline ? "offline|\(downloads?.localFiles.count ?? 0)" : "online" }
}
