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
/// The engine holds `[current]` plus the next `lookahead` playable upcoming entries (QC: only that window gets URLs
/// and volumes, so a library-sized queue costs no more than a short one), starting at index 0. Any queue edit
/// re-sends that list, and it is topped back up as the engine moves on; the current entry keeps the URL it was
/// loaded with, so the engine keeps it playing (only a failover or a fallback rebuilds it).
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

    /// How many upcoming entries the engine is handed after the current one (`EngineWindow`, 1 to 10). Call
    /// `upcomingURLsChanged()` after changing it.
    @ObservationIgnored public var lookahead = EngineWindow.size(engineMax: AVQueueEngine.maxEnqueued)

    /// Slack on top of the wall-clock time between two ticks, and the most one tick can ever credit.
    private static let tickSlack: TimeInterval = 1
    private static let maxTickCredit: TimeInterval = 30
    /// `previous()` restarts the current song once it has played longer than this.
    static let restartThreshold: TimeInterval = 3

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private let scrobbler: any Scrobbler
    @ObservationIgnored private let urls: any StreamURLProvider
    @ObservationIgnored private let isFind: (Song) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let gain: (Song) -> Float
    /// When a play counts (Task 15); read at every check, so a changed setting applies to the song that is playing.
    @ObservationIgnored private let scrobbleRule: () -> ScrobbleRule
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
    /// Round 24 G (D235): the entry previous last started again, and when. A tick the engine sent before that restart
    /// (still in its stream) would put the old position back on screen while the song plays from the top: until a tick
    /// lands near the start, or `restartTickGrace` passes, a later one for that entry is dropped.
    @ObservationIgnored private var restartedAt: (entryId: UUID, at: Date)?
    private static let restartTickGrace: TimeInterval = 2

    /// The URL the current entry plays from (a file on the phone or a server stream), nil before it is loaded.
    /// Round 12 Y3: Now Playing says what is heard from it, not from the quality set now.
    public var currentURL: URL? {
        guard let loaded, loaded.entryId == queue.current?.id else { return nil }
        return loaded.url
    }
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
        /// Seconds actually listened to: ticks add their step, a seek or a resume elsewhere does not.
        var listened: TimeInterval = 0
        /// The position of the last tick, or where the last seek or resume landed.
        var lastTick: TimeInterval = 0
        /// The wall-clock time of that position.
        var lastTickAt: Date
    }

    public init(engine: any PlaybackEngine, scrobbler: any Scrobbler, urls: any StreamURLProvider,
                isFind: @escaping (Song) -> Bool = { _ in false },
                now: @escaping () -> Date = { Date() },
                gain: @escaping (Song) -> Float = { _ in 1 },
                scrobbleRule: @escaping () -> ScrobbleRule = { .standard }) {
        self.engine = engine
        self.scrobbler = scrobbler
        self.urls = urls
        self.isFind = isFind
        self.now = now
        self.gain = gain
        self.scrobbleRule = scrobbleRule
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
        let resumes = stoppedOnItsOwn
        // A manual skip is not the song ending: stop after current no longer applies. Turning it off
        // re-sends the upcoming list, so the engine has the next song again.
        stopsAfterCurrent = false
        guard let target = queue.upcoming(limit: 1, where: { isPlayable($0.song) }).first else {
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
            if resumes { resume() }
            return
        }
        engine.next()
        adoptLoaded(target.id)
        beginEntry()
        topUpWindow()
    }

    /// Plays the upcoming slot `id` now (round 13: CarPlay's Up Next list): the songs before it count as played, as a
    /// skip past each would, and the queue's order stays. Anything that isn't upcoming changes nothing.
    public func jump(to id: UUID) {
        guard queue.upcoming.contains(where: { $0.id == id }) else { return }
        stopsAfterCurrent = false
        while queue.current?.id != id, queue.advance() != nil {}
        loadCurrent()
        resume()
    }

    public func previous() {
        let resumes = stoppedOnItsOwn
        if position > Self.restartThreshold || queue.back() == nil {
            restartFromTop(resumes: resumes)
            return
        }
        loadCurrent()
        if resumes { resume() }
    }

    /// Round 24 G (owner item 11, D235): the player stopped by itself, not by the owner's pause: the current song failed
    /// (a dropout in the car), or the queue ended. A skip from there plays what it lands on; before, it loaded the song
    /// and stayed silent, so the car's next and previous seemed to do nothing.
    private var stoppedOnItsOwn: Bool { failedEntryId != nil || hasEnded }

    /// Round 24 G (owner item 11, D235): previous past 3 s starts the song again from a fresh load, not a seek. A
    /// converted stream comes chunked, with no byte ranges (D42, D45), so a seek to 0 could leave the sound where it was
    /// while Now Playing showed 0:00. Emptying the engine's list first makes it drop the item, so the same entry on the
    /// same URL loads anew; paused stays paused. Stopped on its own, the song plays again as a new play.
    private func restartFromTop(resumes: Bool) {
        guard let current = queue.current else { return }
        engine.setItems([], startAt: 0)
        if resumes {
            loadCurrent()
            resume()
            return
        }
        loaded = nil
        syncEngine()
        position = 0
        anchorTick(at: 0)
        restartedAt = (current.id, now())
    }

    public func seek(_ t: TimeInterval) {
        guard t.isFinite else { return }   // NaN or infinity would trap where the position becomes whole seconds
        hasEnded = false
        restartedAt = nil   // R24 G (D235): a seek after a restart is followed at once
        engine.seek(to: t)
        position = t
        anchorTick(at: t)   // a jump is not listening
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
        anchorTick(at: resumeAt)
    }

    /// The songs the engine holds or is about to: the current one and the window after it. Cache upkeep never
    /// removes these files.
    public var windowSongIds: Set<String> {
        guard let current = queue.current else { return [] }
        return Set([current.song.id] + followingWindow().map(\.song.id))
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
            // The engine only moves on to an entry of the list it was last sent. One that list no longer holds is a
            // late event about a list replaced since (the engine was told to play the current entry): following it
            // would name a song that isn't playing and drop its ticks as stale (crash hunt 1).
            guard sent.contains(where: { $0.id == id }) else { return }
            while queue.current?.id != id, queue.advance() != nil {}
            adoptLoaded(id)
            beginEntry()
            topUpWindow()
        case .time(let id, let t, let d):
            guard id == queue.current?.id else { return }   // stale tick from the previous item
            // A time that isn't a number (a stream that lost its clock) keeps the last position: NaN or infinity would
            // trap where it becomes whole seconds (lock screen, the scrubber's clock).
            guard t.isFinite else { return }
            if let restart = restartedAt, restart.entryId == id {   // R24 G (D235): a tick from before the restart
                if t > Self.restartThreshold, now().timeIntervalSince(restart.at) < Self.restartTickGrace { return }
                restartedAt = nil
            }
            position = max(0, t)
            if var p = playback, p.entryId == id {
                // A step is listening only when the wall clock could have covered it (ticks come less often in the
                // background). A bigger jump forward, or any step back, is a seek, or a stale tick from before one:
                // it re-anchors and adds nothing.
                let at = now()
                let step = t - p.lastTick
                if step > 0, step <= at.timeIntervalSince(p.lastTickAt) + Self.tickSlack, step <= Self.maxTickCredit {
                    p.listened += step
                }
                p.lastTick = t
                p.lastTickAt = at
                playback = p
            }
            // The API's song duration wins (D45: Ogg and other transcoded lengths are estimates); the engine's only
            // fills in when the server gave none.
            if let d, d.isFinite, d > 0, (queue.current?.song.duration ?? 0) <= 0 { duration = d }
            maybeSubmitScrobble()
        case .stalled:
            break
        case .failed(let id, let message, let undecodable):
            // Only the current entry matters; the engine retries a failed upcoming item when it
            // is reached. Stop the engine too, so a dead server can't race through the queue.
            guard let current = queue.current, id == current.id else { return }
            let key = FallbackKey(entryId: id, songId: current.song.id)
            let loadedURL = loaded?.url
            if !fellBack.contains(key), let loadedURL, loadedURL.isFileURL {
                // The song's file on the phone failed: it streams instead, once (the app drops the file only when it
                // is damaged). Without a connection there is no stream, and it is skipped like any song that can't play.
                fellBack.insert(key)
                if let stream = urls.localFileFailed(current.song, undecodable: undecodable) {
                    loaded = (current.id, stream)
                    restartCurrent(rebuild: false)
                    return
                }
                // No stream (offline): the file is kept and the next song that can play does.
                if skipToNextPlayable() { return }
            } else if !fellBack.contains(key), let original = urls.originalURL(for: current.song),
                      let loadedURL, original != loadedURL, !urls.isOriginal(loadedURL) {
                // The server couldn't convert it: play the original instead, once.
                fellBack.insert(key)
                lastFallbackSongId = current.song.id
                restartCurrent(rebuild: true)
                return
            }
            if !isPlayable(current.song), skipToNextPlayable() { return }
            lastError = message
            failedEntryId = id
            needsReload = true
            engine.pause()
            isPlaying = false
        case .ended(let id):
            // Only the end of the list last sent counts: one about a list replaced since (queued before `play`, or
            // before a top-up re-sent the window) would skip songs.
            guard id == sent.last?.id else { return }
            isPlaying = false
            needsReload = true
            if continueAfterWindow() { return }
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

    /// The server may be back, or offline mode changed (Task 14): a current song that failed plays again from where it
    /// was when it can play now, otherwise the next song that can does. Nothing happens unless the current one failed.
    public func retryAfterFailure() {
        guard let current = queue.current, failedEntryId == current.id else { return }
        guard isPlayable(current.song) else {
            _ = skipToNextPlayable()
            return
        }
        failedEntryId = nil
        lastError = nil
        needsReload = false
        restartCurrent(rebuild: true)
    }

    /// The current song can't play right now and mustn't go on streaming (Offline mode On): the next song that can
    /// plays, or the player pauses showing `message`. A song playing from the phone is left alone.
    public func stopUnplayableCurrent(message: String) {
        guard let current = queue.current, !isPlayable(current.song), loaded?.url.isFileURL != true else { return }
        if skipToNextPlayable() { return }
        engine.pause()
        isPlaying = false
        lastError = message
        failedEntryId = current.id
        needsReload = true
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

    /// Sends `[current]` plus the window of playable upcoming entries with their volumes and fresh URLs, except that the
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
        let following = followingWindow()
        let entries = [current] + following
        // Volumes first: the engine applies them as it enqueues.
        engine.setVolumes(Dictionary(entries.map { ($0.id, gain($0.song)) }, uniquingKeysWith: { a, _ in a }))
        let items = [(current.id, currentURL)] + following.map { ($0.id, urls.streamURL(for: $0.song)) }
        sent = items.map { (id: $0.0, url: $0.1) }
        engine.setItems(items, startAt: 0)
    }

    /// The playable upcoming entries the engine gets after the current one: none under repeat one or stop after
    /// current (no gapless prefetch), otherwise the first `lookahead` of them.
    private func followingWindow() -> [QueueEntry] {
        guard repeatMode != .one, !stopsAfterCurrent else { return [] }
        let k = min(max(lookahead, 1), EngineWindow.maxSize)
        return queue.upcoming(limit: k, where: { isPlayable($0.song) })
    }

    /// The engine moved on: what it holds after the new current entry is one short of the window. Re-send the
    /// list when the window has more to give (the engine keeps the playing item and its enqueued next one).
    private func topUpWindow() {
        guard let current = queue.current, let i = sent.firstIndex(where: { $0.id == current.id }) else { return }
        guard sent[(i + 1)...].map(\.id) != followingWindow().map(\.id) else { return }
        syncEngine()
    }

    /// The engine moved on to entry `id` by itself or by `engine.next()`: it plays the URL it enqueued, which
    /// can be older than the last one sent (it keeps an enqueued item whose URL changed). Remember that one,
    /// so the next queue edit doesn't restart the song.
    private func adoptLoaded(_ id: UUID) {
        guard let url = engine.enqueuedURL(for: id) ?? sent.first(where: { $0.id == id })?.url else { return }
        loaded = (id, url)
    }

    /// Puts the current entry back on where it was, on a new URL (`loaded` already holds it unless `rebuild`).
    private func restartCurrent(rebuild: Bool) {
        let resumeAt = position
        syncEngine(rebuildCurrent: rebuild)
        if resumeAt > 0 { engine.seek(to: resumeAt) }
        anchorTick(at: resumeAt)
        engine.play()
        isPlaying = true
    }

    /// Loads the current entry from the start. The engine reloads it either way, so its URL is built afresh.
    private func loadCurrent() {
        loaded = nil
        syncEngine()
        beginEntry()
    }

    /// The engine ran out of its window while playable songs remain after it (an `.itemChanged` went missing, so
    /// the window wasn't topped up): carry on with the first playable song after what the engine was last sent,
    /// instead of ending. Not under repeat one or stop after current, whose window is the current song alone.
    private func continueAfterWindow() -> Bool {
        guard repeatMode != .one, !stopsAfterCurrent else { return false }
        let upcoming = queue.upcoming
        let start = sent.last.flatMap { last in upcoming.firstIndex { $0.id == last.id } }.map { $0 + 1 } ?? 0
        guard let target = upcoming[start...].first(where: { isPlayable($0.song) }) else { return false }
        while queue.current?.id != target.id, queue.advance() != nil {}
        loadCurrent()
        engine.play()
        isPlaying = true
        return true
    }

    /// The current song failed and can't play right now (offline, not on the phone): move on to the next
    /// song that can and keep playing. False when none is left.
    private func skipToNextPlayable() -> Bool {
        guard let target = queue.upcoming(limit: 1, where: { isPlayable($0.song) }).first else { return false }
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
        let started = now()
        playback = TrackPlayback(entryId: entry.id, startedAt: started, lastTickAt: started)
        scrobble(entry.song, submission: false, at: nil)
    }

    /// The song is now at `t` by a seek or a resume, not by playing: the next tick counts from here.
    private func anchorTick(at t: TimeInterval) {
        playback?.lastTick = t
        playback?.lastTickAt = now()
    }

    private func maybeSubmitScrobble() {
        guard var p = playback, !p.submitted, let entry = queue.current, entry.id == p.entryId else { return }
        // The API's duration only (D45): the engine's is an estimate for transcoded streams. Unknown (0): minutes only.
        guard let threshold = scrobbleRule().threshold(duration: entry.song.duration), p.listened >= threshold else { return }
        p.submitted = true
        playback = p
        scrobble(entry.song, submission: true, at: p.startedAt)
    }

    private func scrobble(_ song: Song, submission: Bool, at: Date?) {
        // "Count plays" (G8) is the scrobbler's to check, so the app has one switch for it.
        guard !isFind(song) else { return }
        let key = UUID()
        let scrobbler = self.scrobbler
        pendingScrobbles[key] = Task { [weak self] in
            do {
                try await scrobbler.scrobble(song, submission: submission, at: at)
            } catch {
                Log.logger("playback").error("scrobble failed: \(error.localizedDescription, privacy: .private)")
            }
            self?.pendingScrobbles[key] = nil
        }
    }
}
