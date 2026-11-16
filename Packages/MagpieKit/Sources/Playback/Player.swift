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
    /// Round 27 P (owner item 11, 2026-11-14): the song whose dropped connection is being picked up (Now Playing's
    /// "Connection dropped…" hint, D278). Nil again once sound arrives, the song changes or the retries run out.
    public private(set) var reconnectingSongId: String?
    /// Round 27 P (D278, D281): whether the server can start a conversion part-way (`transcodeOffset`); read at each use.
    @ObservationIgnored public var startsConversionsPartWay: () -> Bool = { false }
    /// Round 27 P (D278): whether the server can be reached right now (a connection, and not offline). A dropped stream
    /// is picked up only then; otherwise it stops as before and `retryAfterFailure()` takes it up later.
    @ObservationIgnored public var canReachServer: () -> Bool = { true }
    /// Overall volume (the sleep timer's fade), forwarded to the engine.
    public var volume: Float = 1 {
        didSet { engine.setVolume(volume) }
    }
    /// Whether a song can play right now (offline: only songs on the phone). Upcoming songs that can't are
    /// left out of the engine's list, and are skipped over; call `upcomingURLsChanged()` after changing it.
    @ObservationIgnored public var isPlayable: (Song) -> Bool = { _ in true }
    /// Round 28 O4 (owner, 2026-11-15; D349): what the player says when it waits on a song that can't play right now
    /// (offline, not on the phone) and nothing after it can.
    @ObservationIgnored public var unplayableMessage = "You're offline"
    /// Round 28 O4 fix round 1 (design H3): the player waits on a song it can't play right now (`holdUnplayable`):
    /// Now Playing says so and Play does nothing until it can.
    public private(set) var isHeldUnplayable = false
    /// Round 28 O4 fix round 1 (design H1): offline, the stream playing stalled and hasn't started again yet (Now
    /// Playing shows it stopped). After `offlineStallGrace` it counts as failed.
    public private(set) var isStalled = false
    /// How long an offline stall may last before the stream counts as failed (a tunnel's silence, then the next song on
    /// the phone).
    public static let offlineStallGrace: Duration = .seconds(6)
    /// The stall being waited out (its entry and where it stopped), and which wait is the latest.
    private var stalledAt: (entryId: UUID, position: TimeInterval)?
    private var stallGeneration = 0
    /// Round 28 crash hunt (R28X): the current stream stalled while the server could still be reached, and no sound
    /// has come since (where it stopped). Going offline then starts the grace (`retryAfterFailure`): in a tunnel the
    /// buffer often runs dry before the switch, and the silent stream never failed.
    private var silentSince: (entryId: UUID, position: TimeInterval)?
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
    /// Round 27 A fix round 2 (N1, D307): the entries the queue moved past by itself (a song ending, a gapless move, an
    /// unplayable song passed over), newest last, at most 50; cleared by `play`. A builder tells a song ending from a skip
    /// by it.
    @ObservationIgnored public private(set) var leftNaturally: [UUID] = []
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

    /// Round 27 P (D278): how long to wait before each pick-up of a dropped converted stream; their count is the most
    /// tries an entry gets.
    static let retryDelays: [Duration] = [.seconds(1), .seconds(3)]
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    /// Pick-ups tried for an entry (its own count; another entry starts at 0).
    @ObservationIgnored private var networkRetries: (entryId: UUID, count: Int)?
    /// The pick-up waiting to run: only the latest (by generation) applies, and only while its entry is current.
    @ObservationIgnored private var pendingRetry: (entryId: UUID, generation: Int, message: String)?
    @ObservationIgnored private var retryGeneration = 0
    /// The engine's own clock for the current load (no offset): how long this load has played, for `PlaybackFailure`.
    @ObservationIgnored private var engineTime: TimeInterval = 0
    /// Fix round 1 (M2): the current load is a pick-up. Its first second isn't the conversion's first second, so an
    /// unrecognised failure then counts as the network again, not as a conversion failure.
    @ObservationIgnored private var pickedUpLoad = false
    /// Round 27 P (D282): stalls of the current entry, logged by kind of stream only.
    @ObservationIgnored private var stalls: (entryId: UUID, count: Int)?

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
                scrobbleRule: @escaping () -> ScrobbleRule = { .standard },
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.engine = engine
        self.sleep = sleep
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
        leftNaturally = []
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
            clearStall()   // Round 28 O4 fix round 2 (N1): a pause ends the offline stall's wait
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
        if preferPhoneFile(play: isPlaying) { return }   // Round 28 O4 (D349): enqueued as a stream before it landed
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
        if position > Self.restartThreshold || !backToPlayable() {
            restartFromTop(resumes: resumes)
            return
        }
        loadCurrent()
        if resumes { resume() }
    }

    /// Round 28 O4 (owner, 2026-11-15; D349): Previous goes back to the last song before this one that can play now
    /// (offline, past those not on the phone). False, and the queue as it was, when there is none.
    private func backToPlayable() -> Bool {
        guard let index = queue.currentIndex, index > 0,
              let target = queue.main[..<index].lastIndex(where: { isPlayable($0.song) }) else { return false }
        for _ in target..<index { _ = queue.back() }
        return true
    }

    /// Round 24 G (owner item 11, D235): the player stopped by itself, not by the owner's pause: the current song failed
    /// (a dropout in the car), or the queue ended. A skip from there plays what it lands on; before, it loaded the song
    /// and stayed silent, so the car's next and previous seemed to do nothing.
    private var stoppedOnItsOwn: Bool { failedEntryId != nil || hasEnded }

    /// Previous past 3 s (or on the first song) starts the song again. Stopped on its own, the song loads and plays as a
    /// new play. Otherwise a song that seeks (a file on the phone, an original stream) seeks to 0 as before.
    /// Round 24 G (owner item 11, D235), defensive, the cause unconfirmed on a device: a converted AAC or Opus stream
    /// comes chunked, with no byte ranges (D42, D45), so a seek to 0 may leave the sound where it was while Now Playing
    /// shows 0:00; that one is loaded afresh instead. Emptying the engine's list first makes it drop the item, so the
    /// same entry loads anew (its URL built again, so from the source that is current now); paused stays paused.
    private func restartFromTop(resumes: Bool) {
        guard let current = queue.current else { return }
        if resumes {
            loadCurrent()
            resume()
            return
        }
        // Round 27 P (D281): where the server starts a conversion part-way, a converted stream reloads from 0 by asking
        // for it (`timeOffset=0`), on the URL built for the source that is current now.
        if let url = currentURL, startsConversionsPartWay(), isConvertedStream(url) {
            let fresh = urls.streamURL(for: current.song)
            if isConvertedStream(fresh), let top = StreamOffset.url(fresh, startingAt: 0) {
                return reloadCurrent(on: top, seekTo: nil, play: false)
            }
        }
        guard let url = currentURL, !Self.seeksReliably(url) else { return seek(0) }
        engine.setItems([], startAt: 0)
        loaded = nil
        engineTime = 0
        pickedUpLoad = false
        syncEngine()
        position = 0
        anchorTick(at: 0)
        restartedAt = (current.id, now())
    }

    /// Round 27 P (D278, D281): a server stream that isn't the original: a conversion (`isOriginal` says which).
    private func isConvertedStream(_ url: URL) -> Bool {
        guard !url.isFileURL, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !urls.isOriginal(url)
    }

    /// Whole seconds for a `timeOffset`, never trapping (a huge or negative time is held to `StreamOffset`'s bounds).
    nonisolated static func wholeSeconds(_ t: TimeInterval) -> Int {
        guard t.isFinite, t > 0 else { return 0 }
        return t < TimeInterval(StreamOffset.maxSeconds) ? Int(t) : StreamOffset.maxSeconds
    }

    /// Round 27 P (D278, D281): loads the current entry again on `url`. The engine drops what it holds first, so even
    /// the same URL reloads. A `timeOffset` in the URL is where the stream starts and becomes the position; otherwise
    /// `seekTo` (a best-effort seek, today's for a converted stream) does. `play`: start it (after a failure the engine
    /// stopped wanting to); otherwise it plays or stays paused as it was.
    private func reloadCurrent(on url: URL, seekTo: TimeInterval?, play: Bool) {
        guard let current = queue.current else { return }
        engine.setItems([], startAt: 0)
        loaded = (current.id, url)
        engineTime = 0
        pickedUpLoad = false
        syncEngine()
        let start = TimeInterval(StreamOffset.seconds(in: url))
        var at = start
        if let seekTo, seekTo.isFinite, seekTo > start {
            engine.seek(to: seekTo - start)
            at = seekTo
        }
        position = at
        anchorTick(at: at)   // a jump is not listening
        // A tick from the load before (its clock far from this one's start) is dropped, as after D235's restart. Not
        // after a seek: the new load's own ticks are near the old position then.
        restartedAt = seekTo == nil ? (current.id, now()) : nil
        if play {
            engine.play()
            isPlaying = true
        }
    }

    /// Round 24 G (D235): whether a seek on `url` lands: a file on the phone, or a stream sent with its length
    /// (`estimateContentLength`: the original). A converted AAC or Opus stream goes out chunked without it (D42, D45),
    /// and since round 27 P a converted MP3 too (D282).
    nonisolated static func seeksReliably(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "estimateContentLength" && $0.value == "true" }
    }

    public func seek(_ t: TimeInterval) {
        guard t.isFinite else { return }   // NaN or infinity would trap where the position becomes whole seconds
        hasEnded = false
        clearStall()   // Round 28 O4 fix round 2 (m3): a seek ends the offline stall's wait
        restartedAt = nil   // R24 G (D235): a seek after a restart is followed at once
        // Round 27 P (D281): a converted stream has no byte ranges to seek in (D42, D45); where the server starts a
        // conversion part-way, it is asked for from the target instead. Paused stays paused.
        if let url = currentURL, !needsReload, startsConversionsPartWay(), isConvertedStream(url),
           let target = StreamOffset.url(url, startingAt: Self.wholeSeconds(t)) {
            return reloadCurrent(on: target, seekTo: nil, play: false)
        }
        let offset = TimeInterval(StreamOffset.seconds(in: currentURL))
        engine.seek(to: offset > 0 ? max(0, t - offset) : t)   // the engine's clock starts where the stream did
        position = t
        anchorTick(at: t)   // a jump is not listening
    }

    // MARK: - Queue edits

    public func playNext(_ songs: [Song]) {
        let wasIdle = queue.current == nil
        queue.playNext(songs)
        if wasIdle { loadCurrent() } else { syncEngine() }
    }

    public func addToEnd(_ songs: [Song]) {
        let wasIdle = queue.current == nil
        queue.addToEnd(songs)
        if wasIdle { loadCurrent() } else { syncEngine() }
    }

    /// Round 27 A fix round 1 (design M5, D307): a builder's songs for the end of the queue. While shuffled they land at
    /// seeded random places after the current song (not all at the end) and join the order shuffle-off restores, at
    /// its end; otherwise as `addToEnd`.
    public func addToEnd(_ songs: [Song], shuffleSeed: UInt64) {
        guard isShuffled else { return addToEnd(songs) }
        let wasIdle = queue.current == nil
        let added = queue.insertRandomly(songs, seed: shuffleSeed)
        unshuffledOrder?.append(contentsOf: added)
        if wasIdle { loadCurrent() } else { syncEngine() }
    }

    /// Round 27 P (owner, 2026-11-14): Automix (Q5, D282): what's coming up after the current song becomes `songs`;
    /// the current song plays on and Play next songs stay. One re-send of the engine's list; an idle queue starts with
    /// them like `addToEnd`.
    public func replaceUpcoming(with songs: [Song]) {
        let wasIdle = queue.current == nil
        queue.replaceUpcoming(with: songs)
        guard queue.current != nil else { return }
        if wasIdle { loadCurrent() } else { syncEngine() }
    }

    /// Round 27 D1 fix round 2 (N2, D285): a Discover page's late library copies swapped into what's coming up, each in
    /// its own slot (`PlayQueue.replaceRestSongs`): one re-send of the engine's list in which every unchanged item keeps
    /// its id and URL, so the next stream is never opened twice; the current song and Play next songs stay.
    public func replaceUpcomingSongs(_ copies: [String: Song]) {
        guard queue.current != nil, queue.replaceRestSongs(copies) else { return }
        syncEngine()
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
            advanceNaturally(to: id)
            adoptLoaded(id)
            beginEntry()
            if preferPhoneFile(play: isPlaying) { return }   // Round 28 O4 (D349): enqueued as a stream before it landed
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
            // Round 27 P (D278): a stream that started part-way (`timeOffset`) counts from there; the engine's clock
            // starts at 0 on it.
            engineTime = max(0, t)
            let offset = TimeInterval(StreamOffset.seconds(in: currentURL))
            let at = engineTime + offset
            position = at
            // Round 28 O4 fix round 1 (design H1): sound again after an offline stall: the same song carries on.
            if let stall = stalledAt, stall.entryId == id, at > stall.position { clearStall() }
            if let silent = silentSince, silent.entryId == id, at > silent.position { silentSince = nil }   // R28X
            if pendingRetry == nil, reconnectingSongId != nil { reconnectingSongId = nil }   // sound again (D278)
            if var p = playback, p.entryId == id {
                // A step is listening only when the wall clock could have covered it (ticks come less often in the
                // background). A bigger jump forward, or any step back, is a seek, or a stale tick from before one:
                // it re-anchors and adds nothing.
                let clock = now()
                let step = at - p.lastTick
                if step > 0, step <= clock.timeIntervalSince(p.lastTickAt) + Self.tickSlack, step <= Self.maxTickCredit {
                    p.listened += step
                }
                p.lastTick = at
                p.lastTickAt = clock
                playback = p
            }
            // The API's song duration wins (D45: Ogg and other transcoded lengths are estimates); the engine's only
            // fills in when the server gave none.
            if let d, d.isFinite, d > 0, (queue.current?.song.duration ?? 0) <= 0 { duration = d + offset }
            maybeSubmitScrobble()
        case .stalled:
            noteStall()
            // R28X: online the stall is waited out (D282), but remembered until sound comes, for a switch to offline.
            if canReachServer(), let current = queue.current { silentSince = (current.id, position) }
            startStallGrace()   // Round 28 O4 fix round 1 (design H1)
        case .failed(let id, let message, let undecodable):
            // Only the current entry matters; the engine retries a failed upcoming item when it
            // is reached. Stop the engine too, so a dead server can't race through the queue.
            guard let current = queue.current, id == current.id else { return }
            let key = FallbackKey(entryId: id, songId: current.song.id)
            let loadedURL = loaded?.url
            // Round 27 P (D277): what kind of failure, from the engine's cause and how long this load had played.
            var cause = engine.failureCause(for: id)
            if cause == .unknown, pickedUpLoad { cause = .network }   // fix round 1 (M2)
            let kind = PlaybackFailure.kind(cause: cause, playedFor: engineTime)
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
            } else if kind == .network, let loadedURL, isConvertedStream(loadedURL) {
                // Round 27 P (owner item 11, D278): the connection dropped, the conversion didn't fail. The same quality
                // picks up from where it was (supersedes Task 7's "any failure": the original is many times the size,
                // so on mobile data it only stalled more). Never the original for this; out of tries, it stops.
                if pickUpLater(current, message: message) { return }
            } else if !fellBack.contains(key), let original = urls.originalURL(for: current.song),
                      let loadedURL, original != loadedURL, !urls.isOriginal(loadedURL) {
                // The server couldn't convert it: play the original instead, once.
                fellBack.insert(key)
                lastFallbackSongId = current.song.id
                restartCurrent(rebuild: true)
                return
            }
            stopOnFailure(current, message: message)
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
        // R28X: gone offline while the stream sat stalled with no sound since: its grace starts now (D349).
        if let silent = silentSince, let current = queue.current, silent.entryId == current.id, !canReachServer() {
            silentSince = nil
            startStallGrace()
        }
        guard let current = queue.current, failedEntryId == current.id else { return }
        // Round 27 P (D278): a dropped stream waiting to be picked up is picked up now.
        if let pending = pendingRetry, pending.entryId == current.id {
            return pickUpDroppedStream(generation: pending.generation, play: isPlaying)
        }
        guard isPlayable(current.song) else {
            _ = skipToNextPlayable()
            return
        }
        // Round 28 O4 (D349): an entry held without starting (`holdUnplayable`) starts now, as a new play.
        if playback?.entryId != current.id { beginEntry() }
        isHeldUnplayable = false
        failedEntryId = nil
        lastError = nil
        needsReload = false
        restartCurrent(rebuild: true)
    }

    /// The current song can't play right now and mustn't go on streaming (Offline mode On): the next song that can
    /// plays, or the player pauses showing `message`. A song playing from the phone is left alone.
    public func stopUnplayableCurrent(message: String) {
        if preferPhoneFile(play: isPlaying) { return }   // Round 28 O4 (D349): on the phone, but streaming
        guard let current = queue.current, !isPlayable(current.song), loaded?.url.isFileURL != true else { return }
        if skipToNextPlayable() { return }
        holdUnplayable(current, message: message)
    }

    /// Round 28 O4 (owner, 2026-11-15; D349): offline, the current song is on the phone but the engine has it as a
    /// stream (it landed while the song streamed, or the engine kept the item it enqueued before): it carries on from
    /// the phone's file, from where it is, playing if `play`. Offline nothing streams. False when that isn't the case
    /// (online, a file already, not on the phone, nothing loaded).
    @discardableResult
    private func preferPhoneFile(play: Bool) -> Bool {
        guard !canReachServer(), let current = queue.current, let loaded, loaded.entryId == current.id,
              !loaded.url.isFileURL, isPlayable(current.song) else { return false }
        let file = urls.streamURL(for: current.song)
        guard file.isFileURL else { return false }
        isHeldUnplayable = false
        clearStall()
        failedEntryId = nil
        lastError = nil
        needsReload = false
        reconnectingSongId = nil
        pendingRetry = nil
        reloadCurrent(on: file, seekTo: position, play: play)
        return true
    }

    /// Nothing from `current` on can play right now: the player waits on it, paused, showing `message`, with nothing
    /// loaded; `retryAfterFailure()` (back online) or Play starts it again.
    private func holdUnplayable(_ current: QueueEntry, message: String) {
        isHeldUnplayable = true
        clearStall()
        engine.pause()
        // Round 28 O1 fix round 1 (security M1): nothing on the phone can play, so the remote item is released (no
        // stream URL with its credentials stays loaded); Play loads it again (`needsReload`).
        engine.setItems([], startAt: 0)
        sent = []
        loaded = nil
        isPlaying = false
        // Round 28 O4 (D349): a song held before it started shows its own length from 0, not the last song's place.
        if playback?.entryId != current.id {
            position = 0
            duration = current.song.duration > 0 ? current.song.duration : nil
            playback = nil
        }
        lastError = message
        failedEntryId = current.id
        needsReload = true
        reconnectingSongId = nil   // R27 P (D278): no pick-up while it can't play
        pendingRetry = nil
    }

    /// Waits for scrobble requests already started (tests; app suspension).
    public func waitForPendingScrobbles() async {
        while let task = pendingScrobbles.values.first {
            await task.value
        }
    }

    // MARK: - Internals

    private func resume() {
        guard let current = queue.current else { return }
        hasEnded = false
        // Round 27 P (D278): play during the wait picks the dropped stream up now, from where it was.
        if let pending = pendingRetry, pending.entryId == current.id {
            return pickUpDroppedStream(generation: pending.generation, play: true)
        }
        // Round 28 O4 (D349): offline, a song not on the phone is never started (loaded, or played on): the next one
        // that is plays, or the player waits saying why (`loadCurrent`).
        if needsReload || !isPlayable(current.song) {
            guard loadCurrent() else { return }
        }
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
            reconnectingSongId = nil
            pendingRetry = nil
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
        // Round 27 P (D279): and the API's lengths, so a chunked transcode's next song opens only in its last 20 s.
        engine.setLengths(Dictionary(entries.compactMap { e -> (UUID, TimeInterval)? in
            e.song.duration.isFinite && e.song.duration > 0 ? (e.id, e.song.duration) : nil
        }, uniquingKeysWith: { a, _ in a }))
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
        engineTime = 0
        pickedUpLoad = false
        syncEngine(rebuildCurrent: rebuild)
        let offset = TimeInterval(StreamOffset.seconds(in: loaded?.url))   // R27 P: 0 unless the URL starts part-way
        if resumeAt > offset { engine.seek(to: resumeAt - offset) }
        anchorTick(at: resumeAt)
        engine.play()
        isPlaying = true
    }

    /// Loads the current entry from the start. The engine reloads it either way, so its URL is built afresh.
    /// Round 28 O4 (owner, 2026-11-15; D349): offline, an entry that isn't on the phone is never loaded (its stream
    /// would be asked for, and repeat all, Previous, Play or a new queue could land on one): the next song that can play
    /// becomes current; with none, nothing is loaded and the player waits on the entry (`holdUnplayable`). False then.
    @discardableResult
    private func loadCurrent() -> Bool {
        if let current = queue.current, !isPlayable(current.song) {
            guard let target = queue.upcoming(limit: 1, where: { isPlayable($0.song) }).first else {
                holdUnplayable(current, message: unplayableMessage)
                return false
            }
            advanceNaturally(to: target.id)
        }
        loaded = nil
        syncEngine()
        beginEntry()
        return true
    }

    /// The engine ran out of its window while playable songs remain after it (an `.itemChanged` went missing, so
    /// the window wasn't topped up): carry on with the first playable song after what the engine was last sent,
    /// instead of ending. Not under repeat one or stop after current, whose window is the current song alone.
    /// Moves the queue on to `id` by itself (not a skip), noting each entry it leaves (N1).
    private func advanceNaturally(to id: UUID) {
        while let current = queue.current?.id, current != id {
            guard queue.advance() != nil else { break }
            leftNaturally.append(current)
        }
        if leftNaturally.count > 50 { leftNaturally.removeFirst(leftNaturally.count - 50) }
    }

    private func continueAfterWindow() -> Bool {
        guard repeatMode != .one, !stopsAfterCurrent else { return false }
        let upcoming = queue.upcoming
        let start = sent.last.flatMap { last in upcoming.firstIndex { $0.id == last.id } }.map { $0 + 1 } ?? 0
        guard let target = upcoming[start...].first(where: { isPlayable($0.song) }) else { return false }
        advanceNaturally(to: target.id)
        loadCurrent()
        engine.play()
        isPlaying = true
        return true
    }

    /// The current song failed and can't play right now (offline, not on the phone): move on to the next
    /// song that can and keep playing. False when none is left.
    private func skipToNextPlayable() -> Bool {
        guard let target = queue.upcoming(limit: 1, where: { isPlayable($0.song) }).first else { return false }
        advanceNaturally(to: target.id)
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
        forgetPickUp()
    }

    /// Round 28 O4 fix round 1 (owner, 2026-11-15; design H1, D349): offline (no server to reach), the current stream
    /// stalled: a tunnel's silence. It gets `offlineStallGrace` to start again (a tick past where it stopped); if it
    /// doesn't, it counts as failed: the next song on the phone plays, or the player waits on it (`holdUnplayable`).
    /// Online a stall is waited out as before (D282). Meanwhile `isStalled` (Now Playing's rate 0).
    private func startStallGrace() {
        guard !canReachServer(), let current = queue.current, let loaded, loaded.entryId == current.id,
              !loaded.url.isFileURL, stalledAt?.entryId != current.id else { return }
        isStalled = true
        stalledAt = (current.id, position)
        stallGeneration += 1
        let generation = stallGeneration, sleep = self.sleep
        Task { [weak self] in
            await sleep(Self.offlineStallGrace)
            self?.stallGraceEnded(generation)
        }
    }

    private func clearStall() {
        silentSince = nil   // R28X: a pause, a seek or another song ends the online stall's memory too
        guard stalledAt != nil || isStalled else { return }
        isStalled = false
        stalledAt = nil
        stallGeneration += 1
    }

    /// The grace ran out with no sound: offline still, the stream counts as failed; back online, it is left to pick up.
    private func stallGraceEnded(_ generation: Int) {
        guard generation == stallGeneration, let stall = stalledAt, let current = queue.current,
              current.id == stall.entryId else { return }
        clearStall()
        // Fix round 2 (N1): paused meanwhile (or back online), nothing starts.
        guard isPlaying, !canReachServer() else {
            // R28X: back online with no sound yet, the stall is remembered: offline again, it is waited out again.
            if isPlaying { silentSince = (stall.entryId, stall.position) }
            return
        }
        Log.logger("playback").info("an offline stall outlasted its grace: moving on")
        if isPlayable(current.song) {
            stopOnFailure(current, message: unplayableMessage)
        } else if !skipToNextPlayable() {
            holdUnplayable(current, message: unplayableMessage)
        }
    }

    /// Round 27 P (D276, D278): a new current entry: no pick-up, hint or stall count carries over from the last one.
    private func forgetPickUp() {
        clearStall()
        reconnectingSongId = nil
        pendingRetry = nil
        networkRetries = nil
        engineTime = 0
        pickedUpLoad = false
        stalls = nil
    }

    /// Round 27 P (owner item 11, D278): the current converted stream's connection dropped. Online and with tries left,
    /// it waits (1 s, then 3 s) and picks up on the same quality from where it was; meanwhile it counts as stopped on
    /// its own (a skip plays what it lands on, D235) and Now Playing says it's picking up. False: stop as before.
    private func pickUpLater(_ current: QueueEntry, message: String) -> Bool {
        guard canReachServer() else { return false }
        let done = networkRetries.flatMap { $0.entryId == current.id ? $0.count : nil } ?? 0
        guard done < Self.retryDelays.count else { return false }
        networkRetries = (current.id, done + 1)
        retryGeneration += 1
        let generation = retryGeneration
        pendingRetry = (current.id, generation, message)
        failedEntryId = current.id
        needsReload = true
        lastError = nil
        reconnectingSongId = current.song.id
        Log.logger("playback").info("connection dropped on a converted stream: picking up (try \(done + 1, privacy: .public))")
        let delay = Self.retryDelays[done], sleep = self.sleep
        Task { [weak self] in
            await sleep(delay)
            self?.pickUpDroppedStream(generation: generation, play: nil)
        }
        return true
    }

    /// Runs the waiting pick-up `generation` if it is still the latest and its entry still current: the same stream
    /// from the position, `timeOffset` where the server starts conversions part-way, otherwise from 0 with a seek.
    /// Offline by now: it stops with the error. `play` nil: plays if the player still means to (a pause meanwhile holds).
    private func pickUpDroppedStream(generation: Int, play: Bool?) {
        guard let pending = pendingRetry, pending.generation == generation,
              let current = queue.current, current.id == pending.entryId else { return }
        pendingRetry = nil
        guard canReachServer(), let base = loaded.flatMap({ $0.entryId == current.id ? $0.url : nil }) else {
            return stopOnFailure(current, message: pending.message)
        }
        failedEntryId = nil
        needsReload = false
        let at = max(0, position)
        let plays = play ?? isPlaying
        if startsConversionsPartWay(), let url = StreamOffset.url(base, startingAt: Self.wholeSeconds(at)) {
            reloadCurrent(on: url, seekTo: nil, play: plays)
        } else {
            reloadCurrent(on: base, seekTo: at, play: plays)
        }
        pickedUpLoad = true   // fix round 1 (M2): after `reloadCurrent`, which clears it
        // Fix round 1 (M1): paused, nothing is picking up any more: the hint goes now, not at some later play.
        if !plays { reconnectingSongId = nil }
    }

    /// The current entry can't play on: when it can't play right now (offline) the next song that can plays; otherwise
    /// the player stops on it showing `message`.
    private func stopOnFailure(_ current: QueueEntry, message: String) {
        reconnectingSongId = nil
        pendingRetry = nil
        if preferPhoneFile(play: true) { return }   // Round 28 O4 (D349): the stream failed; the song is on the phone

        if !isPlayable(current.song), skipToNextPlayable() { return }
        lastError = message
        failedEntryId = current.id
        needsReload = true
        engine.pause()
        isPlaying = false
    }

    /// Round 27 P (D282): the engine waited for data. Counted per entry and logged by the kind of stream only (no URL),
    /// so a device log shows whether converted streams stall more than files and originals.
    private func noteStall() {
        guard let current = queue.current else { return }
        let n = (stalls.flatMap { $0.entryId == current.id ? $0.count : nil } ?? 0) + 1
        stalls = (current.id, n)
        let kind = currentURL.map { $0.isFileURL ? "file" : isConvertedStream($0) ? "converted stream" : "stream" } ?? "nothing loaded"
        Log.logger("playback").info("stalled (\(n, privacy: .public) on this song) on a \(kind, privacy: .public)")
    }

    /// A new entry became current: reset position and scrobble state, send "now playing".
    private func beginEntry() {
        isHeldUnplayable = false
        if playback?.entryId != queue.current?.id { lastFallbackSongId = nil }
        forgetPickUp()
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
