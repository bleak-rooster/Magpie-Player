import MagpieCore
import os

/// The scrobbling preferences (Task 15), where the player and the scrobblers read them on every play. Written on the
/// main actor when the preference changes, so a new rule applies to the song that is playing.
final class ScrobbleSettings: Sendable {
    private let lock: OSAllocatedUnfairLock<ScrobblePreferences>
    init(_ p: ScrobblePreferences) { lock = OSAllocatedUnfairLock(initialState: p) }
    var value: ScrobblePreferences { lock.withLock { $0 } }
    func set(_ p: ScrobblePreferences) { lock.withLock { $0 = p } }
}
