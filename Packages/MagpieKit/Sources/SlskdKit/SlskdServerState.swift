import Foundation

/// Round 24 (owner, 2026-11-08): slskd's connection to the Soulseek network, as `GET /api/v0/server`
/// (`ServerController`, `[Authorize(Policy=Any)]`) answers it: slskd's `ServerState` record in camelCase JSON
/// (`isConnected`, `isLoggedIn`, `isTransitioning`, and `state`, its client-state flags such as `Connected, LoggedIn`).
/// Decoded leniently: a missing or odd field is unknown, and unknown is never "down", so nothing is ever sent on a
/// guess. (D217)
public struct SlskdServerState: Sendable, Equatable {
    public var isConnected: Bool?
    public var isLoggedIn: Bool?
    public var isTransitioning: Bool?
    /// slskd's flags, e.g. `Connected, LoggedIn`, `Disconnected`, `Connecting`.
    public var state: String?

    public init(isConnected: Bool? = nil, isLoggedIn: Bool? = nil, isTransitioning: Bool? = nil, state: String? = nil) {
        self.isConnected = isConnected; self.isLoggedIn = isLoggedIn; self.isTransitioning = isTransitioning; self.state = state
    }

    /// What the state means for "Keep Soulseek connected".
    public enum Condition: Sendable, Equatable {
        case connected
        /// slskd is connecting, logging in or disconnecting by itself: nothing is asked.
        case transitioning
        /// Disconnected and not on its way back: the one state Magpie asks slskd to reconnect from.
        case down
        /// Not enough to tell: treated as neither up nor down.
        case unknown
    }

    /// The flags of `state`, one by one (so `Disconnected` is never read as `Connected`).
    var flags: Set<String> {
        Set((state ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    public var condition: Condition {
        let flags = flags
        let connected = isConnected ?? (flags.isEmpty ? nil : flags.contains("connected"))
        let transitioning = isTransitioning
            ?? (flags.isEmpty ? nil : !flags.isDisjoint(with: ["connecting", "disconnecting", "loggingin"]))
        switch (connected, transitioning) {
        case (_, true?): return .transitioning
        case (true?, _): return .connected
        case (false?, false?): return .down
        default: return .unknown
        }
    }

    /// slskd's answer, read leniently (fields of another type are unknown). Throws `SlskdError.decoding` when it isn't
    /// a JSON object at all.
    public static func decode(_ data: Data) throws -> SlskdServerState {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SlskdError.decoding }
        func flag(_ key: String) -> Bool? {
            // JSONSerialization gives NSNumber for both numbers and booleans: only a real boolean counts.
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        return SlskdServerState(isConnected: flag("isConnected"), isLoggedIn: flag("isLoggedIn"),
                                isTransitioning: flag("isTransitioning"), state: object["state"] as? String)
    }
}

/// What one "Keep Soulseek connected" check found (and did). (D217, D218)
public enum SlskdCheck: Sendable, Equatable, Codable {
    case connected
    case transitioning
    /// slskd is disconnected. `asked`: Magpie asked it to reconnect in this check.
    case down(asked: Bool)
    /// slskd is disconnected and refused this API key's ask to reconnect (401/403): the key can only read.
    case keyCannotReconnect
    /// slskd couldn't be read (network down, a wrong key, an error). Not a failure: nothing counts, nothing is sent.
    case unreachable
    /// slskd answered without saying whether it is connected.
    case unknown

    /// A readable check that found slskd not connected: what the outage counts.
    public var isFailure: Bool {
        switch self {
        case .transitioning, .down, .keyCannotReconnect: true
        case .connected, .unreachable, .unknown: false
        }
    }
}

/// Round 24 (owner, 2026-11-08): the check behind "Keep Soulseek connected". Reads slskd's state; only when it is down
/// (disconnected and not transitioning) asks it once to reconnect through `SlskdWriteGate`, which re-reads the state,
/// refuses unless the owner's switch is on for this address and key, and never asks twice within 60 s. Nothing is sent
/// while the state can't be read. (D217, D218)
public enum SlskdKeepConnected {
    /// How long after asking slskd to reconnect it is not asked again (it reconnects on its own once asked).
    public static let connectCooldown: TimeInterval = 60
    /// While the app is open: a check a minute, and the check after an ask 30 s later (it judges the ask).
    public static let checkInterval: Duration = .seconds(60)
    public static let checkAfterAsking: Duration = .seconds(30)

    public static func check(client: SlskdClient, gate: SlskdWriteGate) async -> SlskdCheck {
        let state: SlskdServerState
        do { state = try await client.serverState() } catch { return .unreachable }
        switch state.condition {
        case .connected: return .connected
        case .transitioning: return .transitioning
        case .unknown: return .unknown
        case .down: break
        }
        if await gate.keyRefused { return .keyCannotReconnect }   // fix round 1 M3: held until the key changes
        guard await gate.mayAskToConnect() else { return .down(asked: false) }
        do {
            try await gate.perform(.connect)   // Round 24 (D218): the one caller of the connect shape
            return .down(asked: true)
        } catch SlskdError.unauthorized {
            return .keyCannotReconnect
        } catch is SlskdGateError {
            return .down(asked: false)   // refused before sending (or slskd read connected meanwhile)
        } catch {
            return .down(asked: true)   // sent, the answer lost or an error: the next check judges it
        }
    }
}

/// Round 24 (owner, 2026-11-08): one outage of slskd's connection, counted in checks Magpie really made (iOS may run
/// few in the background, so never a timer). The owner is told once, after `checksBeforeTelling` failed checks in a row
/// spanning at least `minimumSpan`; a connected read ends the outage and rearms it; unreadable or unknown checks
/// change nothing. Saved per slskd, so background passes across launches add up. (D219)
public struct SlskdOutage: Sendable, Equatable, Codable {
    public static let checksBeforeTelling = 3
    public static let minimumSpan: TimeInterval = 10 * 60

    /// Failed checks in a row.
    public var failedChecks = 0
    /// The first of them: "disconnected since".
    public var since: Date?
    /// The owner was told about this outage.
    public var notified = false

    public init() {}

    /// Adds one check. Returns true exactly once per outage: when the owner is to be told now.
    public mutating func record(_ check: SlskdCheck, at now: Date) -> Bool {
        if check == .connected {
            self = SlskdOutage()
            return false
        }
        guard check.isFailure else { return false }
        // Fix round 1 M1: a start in the future (the clock was set back) starts the outage again from now; whether the
        // owner was told already is kept.
        if let start = since, start > now {
            since = nil
            failedChecks = 0
        }
        failedChecks += 1
        let start = since ?? now
        since = start
        guard !notified, failedChecks >= Self.checksBeforeTelling, now.timeIntervalSince(start) >= Self.minimumSpan else {
            return false
        }
        notified = true
        return true
    }
}
