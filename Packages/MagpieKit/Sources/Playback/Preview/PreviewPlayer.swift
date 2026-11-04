import Foundation
import MagpieCore
import Observation

/// Round 14 A2 (D85–D87): plays 30-second previews of songs not in the library, one at a time or a list in order
/// ("Play previews"), on its own engine.
///
/// - It is not the main player: nothing it plays reaches the queue, the scrobbler, play counts, Finds watching or the
///   cache (it has none of them).
/// - Hand-off (D86): starting a preview pauses the main player when it is playing; when previews stop (Stop, the end of
///   the list, a failure) the main player stays paused and `offersResume` says so, for the mini player's Resume. The
///   main player starting by any other way stops the preview.
/// - Every play resolves the preview just before it plays (`lookup`: the clip Aurral sends); no clip is kept. A play
///   that fails is resolved again once, from where it was; a second failure is final.
@MainActor @Observable
public final class PreviewPlayer {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Resolving or fetching the current clip.
        case loading
        case playing
        case paused
        /// The last clip asked for has no preview.
        case noPreview
        /// The last clip asked for couldn't be played right now.
        case unavailable
    }

    /// What one item's preview button shows.
    public enum ItemState: Sendable, Equatable {
        case ready
        case loading
        case playing(progress: Double)
        case paused(progress: Double)
        case noPreview
        case unavailable
    }

    /// A preview is at most this long (Deezer's are 30 s); a clip that runs on is cut here.
    public static let clipLength: TimeInterval = 30
    /// `previous()` restarts the clip once it has played longer than this.
    static let restartThreshold: TimeInterval = 3

    public private(set) var items: [PreviewItem] = []
    public private(set) var index: Int?
    public private(set) var phase = Phase.idle
    public private(set) var position: TimeInterval = 0
    /// The clip's own length when shorter than 30 s.
    public private(set) var clipDuration: TimeInterval = PreviewPlayer.clipLength
    /// Items found this session to have no preview (by item id): their buttons show "No preview available".
    public private(set) var noPreviewIds: Set<String> = []
    /// The item whose preview couldn't be played right now, until another plays.
    public private(set) var unavailableId: String?
    /// The main player was playing when a preview started, and hasn't played since.
    public private(set) var pausedMainPlayer = false

    /// Resolves a preview id just before it plays. The app sets it (Aurral's `PreviewResolver`); until then nothing
    /// resolves.
    @ObservationIgnored public var lookup: @MainActor (String) async -> PreviewLookup = { _ in .unavailable }

    @ObservationIgnored private let engine: any PreviewEngine
    @ObservationIgnored private weak var mainPlayer: Player?
    /// Bumped by every load and stop: engine events and resolves for an older token are dropped.
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var resolving: Task<Void, Never>?
    /// The current clip was already resolved again after a failure.
    @ObservationIgnored private var retried = false
    /// Paused by an interruption (a call), not by the owner: a resumption recommendation may start it again.
    @ObservationIgnored private var pausedByInterruption = false
    /// The engine reported the current clip started (fix I2: until then a pause is held and applied when it starts).
    @ObservationIgnored private var clipStarted = false
    @ObservationIgnored private var watches: [Task<Void, Never>] = []

    public init(engine: any PreviewEngine, mainPlayer: Player?) {
        self.engine = engine
        self.mainPlayer = mainPlayer
        let events = engine.events
        watches.append(Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        })
        if let mainPlayer {
            watches.append(Task { [weak self, mainPlayer] in
                let playing = Observations { @MainActor in mainPlayer.isPlaying }
                for await isPlaying in playing where isPlaying {
                    guard let self else { return }
                    self.mainPlayerStarted()
                }
            })
        }
    }

    isolated deinit {
        for watch in watches { watch.cancel() }
        resolving?.cancel()
    }

    // MARK: - State

    public var current: PreviewItem? { index.flatMap { items.indices.contains($0) ? items[$0] : nil } }

    /// A preview is loading, playing or paused (the mini player shows it, remote commands go to it).
    public var isActive: Bool { phase == .loading || phase == .playing || phase == .paused }

    /// The ring: how much of the clip has played, 0...1.
    public var progress: Double {
        let length = max(min(clipDuration, Self.clipLength), 1)
        let p = position / length
        return p.isFinite ? min(max(p, 0), 1) : 0
    }

    /// Whole seconds left of the clip.
    public var remaining: Int {
        let length = min(clipDuration, Self.clipLength)
        let left = (length - position).rounded(.up)
        return left.isFinite ? Int(min(max(left, 0), Self.clipLength)) : 0
    }

    /// The mini player offers Resume: previews paused the main player, they have stopped, and it is still paused.
    public var offersResume: Bool {
        guard pausedMainPlayer, !isActive, let mainPlayer else { return false }
        return !mainPlayer.isPlaying && mainPlayer.queue.current != nil
    }

    public func state(for item: PreviewItem) -> ItemState {
        if item.previewId == nil || noPreviewIds.contains(item.id) { return .noPreview }
        if current?.id == item.id {
            switch phase {
            case .loading: return .loading
            case .playing: return .playing(progress: progress)
            case .paused: return .paused(progress: progress)
            case .noPreview: return .noPreview
            case .unavailable: return .unavailable
            case .idle: break
            }
        }
        return unavailableId == item.id ? .unavailable : .ready
    }

    // MARK: - Transport

    /// Plays `items` in order from `startAt`, 30 seconds each ("Play previews").
    public func play(_ items: [PreviewItem], startAt: Int = 0) {
        guard items.indices.contains(startAt) else { return }
        claimMainPlayer()
        self.items = items
        index = startAt
        startCurrent()
    }

    /// A preview button: stops this item's preview when it is the one previewing, otherwise plays it alone.
    public func toggle(_ item: PreviewItem) {
        if current?.id == item.id, isActive {
            stop()
        } else {
            play([item])
        }
    }

    public func pause() {
        guard phase == .playing || phase == .loading else { return }
        pausedByInterruption = false
        engine.pause()
        phase = .paused
    }

    public func resume() {
        guard phase == .paused else { return }
        pausedByInterruption = false
        claimMainPlayer()
        engine.resume()
        phase = clipStarted ? .playing : .loading
    }

    public func next() {
        guard isActive, let index else { return }
        if index + 1 < items.count {
            self.index = index + 1
            startCurrent()
        } else {
            stop()
        }
    }

    /// Back to the previous clip, or the start of this one once it has played a few seconds.
    public func previous() {
        guard isActive, let index else { return }
        if position <= Self.restartThreshold, index > 0 { self.index = index - 1 }
        startCurrent()
    }

    /// Stops previewing. The main player stays as it is (paused).
    public func stop() {
        cancelLoad()
        engine.stop()
        items = []
        index = nil
        phase = .idle
        position = 0
        clipDuration = Self.clipLength
    }

    /// The mini player's Resume: previews stop and the main player plays on.
    public func resumeMain() {
        if isActive { stop() }
        pausedMainPlayer = false
        if let mainPlayer, !mainPlayer.isPlaying { mainPlayer.toggle() }
    }

    /// A remote command while a preview is loading, playing or paused: the preview takes it (true). Seeking and
    /// Favourite are swallowed. Otherwise false, and the main player takes it.
    public func handleRemote(_ command: PreviewRemoteCommand) -> Bool {
        guard isActive else { return false }
        switch command {
        case .play: resume()
        case .pause: pause()
        case .togglePlayPause: phase == .paused ? resume() : pause()
        case .nextTrack: next()
        case .previousTrack: previous()
        case .seek, .like, .shuffle, .repeatMode: break   // nothing to seek or favourite; the main queue isn't touched
        }
        return true
    }

    // MARK: - Engine events

    /// Applies one engine event (fed from the engine's stream; public so tests drive it deterministically).
    public func handle(_ event: PreviewEngineEvent) {
        switch event {
        case .started(let t):
            guard t == token, isActive else { return }
            clipStarted = true
            if phase == .paused {
                engine.pause()   // fix I2: paused (by the owner or a call) while it loaded: it stays paused
            } else {
                phase = .playing
            }
        case .time(let t, let seconds, let duration):
            guard t == token, phase == .playing, seconds.isFinite else { return }
            if let duration, duration.isFinite, duration > 1 { clipDuration = min(duration, Self.clipLength) }
            position = min(max(seconds, 0), Self.clipLength)
            if seconds >= Self.clipLength { clipEnded() }
        case .ended(let t):
            guard t == token, isActive else { return }
            clipEnded()
        case .failed(let t):
            guard t == token, isActive, let item = current else { return }
            if retried {
                becomeUnavailable(item)
            } else {
                retried = true
                resolveAndLoad(item, at: position)
            }
        case .interrupted:
            guard phase == .playing || phase == .loading else { return }
            phase = .paused
            pausedByInterruption = true
        case .resumption(let shouldResume):
            guard phase == .paused, pausedByInterruption else { return }
            pausedByInterruption = false
            if shouldResume {
                claimMainPlayer()
                engine.resume()
                phase = clipStarted ? .playing : .loading
            }
        case .routeLost:
            // Headphones unplugged: paused, and not by a call, so no recommendation resumes it out of the speaker.
            guard phase == .playing || phase == .loading else { return }
            engine.pause()
            phase = .paused
            pausedByInterruption = false
        case .mediaServicesReset:
            // The engine's player is gone: load the clip again (resolved afresh) from where it was, paused if it was.
            guard isActive, let item = current else { return }
            let wasPaused = phase == .paused
            resolveAndLoad(item, at: position)
            if wasPaused { phase = .paused }
        }
    }

    // MARK: - Internals

    /// Pauses the main player when it is playing, and remembers that previews did.
    private func claimMainPlayer() {
        guard let mainPlayer, mainPlayer.isPlaying else { return }
        mainPlayer.toggle()
        pausedMainPlayer = true
    }

    /// The main player started (the owner pressed play there, CarPlay, a song tapped): the preview stops.
    private func mainPlayerStarted() {
        pausedMainPlayer = false
        if isActive { stop() }
    }

    private func startCurrent() {
        guard let item = current else { return stop() }
        cancelLoad()
        engine.stop()
        position = 0
        clipDuration = Self.clipLength
        retried = false
        if unavailableId == item.id { unavailableId = nil }
        guard item.previewId != nil, !noPreviewIds.contains(item.id) else { return noPreview(item) }
        resolveAndLoad(item, at: 0)
    }

    /// Resolves the item's preview now (never a kept clip) and hands it to the engine from `at`.
    private func resolveAndLoad(_ item: PreviewItem, at: TimeInterval) {
        guard let previewId = item.previewId else { return noPreview(item) }
        token += 1
        let mine = token
        phase = .loading
        clipStarted = false
        resolving?.cancel()
        let lookup = self.lookup
        resolving = Task { [weak self] in
            let answer = await lookup(previewId)
            guard let self, !Task.isCancelled, mine == self.token, self.current?.id == item.id else { return }
            switch answer {
            case .playable(let clip) where !clip.isEmpty:
                self.engine.load(clip, token: mine, at: at)
            case .playable, .unavailable:
                self.becomeUnavailable(item)
            case .noPreview:
                self.noPreview(item)
            }
        }
    }

    /// No preview: in a list, on to the next song; alone (or the last), the button says "No preview available".
    private func noPreview(_ item: PreviewItem) {
        noPreviewIds.insert(item.id)
        if let index, index + 1 < items.count {
            self.index = index + 1
            startCurrent()
            return
        }
        cancelLoad()
        engine.stop()
        phase = .noPreview
    }

    /// Couldn't play right now: the run stops (the next song would most likely fail the same way).
    private func becomeUnavailable(_ item: PreviewItem) {
        cancelLoad()
        engine.stop()
        unavailableId = item.id
        phase = .unavailable
        position = 0
    }

    private func clipEnded() {
        guard let index, index + 1 < items.count else { return stop() }
        self.index = index + 1
        startCurrent()
    }

    private func cancelLoad() {
        token += 1
        resolving?.cancel()
        resolving = nil
        pausedByInterruption = false
    }
}
