import Foundation
import MagpieCore
import NavidromeKit

/// A saved server and the credentials for it.
struct SavedSession: Sendable {
    var endpoint: ServerEndpoint
    var credentials: NavidromeCredentials
}

/// What reading the saved session found.
enum SessionLoad: Sendable {
    /// Nothing saved (or what is saved can't be decoded): show Connect.
    case none
    case session(SavedSession)
    /// The Keychain couldn't be read right now, e.g. `errSecInteractionNotAllowed` before the
    /// first unlock after a reboot (CarPlay or background launch). Not the same as signed out.
    case unavailable
}

/// Where the session is kept. `SessionStore` is the Keychain; tests substitute their own.
protocol SessionStoring: Sendable {
    func save(endpoint: ServerEndpoint, credentials: NavidromeCredentials) throws
    func load() -> SessionLoad
    func clear()
}

/// The signed-in server and credentials, kept in the Keychain (never UserDefaults).
struct SessionStore: SessionStoring {
    let keychain: KeychainStore

    static let standard = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.session"))

    private static let endpointKey = "navidrome.endpoint"
    private static let credentialsKey = "navidrome.credentials"

    func save(endpoint: ServerEndpoint, credentials: NavidromeCredentials) throws {
        try keychain.set(JSONEncoder().encode(endpoint), for: Self.endpointKey)
        try keychain.set(JSONEncoder().encode(credentials), for: Self.credentialsKey)
    }

    func load() -> SessionLoad {
        let e: Data?, c: Data?
        do {
            e = try keychain.get(Self.endpointKey)
            c = try keychain.get(Self.credentialsKey)
        } catch {
            Log.logger("session").error("keychain unreadable: \(Log.category(of: error), privacy: .public)")
            return .unavailable
        }
        guard let e, let c,
              let endpoint = try? JSONDecoder().decode(ServerEndpoint.self, from: e),
              let credentials = try? JSONDecoder().decode(NavidromeCredentials.self, from: c),
              !endpoint.bases.isEmpty else { return .none }
        return .session(SavedSession(endpoint: endpoint, credentials: credentials))
    }

    func clear() {
        try? keychain.remove(Self.endpointKey)
        try? keychain.remove(Self.credentialsKey)
    }
}

extension SessionLoad {
    /// The saved session, if one was read.
    var saved: SavedSession? { if case .session(let s) = self { return s } else { return nil } }
}
