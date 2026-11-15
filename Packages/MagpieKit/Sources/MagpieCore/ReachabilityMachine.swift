import Foundation

/// Round 28 O1 (owner, 2026-11-15): whether the library answers, as a pure state machine (plan §7.1). The app feeds it
/// events and does what its effects say; it keeps no clock of its own (every event comes with `now`, in seconds on the
/// app's clock), so tests drive time exactly and nothing sleeps.
///
/// - Thirty seconds (D324, supersedes D46's "10 s or 2 failed reconnects"): `suspect(since)` becomes
///   `automaticOffline` when the library hasn't answered for `window` seconds since the first unanswered try, decided by
///   a tick at that mark, never at the next failure. Any answer ends it. The window counts only while Magpie runs:
///   coming to the front restarts it, and so does a tick that arrives long after its mark (iOS had suspended the app).
/// - No connection at all (owner Q1): with no network path for `pathGrace` seconds, Automatic goes offline at once.
/// - Reconnect checks (D326) only while suspect or automatic offline, never in manual offline: 5 s after the first
///   failure, then every 10 s; offline every 30 s for 5 minutes, every 60 s to 15 minutes, then every 2 minutes;
///   doubled in Low Power Mode; 2 s after the network path returns or changes; at once on Try again, pull to refresh or
///   coming to the front. One probe at a time.
/// - Off (`automaticEnabled == false`): never offline; suspect still holds manual downloads and is probed until it
///   clears (D46, unchanged).
/// - Manual offline (D323, D327) is the owner's preference: nothing is probed, and it outlives sign-out.
public struct ReachabilityMachine: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case online
        /// A try went unanswered at `since` (or the window restarted then).
        case suspect(since: Double)
        /// Automatic offline since `since`.
        case automaticOffline(since: Double)
        case manualOffline
    }

    public enum Event: Sendable, Equatable {
        /// A connection or server-path failure after failover, or a reconnect that reached no address (D325).
        case failure
        /// A probe and its login, or any authenticated answer from the library.
        case answered
        /// 401/403: the library answers and refuses the sign-in (D46): online, never offline.
        case authRejected
        /// The probe this machine asked for is over (its verdict, if any, came as `answered` or `failure`).
        case probeFinished
        /// Try again, pull to refresh, a stream or download that couldn't connect: probe now if down.
        case probeRequested
        /// The network path, or its interface, changed.
        case pathChanged(connected: Bool)
        /// Magpie came to the front; `lastAnswer` is when the library last answered.
        case becameActive(lastAnswer: Double?)
        /// A wake the machine asked for (`nextWake`).
        case tick
        case manual(on: Bool)
        /// Go offline automatically, on or off.
        case automatic(enabled: Bool)
        case lowPower(Bool)
        case signedIn
        case signedOut
    }

    public enum Effect: Sendable, Equatable {
        /// Probe the library's addresses now (ping without credentials, then one login).
        case probeNow
        case scheduleProbe(at: Double)
        /// The 30 s mark, or the end of the no-path grace.
        case scheduleTick(at: Double)
        case cancelProbes
        case goOffline
        case goOnline
    }

    public static let window: Double = 30
    public static let firstProbe: Double = 5
    public static let suspectInterval: Double = 10
    /// No path for this long goes offline at once (Q1).
    public static let pathGrace: Double = 2
    /// A path change probes this long after the last change (paths often change several times in a row).
    public static let pathDebounce: Double = 2
    /// Coming to the front pings when the library hasn't answered for longer than this.
    public static let activeStaleness: Double = 60
    /// A tick later than this after its mark means Magpie wasn't running: the window restarts.
    public static let lateTolerance: Double = 10

    /// Offline: 30 s for the first 5 minutes, 60 s to 15 minutes, then 120 s.
    public static func offlineInterval(afterOfflineFor elapsed: Double) -> Double {
        elapsed < 300 ? 30 : elapsed < 900 ? 60 : 120
    }

    public private(set) var state: State
    public private(set) var automaticEnabled: Bool
    public private(set) var lowPower = false
    public private(set) var connected = true
    public private(set) var pathLostAt: Double?
    public private(set) var hasSession = false
    /// A probe this machine asked for hasn't finished.
    public private(set) var probing = false
    public private(set) var nextProbeAt: Double?

    public init(automaticEnabled: Bool = true, manual: Bool = false) {
        self.automaticEnabled = automaticEnabled
        state = manual ? .manualOffline : .online
    }

    public var isSuspect: Bool { if case .suspect = state { true } else { false } }
    public var isAutomaticOffline: Bool { if case .automaticOffline = state { true } else { false } }
    /// Suspect or automatic offline: the states that probe.
    public var isDown: Bool { isSuspect || isAutomaticOffline }

    /// The 30 s mark while suspect, when Automatic is on.
    public var offlineDeadline: Double? {
        guard hasSession, automaticEnabled, case .suspect(let since) = state else { return nil }
        return since + Self.window
    }

    /// When the app should send the next `tick`: the next probe, the 30 s mark, or the end of the no-path grace.
    public var nextWake: Double? {
        let path = pathRuleApplies && !connected ? pathLostAt.map { $0 + Self.pathGrace } : nil
        return [isDown ? nextProbeAt : nil, offlineDeadline, path].compactMap { $0 }.min()
    }

    public mutating func handle(_ event: Event, now: Double) -> [Effect] {
        var fx: [Effect] = []
        switch event {
        case .signedIn:
            guard !hasSession else { break }
            hasSession = true
            fx += pathLost(now)
        case .signedOut:
            hasSession = false
            let wasOffline = isAutomaticOffline
            if state != .manualOffline { state = .online }
            fx += cancel()
            if wasOffline { fx.append(.goOnline) }
        case .manual(let on):
            if on {
                guard state != .manualOffline else { break }
                let wasOffline = isAutomaticOffline
                state = .manualOffline
                fx += cancel()
                if wasOffline { fx.append(.goOnline) }   // manual takes over; leaving it starts online
            } else if state == .manualOffline {
                // Fix round 1 (design H1): offline by itself until a check (ping and login) answers, so nothing says
                // "Back online." before the library has; a failed check leaves it offline with no blip. Off (never
                // offline) or no session: online, and the app logs in.
                if automaticEnabled, hasSession {
                    state = .automaticOffline(since: now)
                    fx.append(.goOffline)
                    fx += probeNow()
                } else {
                    state = .online
                }
            }
        case .automatic(let enabled):
            guard enabled != automaticEnabled else { break }
            automaticEnabled = enabled
            switch state {
            case .automaticOffline where !enabled:
                state = .suspect(since: now)   // Off: online, still probed until it answers
                fx.append(.goOnline)
            case .suspect(let since) where enabled:
                if now >= since + Self.window { fx += goOffline(now) } else { fx.append(.scheduleTick(at: since + Self.window)) }
            default: break
            }
            fx += pathLost(now)
        case .lowPower(let on):
            lowPower = on
        case .failure:
            guard hasSession, state != .manualOffline else { break }
            if state == .online {
                state = .suspect(since: now)
                let at = now + Self.firstProbe * factor
                nextProbeAt = at
                fx.append(.scheduleProbe(at: at))
                if automaticEnabled { fx.append(.scheduleTick(at: now + Self.window)) }
            }
            fx += pathRule(now)
        case .answered, .authRejected:
            guard state != .manualOffline else { break }
            let wasOffline = isAutomaticOffline, wasDown = isDown
            state = .online
            if wasDown { fx += cancel() }
            if wasOffline { fx.append(.goOnline) }
        case .probeFinished:
            guard probing else { break }
            probing = false
            if isDown, nextProbeAt == nil { fx += schedule(now + interval(now)) }
        case .probeRequested:
            guard hasSession, isDown else { break }
            fx += probeNow()
        case .pathChanged(let isConnected):
            connected = isConnected
            if isConnected {
                pathLostAt = nil
                if hasSession, isDown { fx += schedule(now + Self.pathDebounce) }
            } else {
                if pathLostAt == nil { pathLostAt = now }
                fx += pathLost(now)
            }
        case .becameActive(let lastAnswer):
            guard hasSession else { break }
            switch state {
            case .manualOffline: break
            case .online:
                if lastAnswer.map({ now - $0 > Self.activeStaleness }) ?? true { fx += probeNow() }
            case .suspect:
                fx += restartWindow(now)
            case .automaticOffline:
                fx += probeNow()
            }
        case .tick:
            guard hasSession else { break }
            if let deadline = offlineDeadline, now >= deadline {
                if now - deadline > Self.lateTolerance { return restartWindow(now) }
                fx += goOffline(now)
            }
            fx += pathRule(now)
            if isDown, let at = nextProbeAt, now >= at {
                nextProbeAt = nil
                fx += probeNow()
            }
        }
        return fx
    }

    // MARK: - Steps

    private var factor: Double { lowPower ? 2 : 1 }

    /// The no-path rule can take the machine offline from here.
    private var pathRuleApplies: Bool {
        hasSession && automaticEnabled && (state == .online || isSuspect)
    }

    /// The gap before the next probe, from `now`.
    private func interval(_ now: Double) -> Double {
        let base: Double
        switch state {
        case .suspect(let since):
            base = now - since < Self.window ? Self.suspectInterval : Self.offlineInterval(afterOfflineFor: now - since - Self.window)
        case .automaticOffline(let since):
            base = Self.offlineInterval(afterOfflineFor: now - since)
        default:
            base = Self.suspectInterval
        }
        return base * factor
    }

    private mutating func schedule(_ at: Double) -> [Effect] {
        nextProbeAt = at
        return [.scheduleProbe(at: at)]
    }

    private mutating func probeNow() -> [Effect] {
        guard !probing else { return [] }
        probing = true
        nextProbeAt = nil
        return [.probeNow]
    }

    private mutating func cancel() -> [Effect] {
        nextProbeAt = nil
        return [.cancelProbes]
    }

    private mutating func goOffline(_ now: Double) -> [Effect] {
        state = .automaticOffline(since: now)
        return [.goOffline] + schedule(now + interval(now))
    }

    private mutating func restartWindow(_ now: Double) -> [Effect] {
        state = .suspect(since: now)
        var fx: [Effect] = []
        if automaticEnabled { fx.append(.scheduleTick(at: now + Self.window)) }
        return fx + probeNow()
    }

    /// The path is down: the tick at the end of the grace, or offline now if the grace is over.
    private mutating func pathLost(_ now: Double) -> [Effect] {
        guard pathRuleApplies, !connected, let lost = pathLostAt else { return [] }
        let rule = pathRule(now)
        return rule.isEmpty ? [.scheduleTick(at: lost + Self.pathGrace)] : rule
    }

    /// No path for `pathGrace`: offline at once (Q1).
    private mutating func pathRule(_ now: Double) -> [Effect] {
        guard pathRuleApplies, !connected, let lost = pathLostAt, now >= lost + Self.pathGrace else { return [] }
        return goOffline(now)
    }
}

/// Round 28 O1 (owner, 2026-11-15): the clock the app runs the machine on, in seconds. Tests pass one they move by hand,
/// so the 30 s rule and the probe schedule are driven exactly and nothing sleeps (plan §4).
public protocol ReachabilityClock: Sendable {
    func now() -> Double
    /// Returns at `deadline` (or at once if it has passed); throws when the task is cancelled.
    func sleep(until deadline: Double) async throws
}

/// The real clock: seconds since it was made, on the continuous clock.
public struct ContinuousReachabilityClock: ReachabilityClock {
    private let origin = ContinuousClock.now

    public init() {}

    public func now() -> Double {
        let elapsed = (ContinuousClock.now - origin).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    public func sleep(until deadline: Double) async throws {
        let finite = deadline.isFinite ? max(0, deadline) : 0
        try await Task.sleep(until: origin + .seconds(finite), clock: .continuous)
    }
}
