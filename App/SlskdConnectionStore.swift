import Foundation
import MagpieCore

/// Round 23 (D192): the owner's slskd (the Soulseek client Lidarr downloads through): its address and API key. Optional;
/// only used to clear a removed artist's leftover downloads.
struct SlskdConnection: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
                        CustomReflectable {
    var base: URL
    var apiKey: String

    // Never prints the key.
    var description: String { "SlskdConnection(\(Redactor.sanitize(base)))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["base": Redactor.sanitize(base)]) }
}

/// Where the slskd connection is kept. Tests substitute their own.
protocol SlskdConnectionStoring: Sendable {
    func save(_ connection: SlskdConnection) throws
    func load() -> SlskdConnection?
    func clear()
}

/// Kept in the Keychain next to the Navidrome session and Lidarr's (same service), never in UserDefaults.
struct SlskdConnectionStore: SlskdConnectionStoring {
    let keychain: KeychainStore

    static let standard = SlskdConnectionStore(keychain: SessionStore.standard.keychain)

    private static let key = "slskd.connection"

    func save(_ connection: SlskdConnection) throws {
        try keychain.set(JSONEncoder().encode(connection), for: Self.key)
    }

    func load() -> SlskdConnection? {
        guard let data = try? keychain.get(Self.key) else { return nil }
        return try? JSONDecoder().decode(SlskdConnection.self, from: data)
    }

    func clear() { try? keychain.remove(Self.key) }
}

/// Tests: kept in memory.
final class InMemorySlskdStore: SlskdConnectionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: SlskdConnection?
    init(_ connection: SlskdConnection? = nil) { saved = connection }
    func save(_ connection: SlskdConnection) throws { lock.withLock { saved = connection } }
    func load() -> SlskdConnection? { lock.withLock { saved } }
    func clear() { lock.withLock { saved = nil } }
}
