import Foundation
import MagpieCore
import Network
import os

/// What a local-network ask sees, in order: the browse's states, its own service turning up, the deadline.
enum LocalNetworkBrowseEvent: Sendable, Equatable {
    /// The browse started. Says nothing about the permission: NWBrowser gets here whatever the answer (fix I1).
    case browserReady
    /// The browse waits with kDNSServiceErr_PolicyDenied: the setting is off, or its prompt is still on screen.
    case browserWaitingPolicyDenied
    /// The browse waits for some other reason (no network).
    case browserWaitingOther
    case browserFailed
    case listenerFailed
    /// The browse found the service Magpie itself advertises: local network traffic gets through.
    case foundOwnService
    case timeout
}

/// T3 fix I1: the decision, apart from the Network framework so it can be tested with event sequences. Granted only
/// when the browse finds Magpie's own service; denied only when PolicyDenied still stands at the deadline; otherwise
/// unknown (never granted by default).
struct LocalNetworkBrowseDecision: Sendable {
    private var policyDenied = false

    /// The answer, or nil to keep waiting.
    mutating func handle(_ event: LocalNetworkBrowseEvent) -> LocalNetworkState? {
        switch event {
        case .foundOwnService: return .granted
        case .browserWaitingPolicyDenied: policyDenied = true
        case .browserReady, .browserWaitingOther: policyDenied = false   // only a standing PolicyDenied counts
        case .browserFailed, .listenerFailed: return .unknown
        case .timeout: return policyDenied ? .denied : .unknown
        }
        return nil
    }
}

/// T3 (D38): asks iOS about local network access with the Network framework, the standard way: Magpie advertises a
/// Bonjour service of its own (`_magpie._tcp`, an `NWListener` that takes no connections) and browses for it. Both
/// are listed in `NSBonjourServices`. That shows the Local Network prompt and lists Magpie under Settings › Privacy &
/// Security › Local Network; finding its own service means the answer was Allow. A connection to a LAN address
/// waiting with `unsatisfiedReason == .localNetworkDenied` means the setting is off. Nothing is sent: incoming
/// connections are cancelled, the check's connection is cancelled, and the service name is random (no device name).
@MainActor final class NWBrowserLocalNetworkProber: LocalNetworkProbing {
    nonisolated static let serviceType = "_magpie._tcp"
    /// How long the ask may wait while the prompt may still be on screen.
    private let askTimeout: TimeInterval
    /// How long a connection may take to show it is held back.
    private let checkTimeout: TimeInterval

    init(askTimeout: TimeInterval = 30, checkTimeout: TimeInterval = 2) {
        self.askTimeout = askTimeout
        self.checkTimeout = checkTimeout
    }

    func requestAccess() async -> LocalNetworkState {
        let answer = await Self.decide(timeout: askTimeout, start: Self.advertiseAndBrowse)
        log("asked: \(answer.rawValue)")
        return answer
    }

    func isDenied(host: String, port: Int) async -> Bool {
        let denied = await Self.connectionIsDenied(host: host, port: port, timeout: checkTimeout)
        log("connection held back: \(denied)")
        return denied
    }

    private nonisolated static let queue = DispatchQueue(label: "com.bleak-rooster.magpie.local-network")
    /// kDNSServiceErr_PolicyDenied.
    private nonisolated static let policyDenied: DNSServiceErrorType = -65570

    /// Runs `start` (which reports events and returns how to stop) until the decision has an answer or `timeout`
    /// passes, then stops it. Nonisolated: events arrive on any queue.
    nonisolated static func decide(
        timeout: TimeInterval,
        start: @Sendable (_ emit: @escaping @Sendable (LocalNetworkBrowseEvent) -> Void) -> @Sendable () -> Void
    ) async -> LocalNetworkState {
        let once = Once<LocalNetworkState>()
        let decision = OSAllocatedUnfairLock(initialState: LocalNetworkBrowseDecision())
        let emit: @Sendable (LocalNetworkBrowseEvent) -> Void = { event in
            log("event: \(event)")
            if let answer = decision.withLock({ $0.handle(event) }) { once.resume(answer) }
        }
        var stop: (@Sendable () -> Void)?
        let answer = await withCheckedContinuation { continuation in
            once.set(continuation)
            stop = start(emit)
            queue.asyncAfter(deadline: .now() + timeout) { emit(.timeout) }
        }
        stop?()
        return answer
    }

    /// The real events: Magpie's own service advertised, and a browse for it. Both live until stopped.
    private nonisolated static func advertiseAndBrowse(
        _ emit: @escaping @Sendable (LocalNetworkBrowseEvent) -> Void
    ) -> @Sendable () -> Void {
        let name = "Magpie-" + UUID().uuidString.prefix(8)
        guard let listener = try? NWListener(using: .tcp) else {
            emit(.listenerFailed)
            return {}
        }
        listener.service = NWListener.Service(name: name, type: serviceType)
        listener.newConnectionHandler = { $0.cancel() }   // advertised only to be found; never talks
        listener.stateUpdateHandler = { state in
            log("listener: \(state)")
            if case .failed = state { emit(.listenerFailed) }
        }
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { state in
            log("browser: \(state)")
            switch state {
            case .ready: emit(.browserReady)
            case .waiting(let error):
                if case .dns(let code) = error, code == policyDenied { emit(.browserWaitingPolicyDenied) } else { emit(.browserWaitingOther) }
            case .failed: emit(.browserFailed)
            default: break
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            let own = results.contains {
                if case .service(let found, _, _, _) = $0.endpoint { found == name } else { false }
            }
            log("browse results: \(results.count), own service: \(own)")
            if own { emit(.foundOwnService) }
        }
        listener.start(queue: queue)
        browser.start(queue: queue)
        return {
            browser.cancel()
            listener.cancel()
        }
    }

    /// True when, within `timeout`, a tcp connection to host:port waits because of the Local Network setting.
    private nonisolated static func connectionIsDenied(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: max(port, 1))) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let once = Once<Bool>()
        let denied = await withCheckedContinuation { continuation in
            once.set(continuation)
            connection.pathUpdateHandler = { path in
                if path.unsatisfiedReason == .localNetworkDenied { once.resume(true) }
            }
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .waiting:
                    if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied { once.resume(true) }
                case .ready, .failed, .cancelled: once.resume(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(false) }
        }
        connection.cancel()
        return denied
    }

    /// States and events only: no addresses, names or other personal data.
    private nonisolated static func log(_ text: String) {
        Log.logger("localnetwork").info("\(text, privacy: .public)")
    }

    private func log(_ text: String) { Self.log(text) }
}

/// A continuation resumed exactly once, from whichever handler answers first.
private final class Once<T: Sendable>: Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<T, Never>?>(initialState: nil)

    func set(_ c: CheckedContinuation<T, Never>) { continuation.withLock { $0 = c } }

    func resume(_ value: T) {
        let c = continuation.withLock { c -> CheckedContinuation<T, Never>? in defer { c = nil }; return c }
        c?.resume(returning: value)
    }
}
