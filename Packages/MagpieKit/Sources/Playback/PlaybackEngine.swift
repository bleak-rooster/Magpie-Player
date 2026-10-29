import Foundation
import MagpieCore

/// What an engine reports back to `Player`.
public enum EngineEvent: Sendable, Equatable {
    /// The engine moved on to the item with this id (gapless auto-advance or after `setItems`/`next`).
    case itemChanged(UUID)
    /// Playback position of the item with this id; `duration` is nil while unknown (e.g. live
    /// transcodes). Carries the id so a tick buffered from the previous item can be dropped.
    case time(UUID, TimeInterval, duration: TimeInterval?)
    case stalled
    case failed(UUID, String)
    /// The last item the engine holds finished: the entry with this id. `Player` drops one about a list it has since
    /// replaced (a stale end that would otherwise skip songs).
    case ended(UUID)
    /// The engine started or stopped on its own (audio interruption, headphones unplugged).
    case playing(Bool)
}

/// Plays a list of stream URLs. `Player` owns the queue; the engine only sees `(entry id, url)` pairs.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var events: AsyncStream<EngineEvent> { get }
    /// Replaces the engine's list. If the item at `startAt` has the same id *and* URL as the item
    /// playing now, it keeps playing uninterrupted and only the items after it are replaced;
    /// otherwise the engine loads it from the start.
    func setItems(_ urls: [(UUID, URL)], startAt: Int)
    func play()
    func pause()
    func seek(to: TimeInterval)
    func next()
    /// Per-entry volume (ReplayGain), keyed by entry id; applied when an item is enqueued.
    func setVolumes(_ volumes: [UUID: Float])
    /// Overall volume (the sleep timer's fade), on top of the per-entry volumes.
    func setVolume(_ volume: Float)
    /// The URL the engine actually holds for this entry, if it has it enqueued. An enqueued item is kept when
    /// only its URL changed, so this can differ from the URL last sent; nil when unknown.
    func enqueuedURL(for id: UUID) -> URL?
}

public extension PlaybackEngine {
    func setVolumes(_ volumes: [UUID: Float]) {}
    func setVolume(_ volume: Float) {}
    func enqueuedURL(for id: UUID) -> URL? { nil }
}

/// Records a play with the server. Sendable so `Player` can call it off the main actor.
public protocol Scrobbler: Sendable {
    func scrobble(songId: String, submission: Bool, at: Date?) async throws
}

/// Builds the URL to stream a song from, against whichever server address is active right now.
@MainActor
public protocol StreamURLProvider: AnyObject {
    func streamURL(for song: Song) -> URL
    /// The song untranscoded, for when the server fails to convert it. Nil whenever the song can't be fetched from
    /// the server right now (a local file; offline from Task 14): `Player` tries this fallback before skipping an
    /// unplayable song, so a non-nil answer offline wastes a try.
    func originalURL(for song: Song) -> URL?
    /// Whether `url` already streams the song untranscoded. `Player` takes the fallback only when the URL the song
    /// loaded with isn't original, so a session re-login (new auth salt in the URL) doesn't cause a pointless
    /// fallback and a false hint (an `originalURL` equal to the loaded URL is never a fallback either).
    func isOriginal(_ url: URL) -> Bool
}

public extension StreamURLProvider {
    func originalURL(for song: Song) -> URL? { nil }
    func isOriginal(_ url: URL) -> Bool { false }
}
