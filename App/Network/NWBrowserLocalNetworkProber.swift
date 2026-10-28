import Foundation
import MagpieCore
import Network
import os

/// T3 (D38): asks iOS about local network access with the Network framework. A Bonjour browse for `_http._tcp`
/// (listed in `NSBonjourServices`) is what makes iOS show the Local Network prompt and list Magpie under
/// Settings › Privacy & Security › Local Network; a plain connection to a LAN address only does so when one is made.
/// Denial shows as the browse waiting with `kDNSServiceErr_PolicyDenied`, and a connection waiting with
/// `unsatisfiedReason == .localNetworkDenied`. Nothing is sent: the browse only listens, the connection is cancelled.
@MainActor final class NWBrowserLocalNetworkProber: LocalNetworkProbing {
    /// How long a policy-denied browse may wait while the prompt may still be on screen.
    private let askTimeout: TimeInterval
    /// How long a connection may take to show it is held back.
    private let checkTimeout: TimeInterval

    init(askTimeout: TimeInterval = 30, checkTimeout: TimeInterval = 2) {
        self.askTimeout = askTimeout
        self.checkTimeout = checkTimeout
    }

    func requestAccess() async -> LocalNetworkState {
        let answer = await Self.browse(timeout: askTimeout)
        Log.logger("localnetwork").info("asked: \(answer.rawValue, privacy: .public)")
        return answer
    }

    func isDenied(host: String, port: Int) async -> Bool {
        let denied = await Self.connectionIsDenied(host: host, port: port, timeout: checkTimeout)
        Log.logger("localnetwork").info("connection held back: \(denied, privacy: .public)")
        return denied
    }

    private nonisolated static let queue = DispatchQueue(label: "com.bleak-rooster.magpie.local-network")
    /// kDNSServiceErr_PolicyDenied: the Local Network setting is off, or its prompt is still unanswered.
    private nonisolated static let policyDenied: DNSServiceErrorType = -65570

    /// `.ready` or a result: granted. Policy-denied still after `timeout`: denied. `.failed` (or anything else at the
    /// timeout): unknown. Nonisolated, so the handlers run on `queue` without hopping to the main actor.
    private nonisolated static func browse(timeout: TimeInterval) async -> LocalNetworkState {
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        let once = Once<LocalNetworkState>()
        let sawPolicyDenied = OSAllocatedUnfairLock(initialState: false)
        let answer = await withCheckedContinuation { continuation in
            once.set(continuation)
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.granted)
                case .failed: once.resume(.unknown)
                case .waiting(let error):
                    // The prompt may be up: keep waiting for the owner's answer (or the timeout).
                    if case .dns(let code) = error { sawPolicyDenied.withLock { $0 = code == policyDenied } }
                default: break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty { once.resume(.granted) }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(sawPolicyDenied.withLock { $0 } ? .denied : .unknown)
            }
        }
        browser.cancel()
        return answer
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
