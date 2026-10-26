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
    /// The last item finished.
    case ended
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
}

/// Records a play with the server. Sendable so `Player` can call it off the main actor.
public protocol Scrobbler: Sendable {
    func scrobble(songId: String, submission: Bool, at: Date?) async throws
}

/// Builds the URL to stream a song from, against whichever server address is active right now.
@MainActor
public protocol StreamURLProvider: AnyObject {
    func streamURL(for song: Song) -> URL
}
