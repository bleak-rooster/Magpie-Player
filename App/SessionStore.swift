import Foundation
import MagpieCore
import NavidromeKit

/// The signed-in server and credentials, kept in the Keychain (never UserDefaults).
struct SessionStore: Sendable {
    let keychain: KeychainStore

    static let standard = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.session"))

    private static let endpointKey = "navidrome.endpoint"
    private static let credentialsKey = "navidrome.credentials"

    func save(endpoint: ServerEndpoint, credentials: NavidromeCredentials) throws {
        try keychain.set(JSONEncoder().encode(endpoint), for: Self.endpointKey)
        try keychain.set(JSONEncoder().encode(credentials), for: Self.credentialsKey)
    }

    /// The saved session, or nil when nothing (or something unreadable) is stored.
    func load() -> (endpoint: ServerEndpoint, credentials: NavidromeCredentials)? {
        guard let e = try? keychain.get(Self.endpointKey), let c = try? keychain.get(Self.credentialsKey),
              let endpoint = try? JSONDecoder().decode(ServerEndpoint.self, from: e),
              let credentials = try? JSONDecoder().decode(NavidromeCredentials.self, from: c),
              !endpoint.bases.isEmpty else { return nil }
        return (endpoint, credentials)
    }

    func clear() {
        try? keychain.remove(Self.endpointKey)
        try? keychain.remove(Self.credentialsKey)
    }
}
