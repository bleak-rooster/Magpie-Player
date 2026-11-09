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
    /// Round 14 A2 (D86): while a preview loads, plays or is paused, the lock screen shows it and the remote commands go
    /// to it; when it stops, the main player's info comes back.
    private let preview: PreviewPlayer?
    private let artworkURL: (Song) -> URL?
    /// The app's artwork, through its caches (P4); when given, `artworkURL` isn't used.
    private let artworkImage: (@MainActor (Song) async -> UIImage?)?
    private let onLike: (Song) -> Void
    /// The like button's state for a song: the app's star state (with its unsaved flips), observed.
    private let isLiked: (Song) -> Bool
    private var artwork: (coverArtId: String, artwork: MPMediaItemArtwork)?
    private var artworkTask: Task<Void, Never>?
    /// Round 15 C1 (owner item 4, D127): the preview's cover, through the app (its row's picture); nil: none.
    private let previewArtwork: (@MainActor (PreviewItem) async -> UIImage?)?
    private var previewArt: (itemId: String, artwork: MPMediaItemArtwork?)?
    private var previewArtTask: Task<Void, Never>?
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
        var preview: PreviewSnapshot?
    }

    /// What the lock screen shows of a preview.
    private struct PreviewSnapshot: Equatable, Sendable {
        var itemId: String
        var isPlaying: Bool
        var second: Int
    }

    public init(player: Player, artworkURL: @escaping (Song) -> URL?, onLike: @escaping (Song) -> Void,
                isLiked: @escaping (Song) -> Bool = { $0.starred },
                artworkImage: (@MainActor (Song) async -> UIImage?)? = nil,
                previewArtwork: (@MainActor (PreviewItem) async -> UIImage?)? = nil, preview: PreviewPlayer? = nil) {
        self.player = player
        self.preview = preview
        self.previewArtwork = previewArtwork
        self.artworkURL = artworkURL
        self.artworkImage = artworkImage
        self.onLike = onLike
        self.isLiked = isLiked
        registerCommands()
        observation = Task { [weak self, player, preview, isLiked] in
            var last: Snapshot?
            let snapshots = Observations { @MainActor in
                Snapshot(entryId: player.queue.current?.id, isPlaying: player.isPlaying, duration: player.duration,
                         second: NowPlayingBridge.wholeSeconds(player.position), upcomingCount: player.queue.upcomingCount,
                         isShuffled: player.isShuffled, repeatMode: player.repeatMode,
                         liked: player.queue.current.map { isLiked($0.song) } ?? false,
                         preview: NowPlayingBridge.previewSnapshot(preview))
            }
            for await snapshot in snapshots where snapshot != last {
                guard let self else { return }
                // Back from a preview: the main song's artwork is published again too.
                let entryChanged = snapshot.entryId != last?.entryId || (snapshot.preview == nil && last?.preview != nil)
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
        previewArtTask?.cancel()
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Now Playing info

    private static func previewSnapshot(_ preview: PreviewPlayer?) -> PreviewSnapshot? {
        guard let preview, preview.isActive, let item = preview.current else { return nil }
        return PreviewSnapshot(itemId: item.id, isPlaying: preview.phase == .playing, second: wholeSeconds(preview.position))
    }

    /// The Now Playing info of the preview playing: its title and artist, 30 seconds long. The bridge adds its cover once
    /// the app has it (C1, D127).
    public static func previewInfo(_ preview: PreviewPlayer) -> [String: Any]? {
        guard preview.isActive, let item = preview.current else { return nil }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPMediaItemPropertyPlaybackDuration: min(preview.clipDuration, PreviewPlayer.clipLength),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: preview.position.isFinite ? preview.position : 0,
            MPNowPlayingInfoPropertyPlaybackRate: preview.phase == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let index = preview.index {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = preview.items.count
        }
        return info
    }

    private func publish(loadArtwork: Bool) {
        Self.syncModes(of: player)
        let center = MPNowPlayingInfoCenter.default()
        if let preview, var info = Self.previewInfo(preview), let item = preview.current {
            // C1 (D127): the preview's cover (its row's picture), once the app has it; loaded once per preview.
            if previewArt?.itemId == item.id {
                if let artwork = previewArt?.artwork { info[MPMediaItemPropertyArtwork] = artwork }
            } else {
                fetchPreviewArtwork(for: item)
            }
            center.nowPlayingInfo = info
            MPRemoteCommandCenter.shared().likeCommand.isActive = false
            return
        }
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

    private func fetchPreviewArtwork(for item: PreviewItem) {
        previewArtTask?.cancel()
        previewArt = (item.id, nil)
        guard let previewArtwork, item.artworkKey != nil else { return }
        previewArtTask = Task { [weak self] in
            guard let image = await previewArtwork(item), !Task.isCancelled, let self, self.previewArt?.itemId == item.id
            else { return }
            self.previewArt = (item.id, Self.makeArtwork(image))
            if self.preview?.current?.id == item.id { self.publish(loadArtwork: false) }
        }
    }

    private func fetchArtwork(for song: Song) {
        guard let id = song.coverArtId, artwork?.coverArtId != id else { return }
        if let artworkImage {   // the app's caches: a cached cover costs no request, and shows offline
            artworkTask?.cancel()
            artworkTask = Task { [weak self] in
                guard let image = await artworkImage(song), !Task.isCancelled, let self else { return }
                self.artwork = (id, Self.makeArtwork(image))
                if self.player.queue.current?.song.coverArtId == id { self.publish(loadArtwork: false) }
            }
            return
        }
        guard let url = artworkURL(song) else { return }
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
        let preview = self.preview
        add(c.playCommand) { p, _ in if !Self.previewTakes(.play, preview), !p.isPlaying { p.toggle() } }
        add(c.pauseCommand) { p, _ in if !Self.previewTakes(.pause, preview), p.isPlaying { p.toggle() } }
        add(c.togglePlayPauseCommand) { p, _ in if !Self.previewTakes(.togglePlayPause, preview) { p.toggle() } }
        add(c.nextTrackCommand) { p, _ in if !Self.previewTakes(.nextTrack, preview) { p.next() } }
        add(c.previousTrackCommand) { p, _ in if !Self.previewTakes(.previousTrack, preview) { p.previous() } }
        add(c.changePlaybackPositionCommand) { p, input in
            if case .position(let t) = input, !Self.previewTakes(.seek(t), preview) { p.seek(t) }
        }
        // Fix round 1: during a preview, shuffle and repeat don't change the hidden main queue.
        add(c.changeShuffleModeCommand) { p, input in
            if !Self.previewTakes(.shuffle, preview) { Self.shuffleCommandAction(p, input) }
        }
        add(c.changeRepeatModeCommand) { p, input in
            if !Self.previewTakes(.repeatMode, preview) { Self.repeatCommandAction(p, input) }
        }
        add(c.likeCommand) { [weak self] p, _ in
            guard !Self.previewTakes(.like, preview), let song = p.queue.current?.song else { return }
            self?.onLike(song)
        }
    }

    /// Round 14 A2: a preview loading, playing or paused takes the command; otherwise the main player does.
    public static func previewTakes(_ command: PreviewRemoteCommand, _ preview: PreviewPlayer?) -> Bool {
        preview?.handleRemote(command) ?? false
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
        { event in dispatch(CommandInput(event), player: player, action: action) }
    }

    /// Runs a command's action on the main actor: at once on the main thread, otherwise by a hop. Round 24 G (D234):
    /// split out of `commandHandler` so tests can send a command from either thread without a MediaPlayer event.
    nonisolated static func dispatch(
        _ input: CommandInput, player: Player, action: @escaping @Sendable @MainActor (Player, CommandInput) -> Void
    ) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            MainActor.assumeIsolated { action(player, input) }
        } else {
            Task { @MainActor in action(player, input) }
        }
        return .success
    }

    /// The commands this bridge has a handler on, one entry per handler (Round 24 G, D234: tests check each is
    /// registered once and that `invalidate` removes them).
    var registeredCommands: [MPRemoteCommand] { commandTargets.map(\.0) }
}
#endif
