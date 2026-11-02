import AurralKit
import Foundation
import MagpieCore
import NavidromeKit
import Observation

/// Round 12 Y6: the owner's Aurral (Discover): its address and API key. The key is full admin on Aurral, so it lives
/// only in the Keychain, is never logged and never shown.
struct AurralConnection: Codable, Sendable, Equatable {
    var base: URL
    var apiKey: String
}

/// Where the Aurral connection is kept. Tests substitute their own.
protocol AurralConnectionStoring: Sendable {
    func save(_ connection: AurralConnection) throws
    func load() -> AurralConnection?
    func clear()
}

/// Kept in the Keychain next to the Navidrome session and Lidarr (same service), never in UserDefaults.
struct AurralConnectionStore: AurralConnectionStoring {
    let keychain: KeychainStore

    static let standard = AurralConnectionStore(keychain: SessionStore.standard.keychain)

    private static let key = "aurral.connection"

    func save(_ connection: AurralConnection) throws {
        try keychain.set(JSONEncoder().encode(connection), for: Self.key)
    }

    func load() -> AurralConnection? {
        guard let data = try? keychain.get(Self.key) else { return nil }
        return try? JSONDecoder().decode(AurralConnection.self, from: data)
    }

    func clear() { try? keychain.remove(Self.key) }
}

/// Discover's state for the signed-in account (AppModel+Discover.swift): the Aurral connection, what Aurral last said,
/// the playlists that are its flows, and the main library's copies found for flow songs.
@MainActor @Observable final class DiscoverState {
    @ObservationIgnored let store: any AurralConnectionStoring
    /// The saved Aurral, if any. Discover shows only while there is one.
    var connection: AurralConnection?
    /// `/api/health`, as last read (Settings shows the version).
    var health: AurralHealth?
    /// `/api/playlists/status`, as last read (the flows, the worker's progress).
    var status: AurralStatus?
    /// When `status` was read.
    @ObservationIgnored var statusReadAt: Date?
    /// Every flow song Aurral knows, as last read (empty when its route is missing).
    var jobs: [AurralJob] = []
    /// The Navidrome playlists that are Aurral's flows, as last matched.
    var playlists: [DiscoverPlaylist] = []
    /// Every song id seen in a Discover playlist (Aurral's copies): never a "library copy" of anything.
    var flowSongIds: Set<String> = []
    /// The main library's copy of a flow song, by the flow song's id (what Discover shows and plays in its place).
    var copies: [String: Song] = [:]
    /// Album ids of Aurral's copies (an artist page hides one whose every song has a library copy).
    var flowAlbumSongs: [String: Set<String>] = [:]
    /// A Refresh Flow just sent, per flow, until Aurral's status shows its run.
    var refreshing: Set<String> = []

    init(store: any AurralConnectionStoring) {
        self.store = store
        self.connection = store.load()
    }

    /// Forgets everything read for the account (sign-out, another Aurral).
    func forgetReads() {
        health = nil
        status = nil
        statusReadAt = nil
        jobs = []
        playlists = []
        flowSongIds = []
        copies = [:]
        flowAlbumSongs = [:]
        refreshing = []
    }
}
