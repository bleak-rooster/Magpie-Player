import Foundation
import MagpieCore

/// The owner's Lidarr: its address and API key.
struct LidarrConnection: Codable, Sendable, Equatable {
    var base: URL
    var apiKey: String
}

/// Where the Lidarr connection is kept. Tests substitute their own.
protocol LidarrConnectionStoring: Sendable {
    func save(_ connection: LidarrConnection) throws
    func load() -> LidarrConnection?
    func clear()
}

/// Kept in the Keychain next to the Navidrome session (same service), never in UserDefaults.
struct LidarrConnectionStore: LidarrConnectionStoring {
    let keychain: KeychainStore

    static let standard = LidarrConnectionStore(keychain: SessionStore.standard.keychain)

    private static let key = "lidarr.connection"

    func save(_ connection: LidarrConnection) throws {
        try keychain.set(JSONEncoder().encode(connection), for: Self.key)
    }

    func load() -> LidarrConnection? {
        guard let data = try? keychain.get(Self.key) else { return nil }
        return try? JSONDecoder().decode(LidarrConnection.self, from: data)
    }

    func clear() { try? keychain.remove(Self.key) }
}

/// The optional ListenBrainz user token (Settings). Keychain only.
protocol ListenBrainzTokenStoring: Sendable {
    func save(_ token: String) throws
    func load() -> String?
    func clear()
}

struct ListenBrainzTokenStore: ListenBrainzTokenStoring {
    let keychain: KeychainStore

    static let standard = ListenBrainzTokenStore(keychain: SessionStore.standard.keychain)

    private static let key = "listenbrainz.token"

    func save(_ token: String) throws { try keychain.set(Data(token.utf8), for: Self.key) }

    func load() -> String? {
        guard let data = try? keychain.get(Self.key), let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return nil
        }
        return token
    }

    func clear() { try? keychain.remove(Self.key) }
}
