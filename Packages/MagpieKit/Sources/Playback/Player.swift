import Foundation
import MagpieCore
import Observation

/// What happens when the queue (or, for `.one`, the current song) ends.
public enum RepeatMode: String, Sendable, Hashable, Codable, CaseIterable {
    case off, all, one

    /// The next mode when the repeat button is tapped: off, all, one, off.
    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// The app's single player: owns the queue, drives a `PlaybackEngine`, and scrobbles.
///
/// The engine always holds `[current] + upcoming`, starting at index 0. Any queue edit re-sends
/// that list; the engine keeps the current item playing when its id and URL are unchanged.
@MainActor @Observable
public final class Player {
    public private(set) var queue = PlayQueue()
    public private(set) var isPlaying = false
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval?
    /// Repeat is in-memory: a new launch starts with it off.
    public var repeatMode: RepeatMode = .off {
        // Repeat one holds back the upcoming items (no gapless prefetch of the next song), so
        // switching into or out of it re-sends the engine's list.
        didSet { if oldValue != repeatMode, queue.current != nil { syncEngine() } }
    }
    public private(set) var isShuffled = false
    /// Last playback error for the current entry, if any (cleared when a new entry starts).
    public private(set) var lastError: String?
    /// The current song played to its end and nothing followed (final fix 2 B-M3): it was heard, so whatever jumps
    /// past it doesn't put it back. Cleared when it plays again, is sought or another song starts.
    public private(set) var hasEnded = false

    /// Scrobble at 50 % of the track or this many seconds, whichever comes first.
    static let scrobbleCap: TimeInterval = 240
    /// `previous()` restarts the current song once it has played longer than this.
    static let restartThreshold: TimeInterval = 3

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private let scrobbler: any Scrobbler
    @ObservationIgnored private let urls: any StreamURLProvider
    @ObservationIgnored private let isFind: (Song) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var playback: TrackPlayback?
    /// The engine stopped on its own (end of list, or the current entry failed); resuming or
    /// skipping reloads the engine instead of relying on what it still holds.
    @ObservationIgnored private var needsReload = false
    /// The current entry failed; engine item changes are ignored until the user acts.
    @ObservationIgnored private var failedEntryId: UUID?
    /// `main` order before shuffle was switched on, so switching it off can put it back.
    @ObservationIgnored private var unshuffledOrder: [UUID]?
    @ObservationIgnored private var pendingScrobbles: [UUID: Task<Void, Never>] = [:]

    /// Scrobble bookkeeping for the entry that is playing.
    private struct TrackPlayback {
        var entryId: UUID
        var startedAt: Date
        var submitted = false
    }

