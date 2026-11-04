import Foundation

/// Round 14 A2 (D85): one song's 30-second preview, as the preview player sees it. Not a `Song`: it never reaches the
/// main queue, the scrobbler, play counts, Finds watching or the cache.
public struct PreviewItem: Sendable, Hashable, Identifiable {
    /// The row's own key (stable for the list it belongs to).
    public let id: String
    /// The preview to resolve (Aurral's Deezer track id); nil: this song has no preview ("No preview available").
    public let previewId: String?
    public var title: String
    public var artist: String
    public var album: String?
    public var artworkURL: URL?

    public init(id: String, previewId: String?, title: String, artist: String, album: String? = nil,
                artworkURL: URL? = nil) {
        self.id = id
        self.previewId = previewId
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
    }
}

/// What resolving a preview gave, just before it plays (D87).
public enum PreviewLookup: Sendable, Equatable {
    /// The clip to play now, as Aurral sent it (A7: never a link to Deezer); held only while it plays.
    case playable(Data)
    /// There is no preview for this song (404): "No preview available".
    case noPreview
    /// It couldn't be resolved right now (5xx, a timeout, a refused answer, no Aurral): "Preview unavailable right now".
    case unavailable
}

/// What a preview engine reports back. Every event about a clip carries the token it was loaded with, so one about a
/// clip replaced since is dropped.
public enum PreviewEngineEvent: Sendable, Equatable {
    /// The clip is loaded and playing.
    case started(token: Int)
    case time(token: Int, TimeInterval, duration: TimeInterval?)
    case ended(token: Int)
    /// The clip couldn't be played (bytes that aren't audio, a player that wouldn't start).
    case failed(token: Int)
    /// The system took the audio (a call): the clip is paused.
    case interrupted
    /// The interruption ended; resume only when the system recommends it.
    case resumption(shouldResume: Bool)
    /// The audio route went away (headphones unplugged): the clip is paused, and nothing resumes it by itself.
    case routeLost
    /// The system's media services restarted: the engine's player is gone.
    case mediaServicesReset
}

/// Plays one preview clip at a time. `PreviewPlayer` owns the list; the engine only sees the clip's bytes and a token.
@MainActor
public protocol PreviewEngine: AnyObject {
    var events: AsyncStream<PreviewEngineEvent> { get }
    /// Plays `clip` (the bytes Aurral sent, kept in memory only) from `at` seconds, replacing whatever was loaded.
    func load(_ clip: Data, token: Int, at: TimeInterval)
    func pause()
    func resume()
    /// Stops and lets go of the clip (its bytes too).
    func stop()
}

/// A remote command (lock screen, Control Center, CarPlay, headphones) the preview may take while it plays.
public enum PreviewRemoteCommand: Sendable, Equatable {
    case play, pause, togglePlayPause, nextTrack, previousTrack, seek(TimeInterval), like, shuffle, repeatMode
}
