import Foundation

/// Round 27 R (owner, 2026-11-14): "an option within Lidarr settings to manually search for all missing albums in
/// monitored artists", and the same on a schedule (D289–D291). Lidarr's own `MissingAlbumSearch` command searches every
/// album without files where the album and its artist are monitored, minus albums already in the queue, so it is
/// exactly what the owner asked for. It is the one command not confined to the ledger (it searches the owner's own
/// albums by design): the gate sends it only as `ConfinedShape.missingAlbumSearch`, with the body below and nothing
/// else, while "Allow Magpie to change your library" is on, no such command is queued or started in Lidarr's fresh
/// `GET /command`, and at least `floor` after the last one this gate's record knows of (saved before sending, M6).
/// `scripts/check-writes.sh` pins the record's key and type to this file.
public enum MissingAlbumSearch {
    /// Lidarr's command name (`MissingAlbumSearchCommand`).
    public static let commandName = "MissingAlbumSearch"

    /// The one body the shape sends: exactly `{"name": "MissingAlbumSearch"}`. No `artistId` (the whole library).
    public struct Body: Encodable, Sendable, Equatable {
        public let name: String
        public init() { name = MissingAlbumSearch.commandName }
    }

    /// At most one every ten minutes from this gate, whatever asks (a lost answer is re-proven by the command read).
    public static let floor: TimeInterval = 600

    /// Why the gate refused: one is queued or started in Lidarr now.
    public static let alreadyRunning = "a missing-album search is already queued or running"
    /// Why the gate refused: its record says one went less than `floor` ago (a time in the future counts as now).
    public static let tooSoon = "a missing-album search was sent less than ten minutes ago"

    static let recordKeyPrefix = "magpie.lidarr.missingSearch"

    /// The gate's record for one Lidarr instance (`LidarrClient.instanceScope`), in the gate's UserDefaults.
    public static func recordKey(scope: String) -> String { "\(recordKeyPrefix).\(scope)" }

    /// Disconnect and sign-out forget it with the other Lidarr keys (the next Lidarr starts afresh).
    public static func forgetRecord(scope: String, in defaults: UserDefaults) {
        defaults.removeObject(forKey: recordKey(scope: scope))
    }
}

/// Where the gate keeps when it last sent a `MissingAlbumSearch`. Internal: the gate's own (tests swap in a failing one).
protocol MissingAlbumSearchStore: Sendable {
    func last(scope: String) -> Date?
    /// Throws when the time can't be shown to be saved: then nothing is sent (M6).
    func save(_ date: Date, scope: String) throws
}

/// The record in the gate's UserDefaults suite, read back after it is written.
struct DefaultsMissingAlbumSearchStore: MissingAlbumSearchStore, @unchecked Sendable {
    struct NotSaved: Error {}

    let defaults: UserDefaults

    func last(scope: String) -> Date? { defaults.object(forKey: MissingAlbumSearch.recordKey(scope: scope)) as? Date }

    func save(_ date: Date, scope: String) throws {
        defaults.set(date, forKey: MissingAlbumSearch.recordKey(scope: scope))
        guard last(scope: scope) == date else { throw NotSaved() }
    }
}