    public init(engine: any PlaybackEngine, scrobbler: any Scrobbler, urls: any StreamURLProvider,
                isFind: @escaping (Song) -> Bool = { _ in false },
                now: @escaping () -> Date = { Date() }) {
        self.engine = engine
        self.scrobbler = scrobbler
        self.urls = urls
        self.isFind = isFind
        self.now = now
        let events = engine.events
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: - Transport

    public func play(_ songs: [Song], startAt: Int) {
        queue.replace(with: songs, startAt: startAt)
        isShuffled = false
        unshuffledOrder = nil
        loadCurrent()
        resume()
    }

    public func toggle() {
        if isPlaying {
            engine.pause()
            isPlaying = false
        } else {
            resume()
        }
    }

    public func next() {
        guard queue.advance() != nil else {
            if repeatMode == .all, queue.wrapToStart() != nil {
                needsReload = true
                resume()
            }
            return
        }
        if needsReload {
            loadCurrent()
            return
        }
        // The engine already holds the old upcoming list, whose head is the new current entry.
        engine.next()
        beginEntry()
    }

    public func previous() {
        if position > Self.restartThreshold || queue.back() == nil {
            seek(0)
            return
        }
        loadCurrent()
    }

    public func seek(_ t: TimeInterval) {
        hasEnded = false
        engine.seek(to: t)
        position = t
    }

    // MARK: - Queue edits

    public func playNext(_ songs: [Song]) {
        let wasIdle = queue.current == nil
        queue.playNext(songs)
        wasIdle ? loadCurrent() : syncEngine()
    }

    public func addToEnd(_ songs: [Song]) {
        let wasIdle = queue.current == nil
        queue.addToEnd(songs)
        wasIdle ? loadCurrent() : syncEngine()
    }

    public func remove(id: UUID) {
        let current = queue.current?.id
        queue.remove(id: id)
        if queue.current?.id != current {
            loadCurrent()
        } else {
            syncEngine()
        }
    }

    /// Not for me (Task 6.2c): the songs leave the queue wherever they are. Playing one of them: the next song
    /// loads (nothing left: the engine stops); otherwise the current song plays on.
    public func removeSongs(_ songIds: Set<String>) {
        let current = queue.current?.id
        guard queue.removeSongs(songIds) else { return }
        if queue.current?.id != current {
            loadCurrent()
        } else {
            syncEngine()
        }
    }

    public func move(id: UUID, to index: Int) {
        queue.move(id: id, to: index)
        syncEngine()
    }

    public func shuffle(seed: UInt64 = .random(in: .min ... .max)) {
        queue.shuffle(seed: seed)
        syncEngine()
    }

    /// Shuffle on/off. On shuffles `main` (current stays first); off restores the order it had.
    public func setShuffled(_ on: Bool, seed: UInt64 = .random(in: .min ... .max)) {
        guard on != isShuffled else { return }
        if on {
            unshuffledOrder = queue.main.map(\.id)
            queue.shuffle(seed: seed)
        } else if let order = unshuffledOrder {
            queue.restoreOrder(order)
            unshuffledOrder = nil
        }
        isShuffled = on
        syncEngine()
    }

    /// Clears everything after the current song; the current song keeps playing.
    public func clearUpcoming() {
        queue.clearUpcoming()
        syncEngine()
    }

    /// Keep (Task 6.2b): song `id` is now `song` (the library song a kept find became). The queue's slots are
    /// updated, so scrobbling sees the library song. When the id changed and the song is current or still to
    /// play, the engine's URLs are rebuilt and the current entry resumes where it was.
    public func replaceSong(id: String, with song: Song) {
        let pending = ([queue.current].compactMap { $0 } + queue.upcoming).contains { $0.song.id == id }
        guard queue.replaceSong(id: id, with: song), pending, song.id != id else { return }
        urlsInvalidated()
    }

    /// The active server address changed (failover): rebuild every URL the engine holds, from the
    /// current entry on, and resume the current entry where it was.
    public func urlsInvalidated() {
        guard queue.current != nil else { return }
        let resumeAt = position
        syncEngine()
        engine.seek(to: resumeAt)
    }

    // MARK: - Engine events

    /// Applies one engine event. The engine's event stream is fed here automatically; it is public
    /// so tests (and future engines) can drive the player deterministically.
    public func handle(_ event: EngineEvent) {
        switch event {
        case .itemChanged(let id):
            guard failedEntryId == nil, id != queue.current?.id else { return }
            guard queue.upcoming.contains(where: { $0.id == id }) else { return }
            if repeatMode == .one {
                // The engine moved on by itself; put the same song back on from the start.
                loadCurrent()
                engine.play()
                isPlaying = true
                return
            }
            while queue.current?.id != id, queue.advance() != nil {}
            beginEntry()
        case .time(let id, let t, let d):
            guard id == queue.current?.id else { return }   // stale tick from the previous item
            position = t
            if let d { duration = d }
            maybeSubmitScrobble()
        case .stalled:
            break
        case .failed(let id, let message):
            // Only the current entry matters; the engine retries a failed upcoming item when it
            // is reached. Stop the engine too, so a dead server can't race through the queue.
            guard id == queue.current?.id else { return }
            lastError = message
            failedEntryId = id
            needsReload = true
            engine.pause()
            isPlaying = false
        case .ended:
            isPlaying = false
            needsReload = true
            switch repeatMode {
            case .off: hasEnded = true
            case .one: resume()
            case .all:
                queue.wrapToStart()
                resume()
            }
        case .playing(let playing):
            isPlaying = playing
        }
    }

    /// Waits for scrobble requests already started (tests; app suspension).
    public func waitForPendingScrobbles() async {
        while let task = pendingScrobbles.values.first {
            await task.value
        }
    }

    // MARK: - Internals

    private func resume() {
        guard queue.current != nil else { return }
        hasEnded = false
        if needsReload { loadCurrent() }
        engine.play()
        isPlaying = true
    }

    /// Sends `[current] + upcoming` with fresh URLs; an idle queue empties and stops the engine.
    private func syncEngine() {
        guard let current = queue.current else {
            engine.setItems([], startAt: 0)
            engine.pause()
            isPlaying = false
            return
        }
        let following = repeatMode == .one ? [] : queue.upcoming
        let items = ([current] + following).map { ($0.id, urls.streamURL(for: $0.song)) }
        engine.setItems(items, startAt: 0)
    }

    /// Loads the current entry from the start (the engine sees a different current item).
    private func loadCurrent() {
        syncEngine()
        beginEntry()
    }

    /// A new entry became current: reset position and scrobble state, send "now playing".
    private func beginEntry() {
        hasEnded = false
        needsReload = false
        failedEntryId = nil
        position = 0
        lastError = nil
        guard let entry = queue.current else {
            duration = nil
            playback = nil
            return
        }
        duration = entry.song.duration > 0 ? entry.song.duration : nil
        playback = TrackPlayback(entryId: entry.id, startedAt: now())
        scrobble(entry.song, submission: false, at: nil)
    }

    private func maybeSubmitScrobble() {
        guard var p = playback, !p.submitted, let entry = queue.current, entry.id == p.entryId else { return }
        let length = duration ?? entry.song.duration
        let threshold = length > 0 ? min(length / 2, Self.scrobbleCap) : Self.scrobbleCap
        guard position >= threshold else { return }
        p.submitted = true
        playback = p
        scrobble(entry.song, submission: true, at: p.startedAt)
    }

    private func scrobble(_ song: Song, submission: Bool, at: Date?) {
        // "Count plays" (G8) is the scrobbler's to check, so the app has one switch for it.
        guard !isFind(song) else { return }
        let key = UUID()
        let scrobbler = self.scrobbler
        let songId = song.id
        pendingScrobbles[key] = Task { [weak self] in
            do {
                try await scrobbler.scrobble(songId: songId, submission: submission, at: at)
            } catch {
                Log.logger("playback").error("scrobble failed: \(error.localizedDescription, privacy: .private)")
            }
            self?.pendingScrobbles[key] = nil
        }
    }
}
