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
