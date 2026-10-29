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
/// The engine always holds `[current] + upcoming` (the upcoming entries that are playable), starting at
/// index 0. Any queue edit re-sends that list; the current entry keeps the URL it was loaded with, so the
/// engine keeps it playing (only a failover or a fallback rebuilds it).
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
    /// The last song that failed to transcode and fell back to its original (Task 7).
    public private(set) var lastFallbackSongId: String?
    /// Overall volume (the sleep timer's fade), forwarded to the engine.
    public var volume: Float = 1 {
        didSet { engine.setVolume(volume) }
    }
    /// Whether a song can play right now (offline: only songs on the phone). Upcoming songs that can't are
    /// left out of the engine's list, and are skipped over; call `upcomingURLsChanged()` after changing it.
    @ObservationIgnored public var isPlayable: (Song) -> Bool = { _ in true }
    /// Pause once the current song ends, on the next song. Holds back the upcoming items like repeat one,
    /// and switches itself off when it fires.
    public var stopsAfterCurrent = false {
        didSet {
            // While the engine is stopped (`needsReload`) the next load sends the list anyway.
            if oldValue != stopsAfterCurrent, queue.current != nil, !needsReload { syncEngine() }
        }
    }

    /// Scrobble at 50 % of the track or this many seconds, whichever comes first.
    static let scrobbleCap: TimeInterval = 240
    /// `previous()` restarts the current song once it has played longer than this.
    static let restartThreshold: TimeInterval = 3

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private let scrobbler: any Scrobbler
    @ObservationIgnored private let urls: any StreamURLProvider
    @ObservationIgnored private let isFind: (Song) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let gain: (Song) -> Float
    @ObservationIgnored private var playback: TrackPlayback?
    /// The engine stopped on its own (end of list, or the current entry failed); resuming or
    /// skipping reloads the engine instead of relying on what it still holds.
    @ObservationIgnored private var needsReload = false
    /// The current entry failed; engine item changes are ignored until the user acts.
    @ObservationIgnored private var failedEntryId: UUID?
    /// `main` order before shuffle was switched on, so switching it off can put it back.
    @ObservationIgnored private var unshuffledOrder: [UUID]?
    @ObservationIgnored private var pendingScrobbles: [UUID: Task<Void, Never>] = [:]
    /// What the engine was last handed as current; reused so a refresh of the upcoming URLs (quality,
    /// network) never makes the engine reload the song that is playing.
    @ObservationIgnored private var loaded: (entryId: UUID, url: URL)?
    /// The list last sent to the engine, by entry id: an entry reached by advance plays the URL the engine
    /// enqueued it on (`adoptLoaded`).
    @ObservationIgnored private var sent: [(id: UUID, url: URL)] = []
    /// Entries (with the song they held) that failed and were rebuilt on their original URL; a second
    /// failure is final.
    @ObservationIgnored private var fellBack: Set<FallbackKey> = []

    private struct FallbackKey: Hashable {
        var entryId: UUID
        var songId: String
    }

    /// Scrobble bookkeeping for the entry that is playing.
    private struct TrackPlayback {
        var entryId: UUID
        var startedAt: Date
        var submitted = false
    }

    public init(engine: any PlaybackEngine, scrobbler: any Scrobbler, urls: any StreamURLProvider,
                isFind: @escaping (Song) -> Bool = { _ in false },
                now: @escaping () -> Date = { Date() },
                gain: @escaping (Song) -> Float = { _ in 1 }) {
        self.engine = engine
        self.scrobbler = scrobbler
        self.urls = urls
        self.isFind = isFind
        self.now = now
        self.gain = gain
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
        fellBack = []
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
        // A manual skip is not the song ending: stop after current no longer applies. Turning it off
        // re-sends the upcoming list, so the engine has the next song again.
        stopsAfterCurrent = false
        guard let target = queue.upcoming.first(where: { isPlayable($0.song) }) else {
            if repeatMode == .all, queue.wrapToStart() != nil {
                needsReload = true
                resume()
            }
            return
        }
        // The engine holds the entry right after the current one in the list last sent. After a gapless
        // advance the current entry is no longer first there, so look it up rather than read `sent[1]`.
        let currentIndex = queue.current.flatMap { current in sent.firstIndex { $0.id == current.id } }
        let engineHasItNext = !needsReload
            && currentIndex.map { sent.indices.contains($0 + 1) && sent[$0 + 1].id == target.id } ?? false
        while queue.current?.id != target.id, queue.advance() != nil {}
        guard engineHasItNext else {
            loadCurrent()
            return
        }
        engine.next()
        adoptLoaded(target.id)
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
        syncEngine(rebuildCurrent: true)
        engine.seek(to: resumeAt)
    }

    /// What the upcoming songs stream from changed (quality, network, a download landed, playability):
    /// re-send them with fresh URLs and volumes. The current song keeps playing on the URL it has.
    public func upcomingURLsChanged() {
        guard queue.current != nil, !needsReload else { return }
        syncEngine()
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
            adoptLoaded(id)
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
            guard let current = queue.current, id == current.id else { return }
            let key = FallbackKey(entryId: id, songId: current.song.id)
            if !fellBack.contains(key), let original = urls.originalURL(for: current.song), original != loaded?.url {
                // The server couldn't convert it: play the original instead, once.
                fellBack.insert(key)
                lastFallbackSongId = current.song.id
                let resumeAt = position
                syncEngine(rebuildCurrent: true)
                if resumeAt > 0 { engine.seek(to: resumeAt) }
                engine.play()
                isPlaying = true
                return
            }
            if !isPlayable(current.song), skipToNextPlayable() { return }
            lastError = message
            failedEntryId = id
            needsReload = true
            engine.pause()
            isPlaying = false
        case .ended:
            isPlaying = false
            needsReload = true
            if stopsAfterCurrent {
                stopsAfterCurrent = false
                stopOnNext()
                return
            }
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

    /// Sends `[current] + upcoming` (playable ones only) with their volumes and fresh URLs, except that the
    /// current entry keeps the URL it was loaded with unless `rebuildCurrent`. An idle queue empties and
    /// stops the engine.
    private func syncEngine(rebuildCurrent: Bool = false) {
        guard let current = queue.current else {
            loaded = nil
            sent = []
            engine.setItems([], startAt: 0)
            engine.pause()
            isPlaying = false
            return
        }
        let currentURL: URL
        if !rebuildCurrent, let loaded, loaded.entryId == current.id {
            currentURL = loaded.url
        } else if fellBack.contains(FallbackKey(entryId: current.id, songId: current.song.id)), let original = urls.originalURL(for: current.song) {
            currentURL = original
        } else {
            currentURL = urls.streamURL(for: current.song)
        }
        loaded = (current.id, currentURL)
        let following = repeatMode == .one || stopsAfterCurrent ? [] : queue.upcoming.filter { isPlayable($0.song) }
        let entries = [current] + following
        // Volumes first: the engine applies them as it enqueues.
        engine.setVolumes(Dictionary(entries.map { ($0.id, gain($0.song)) }, uniquingKeysWith: { a, _ in a }))
        let items = [(current.id, currentURL)] + following.map { ($0.id, urls.streamURL(for: $0.song)) }
        sent = items.map { (id: $0.0, url: $0.1) }
        engine.setItems(items, startAt: 0)
    }

    /// The engine moved on to entry `id` by itself or by `engine.next()`: it plays the URL it enqueued, which
    /// can be older than the last one sent (it keeps an enqueued item whose URL changed). Remember that one,
    /// so the next queue edit doesn't restart the song.
    private func adoptLoaded(_ id: UUID) {
        guard let url = engine.enqueuedURL(for: id) ?? sent.first(where: { $0.id == id })?.url else { return }
        loaded = (id, url)
    }

    /// Loads the current entry from the start. The engine reloads it either way, so its URL is built afresh.
    private func loadCurrent() {
        loaded = nil
        syncEngine()
        beginEntry()
    }

    /// The current song failed and can't play right now (offline, not on the phone): move on to the next
    /// song that can and keep playing. False when none is left.
    private func skipToNextPlayable() -> Bool {
        guard let target = queue.upcoming.first(where: { isPlayable($0.song) }) else { return false }
        while queue.current?.id != target.id, queue.advance() != nil {}
        loadCurrent()
        engine.play()
        isPlaying = true
        return true
    }

    /// Stop after current fired: the next song becomes current without loading or playing, so play starts
    /// it from the top. Nothing next: the end of the queue, as usual.
    private func stopOnNext() {
        guard queue.advance() != nil else {
            hasEnded = true
            return
        }
        position = 0
        duration = queue.current.flatMap { $0.song.duration > 0 ? $0.song.duration : nil }
        lastError = nil
        playback = nil
    }

    /// A new entry became current: reset position and scrobble state, send "now playing".
    private func beginEntry() {
        if playback?.entryId != queue.current?.id { lastFallbackSongId = nil }
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
