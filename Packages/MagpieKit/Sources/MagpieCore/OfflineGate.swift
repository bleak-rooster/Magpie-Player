import Foundation
import os

/// Round 28 O1 (owner, 2026-11-15): one gate for everything Magpie sends (D328). Every transport the app owns is a
/// `GatedTransport` over the same gate, so "Offline mode sends nothing" (D46) holds by construction rather than by each
/// feature remembering to check:
/// - **manual** offline lets nothing out, not even a probe;
/// - **automatic** offline lets out only the reconnect ping (`rest/ping` with no credentials, on the library's
///   transports) and, while a reconnect runs (`beginReconnect`…`endReconnect`), its login (`auth/login`);
/// - **open** (online or suspect) lets everything through.
/// A refused send throws `URLError(.notConnectedToInternet)` before touching the network, so callers treat it as
/// unreachable, as they did with D46's forced-offline error. Counts are kept for tests and the security review.
public final class OfflineGate: Sendable {
    public enum Mode: Sendable, Equatable { case open, automatic, manual }

    /// Which transport a send came through.
    public enum Role: String, Sendable, CaseIterable {
        /// The app's main transport: the library, and everything that shares it (Lidarr, ListenBrainz, MusicBrainz,
        /// Aurral, slskd).
        case main
        /// The reconnect probe's own transport (6 s timeout).
        case probe
        /// Hosts outside the owner's servers or their media: LRCLIB, outside art, previews and Aurral's image proxy.
        case outside
    }

    private struct State {
        var mode: Mode = .open
        var reconnects = 0
        /// Fix round 1 (security L2): the one login URL the reconnect under way is about to send.
        var loginURL: URL?
        var passed = 0
        var refused = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var mode: Mode { state.withLock { $0.mode } }
    public func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }

    /// A reconnect is under way: in automatic offline its login may go out. Balanced by `endReconnect`.
    public func beginReconnect() { state.withLock { $0.reconnects += 1 } }
    public func endReconnect() {
        state.withLock {
            $0.reconnects = max(0, $0.reconnects - 1)
            if $0.reconnects == 0 { $0.loginURL = nil }
        }
    }

    /// Fix round 1 (security L2): the reconnect's login, by its exact URL, may go out once (in automatic offline,
    /// while the reconnect holds the gate). Aurral's login, or a second login, may not.
    public func permitLoginOnce(_ url: URL) { state.withLock { $0.loginURL = url } }

    /// Sends let through and refused since this gate was made.
    public var passedCount: Int { state.withLock { $0.passed } }
    public var refusedCount: Int { state.withLock { $0.refused } }

    /// Whether `request` may go out through `role` now; counts the answer. A login let through uses up its permission.
    public func admit(_ request: URLRequest, role: Role) -> Bool {
        state.withLock { s in
            let ok = Self.permits(request, role: role, mode: s.mode, reconnecting: s.reconnects > 0, loginURL: s.loginURL)
            if ok, s.mode == .automatic, let url = request.url, url == s.loginURL { s.loginURL = nil }
            if ok { s.passed += 1 } else { s.refused += 1 }
            return ok
        }
    }

    /// The rule, on its own.
    public static func permits(_ request: URLRequest, role: Role, mode: Mode, reconnecting: Bool, loginURL: URL? = nil) -> Bool {
        switch mode {
        case .open: return true
        case .manual: return false
        case .automatic:
            guard role != .outside, let url = request.url else { return false }
            if isBarePing(request, url: url) { return true }
            return role == .main && reconnecting && url == loginURL && isLogin(request, url: url)
        }
    }

    /// The query names that carry a Subsonic credential.
    static let credentialQueryNames: Set<String> = ["u", "t", "s", "p", "apikey", "jwt", "token"]

    /// `GET …/rest/ping` with no credential in its query or headers.
    private static func isBarePing(_ request: URLRequest, url: URL) -> Bool {
        let method = (request.httpMethod ?? "GET").uppercased()
        guard method == "GET", url.path.hasSuffix("/rest/ping") || url.path == "rest/ping", request.httpBody == nil else { return false }
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
        guard !names.contains(where: credentialQueryNames.contains) else { return false }
        let headers = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
        return !headers.contains(where: SameOriginRedirects.credentialHeaders.contains)
    }

    /// The library's sign-in: `…/auth/login`, sent with a body (never a GET or HEAD).
    private static func isLogin(_ request: URLRequest, url: URL) -> Bool {
        let method = (request.httpMethod ?? "GET").uppercased()
        return method != "GET" && method != "HEAD" && request.httpBody != nil && url.path.hasSuffix("/auth/login")
    }
}

/// A transport that asks the gate before every send (D328). Both sends are forwarded, so a capped read stays capped.
/// Fix round 1 (security M4): `inner` is private, so nothing can send past the gate through it.
public struct GatedTransport: HTTPTransport {
    private let inner: HTTPTransport
    public let gate: OfflineGate
    public let role: OfflineGate.Role

    #if DEBUG
    /// Tests: the transport a test passed in, to stub it after the model was made.
    public var innerForTesting: HTTPTransport { inner }
    #endif

    public init(_ inner: HTTPTransport, gate: OfflineGate, role: OfflineGate.Role) {
        self.inner = inner
        self.gate = gate
        self.role = role
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard gate.admit(request, role: role) else { throw URLError(.notConnectedToInternet) }
        return try await inner.send(request)
    }

    public func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard gate.admit(request, role: role) else { throw URLError(.notConnectedToInternet) }
        return try await inner.send(request, maxBytes: maxBytes)
    }
}
