#if os(iOS)
import Foundation
import MagpieCore
import MediaPlayer
import Observation
import UIKit

/// Mirrors `Player` into the system's Now Playing surfaces (lock screen, Control Center, CarPlay)
/// and routes remote commands back to it.
@MainActor
public final class NowPlayingBridge {
    private let player: Player
    private let artworkURL: (Song) -> URL?
    private let onLike: (Song) -> Void
    private var artwork: (coverArtId: String, artwork: MPMediaItemArtwork)?
    private var artworkTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    /// Values that, when changed, republish Now Playing info. Elapsed time is sent at whole seconds;
    /// the system extrapolates in between from the rate.
    private struct Snapshot: Equatable, Sendable {
        var entryId: UUID?
        var isPlaying: Bool
        var duration: TimeInterval?
        var second: Int
        var upcomingCount: Int
    }

    public init(player: Player, artworkURL: @escaping (Song) -> URL?, onLike: @escaping (Song) -> Void) {
        self.player = player
        self.artworkURL = artworkURL
        self.onLike = onLike
        registerCommands()
        observation = Task { [weak self, player] in
            var last: Snapshot?
            let snapshots = Observations { @MainActor in
                Snapshot(entryId: player.queue.current?.id, isPlaying: player.isPlaying, duration: player.duration,
                         second: Int(player.position), upcomingCount: player.queue.upcoming.count)
            }
            for await snapshot in snapshots where snapshot != last {
                guard let self else { return }
                let entryChanged = snapshot.entryId != last?.entryId
                last = snapshot
                self.publish(loadArtwork: entryChanged)
            }
        }
    }

    /// Removes remote-command handlers and clears Now Playing.
    public func invalidate() {
        observation?.cancel()
        artworkTask?.cancel()
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Now Playing info

    private func publish(loadArtwork: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        guard let entry = player.queue.current else {
            center.nowPlayingInfo = nil
            return
        }
        let song = entry.song
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration = player.duration ?? (song.duration > 0 ? song.duration : nil) {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let index = player.queue.currentIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = index + 1 + player.queue.upcoming.count
        }
        if let art = artwork, art.coverArtId == song.coverArtId {
            info[MPMediaItemPropertyArtwork] = art.artwork
        }
        center.nowPlayingInfo = info
        MPRemoteCommandCenter.shared().likeCommand.isActive = song.starred
        if loadArtwork { fetchArtwork(for: song) }
    }

    private func fetchArtwork(for song: Song) {
        guard let id = song.coverArtId, artwork?.coverArtId != id, let url = artworkURL(song) else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await Self.artworkSession.data(from: url),
                  let image = UIImage(data: data), !Task.isCancelled, let self else { return }
            self.artwork = (id, Self.makeArtwork(image))
            if self.player.queue.current?.song.coverArtId == id { self.publish(loadArtwork: false) }
        }
    }

    /// Artwork URLs carry server auth in the query: no disk cache, no shared session.
    public nonisolated static let artworkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// MediaPlayer calls the artwork handler off the main thread (lock screen, CarPlay). Built in
    /// a nonisolated context so the closure is not main-actor-isolated (which would trap there).
    public nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: - Remote commands

    private func registerCommands() {
        let c = MPRemoteCommandCenter.shared()
        add(c.playCommand) { p, _ in if !p.isPlaying { p.toggle() } }
        add(c.pauseCommand) { p, _ in if p.isPlaying { p.toggle() } }
        add(c.togglePlayPauseCommand) { p, _ in p.toggle() }
        add(c.nextTrackCommand) { p, _ in p.next() }
        add(c.previousTrackCommand) { p, _ in p.previous() }
        add(c.changePlaybackPositionCommand) { p, position in
            if let position { p.seek(position) }
        }
        add(c.likeCommand) { [weak self] p, _ in
            guard let song = p.queue.current?.song else { return }
            self?.onLike(song)
        }
    }

    /// Registers a handler that runs on the main actor. `position` carries the target time for
    /// `changePlaybackPositionCommand`.
    private func add(_ command: MPRemoteCommand,
                     _ action: @escaping @Sendable @MainActor (Player, TimeInterval?) -> Void) {
        command.isEnabled = true
        let target = command.addTarget(handler: Self.commandHandler(player: player, action: action))
        commandTargets.append((command, target))
    }

    /// Built in a nonisolated context: MediaPlayer may invoke command handlers off the main
    /// thread, so the closure must not be main-actor-isolated. It hops to the main actor itself.
    nonisolated static func commandHandler(
        player: Player, action: @escaping @Sendable @MainActor (Player, TimeInterval?) -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            if Thread.isMainThread {
                MainActor.assumeIsolated { action(player, position) }
            } else {
                Task { @MainActor in action(player, position) }
            }
            return .success
        }
    }
}
#endif
