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
    /// The like button's state for a song: the app's star state (with its unsaved flips), observed.
    private let isLiked: (Song) -> Bool
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
        var isShuffled: Bool
        var repeatMode: RepeatMode
        var liked: Bool
    }

    public init(player: Player, artworkURL: @escaping (Song) -> URL?, onLike: @escaping (Song) -> Void,
                isLiked: @escaping (Song) -> Bool = { $0.starred }) {
        self.player = player
        self.artworkURL = artworkURL
        self.onLike = onLike
        self.isLiked = isLiked
        registerCommands()
        observation = Task { [weak self, player, isLiked] in
            var last: Snapshot?
            let snapshots = Observations { @MainActor in
                Snapshot(entryId: player.queue.current?.id, isPlaying: player.isPlaying, duration: player.duration,
                         second: NowPlayingBridge.wholeSeconds(player.position), upcomingCount: player.queue.upcomingCount,
                         isShuffled: player.isShuffled, repeatMode: player.repeatMode,
                         liked: player.queue.current.map { isLiked($0.song) } ?? false)
            }
            for await snapshot in snapshots where snapshot != last {
                guard let self else { return }
                let entryChanged = snapshot.entryId != last?.entryId
                last = snapshot
                self.publish(loadArtwork: entryChanged)
            }
        }
    }

    /// Whole seconds of a position, for the republish check; 0 for NaN or infinity, which `Int(_:)` traps on.
    public nonisolated static func wholeSeconds(_ t: TimeInterval) -> Int {
        guard t.isFinite else { return 0 }
        return Int(min(max(t, -1e9), 1e9))
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
        Self.syncModes(of: player)
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
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position.isFinite ? player.position : 0,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration = player.duration ?? (song.duration > 0 ? song.duration : nil) {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let index = player.queue.currentIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = index + 1 + player.queue.upcomingCount
        }
        if let art = artwork, art.coverArtId == song.coverArtId {
            info[MPMediaItemPropertyArtwork] = art.artwork
        }
        center.nowPlayingInfo = info
        MPRemoteCommandCenter.shared().likeCommand.isActive = isLiked(song)
        if loadArtwork { fetchArtwork(for: song) }
    }

    private func fetchArtwork(for song: Song) {
        guard let id = song.coverArtId, artwork?.coverArtId != id, let url = artworkURL(song) else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await Self.artworkSession.data(from: url, delegate: SameOriginRedirects.shared),
                  let image = UIImage(data: data), !Task.isCancelled, let self else { return }
            self.artwork = (id, Self.makeArtwork(image))
            if self.player.queue.current?.song.coverArtId == id { self.publish(loadArtwork: false) }
        }
    }

    /// Artwork URLs carry server auth in the query: no disk cache, no shared session, and no redirect to
    /// another origin (security M1).
    public nonisolated static let artworkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return SameOriginRedirects.session(configuration: config)
    }()

    /// MediaPlayer calls the artwork handler off the main thread (lock screen, CarPlay). Built in
    /// a nonisolated context so the closure is not main-actor-isolated (which would trap there).
    public nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: - Shuffle and repeat

    /// Shuffle from a remote command or a CarPlay button: any shuffle type but `.off` turns it on.
    public static func applyShuffle(_ type: MPShuffleType, to player: Player) {
        player.setShuffled(type != .off)
        syncModes(of: player)
    }

    public static func applyRepeat(_ type: MPRepeatType, to player: Player) {
        player.repeatMode = repeatMode(type)
        syncModes(of: player)
    }

    public nonisolated static func repeatType(_ mode: RepeatMode) -> MPRepeatType {
        switch mode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }

    public nonisolated static func repeatMode(_ type: MPRepeatType) -> RepeatMode {
        switch type {
        case .one: .one
        case .all: .all
        default: .off
        }
    }

    /// Handlers for `changeShuffleModeCommand` / `changeRepeatModeCommand` (exposed for tests).
    public static let shuffleCommandAction: @Sendable @MainActor (Player, CommandInput) -> Void = { p, input in
        if case .shuffle(let type) = input { applyShuffle(type, to: p) }
    }
    public static let repeatCommandAction: @Sendable @MainActor (Player, CommandInput) -> Void = { p, input in
        if case .repeatMode(let type) = input { applyRepeat(type, to: p) }
    }

    /// The system draws the shuffle and repeat buttons (lock screen, CarPlay) from these.
    public static func syncModes(of player: Player) {
        let commands = MPRemoteCommandCenter.shared()
        commands.changeShuffleModeCommand.currentShuffleType = player.isShuffled ? .items : .off
        commands.changeRepeatModeCommand.currentRepeatType = repeatType(player.repeatMode)
    }

    // MARK: - Remote commands

    private func registerCommands() {
        let c = MPRemoteCommandCenter.shared()
        add(c.playCommand) { p, _ in if !p.isPlaying { p.toggle() } }
        add(c.pauseCommand) { p, _ in if p.isPlaying { p.toggle() } }
        add(c.togglePlayPauseCommand) { p, _ in p.toggle() }
        add(c.nextTrackCommand) { p, _ in p.next() }
        add(c.previousTrackCommand) { p, _ in p.previous() }
        add(c.changePlaybackPositionCommand) { p, input in
            if case .position(let t) = input { p.seek(t) }
        }
        add(c.changeShuffleModeCommand, Self.shuffleCommandAction)
        add(c.changeRepeatModeCommand, Self.repeatCommandAction)
        add(c.likeCommand) { [weak self] p, _ in
            guard let song = p.queue.current?.song else { return }
            self?.onLike(song)
        }
    }

    /// What a remote command event carries, copied out so it can cross to the main actor.
    public enum CommandInput: Sendable, Equatable {
        case none
        case position(TimeInterval)
        case shuffle(MPShuffleType)
        case repeatMode(MPRepeatType)

        public nonisolated init(_ event: MPRemoteCommandEvent) {
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self = .position(e.positionTime)
            } else if let e = event as? MPChangeShuffleModeCommandEvent {
                self = .shuffle(e.shuffleType)
            } else if let e = event as? MPChangeRepeatModeCommandEvent {
                self = .repeatMode(e.repeatType)
            } else {
                self = .none
            }
        }
    }

    /// Registers a handler that runs on the main actor with the event's input.
    private func add(_ command: MPRemoteCommand,
                     _ action: @escaping @Sendable @MainActor (Player, CommandInput) -> Void) {
        command.isEnabled = true
        let target = command.addTarget(handler: Self.commandHandler(player: player, action: action))
        commandTargets.append((command, target))
    }

    /// Built in a nonisolated context: MediaPlayer may invoke command handlers off the main
    /// thread, so the closure must not be main-actor-isolated. It hops to the main actor itself.
    nonisolated static func commandHandler(
        player: Player, action: @escaping @Sendable @MainActor (Player, CommandInput) -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            let input = CommandInput(event)
            if Thread.isMainThread {
                MainActor.assumeIsolated { action(player, input) }
            } else {
                Task { @MainActor in action(player, input) }
            }
            return .success
        }
    }
}
#endif
