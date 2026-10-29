import AVFoundation
import Foundation
import MagpieCore

/// `PlaybackEngine` on `AVQueuePlayer` (gapless when the files carry encoder delay/padding info).
///
/// Holds the full list from `Player` but keeps at most `maxEnqueued` items in the AVQueuePlayer:
/// the next item is appended once the current one has `prefetchLead` seconds or less left
/// (immediately when the current item's length is unknown, e.g. a live transcode).
///
/// On iOS the audio session is configured `.playback` / `.longFormAudio` at init but activated
/// only on the first `play()` — activating early cuts off the car's own audio (FM radio) in CarPlay.
@MainActor
public final class AVQueueEngine: PlaybackEngine {
    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    static let maxEnqueued = 3
    static let prefetchLead: TimeInterval = 20

    private struct Enqueued {
        let item: AVPlayerItem
        let id: UUID
        let url: URL
        let statusObservation: NSKeyValueObservation
        /// The ReplayGain volume asked for last; an audio-mix load that finishes after a newer one is dropped.
        var volume: Float = 1
        /// Whether the item's audio mix carries `volume` (always so at 1). Until it does, the player volume
        /// carries it while the item is current, so a fresh song never starts with a loud burst.
        var mixApplied = true
    }

    private var player = AVQueuePlayer()
    private var list: [(id: UUID, url: URL)] = []
    private var enqueued: [ObjectIdentifier: Enqueued] = [:]
    /// The entry the engine considers current (last `.itemChanged`). Failure handling keys off this,
    /// not `player.currentItem`, because AVQueuePlayer may already have skipped past a failed item.
    private var reportedId: UUID?
    /// Set when the current entry failed and playback was halted on it.
    private var haltedId: UUID?
    private var lastTime: TimeInterval = 0
    /// Per-entry volumes from `setVolumes`, applied as items are enqueued (and to items already enqueued).
    private var volumes: [UUID: Float] = [:]
    /// Overall volume from `setVolume`; survives a media-services rebuild.
    private var volume: Float = 1
    /// What the user asked for; survives interruptions so we know whether to resume.
    private var wantsToPlay = false
    private var playerObservers: [Any] = []
    private var notificationTokens: [NSObjectProtocol] = []
    #if os(iOS)
    private var sessionActivated = false
    #endif

    /// What the AVQueuePlayer holds right now, current first.
    public var enqueuedItems: [(id: UUID, url: URL)] {
        player.items().compactMap { item in enqueued[ObjectIdentifier(item)].map { (id: $0.id, url: $0.url) } }
    }

    /// Diagnostics: what the current item plays at, the player volume times its audio mix (whichever of the two
    /// carries its ReplayGain right now).
    public var currentItemEffectiveVolume: Float {
        player.volume * (currentItemMixVolume ?? 1)
    }

    /// Diagnostics: the current item's ReplayGain volume as its audio mix carries it; nil without a mix.
    public var currentItemMixVolume: Float? {
        guard let params = player.currentItem?.audioMix?.inputParameters.first else { return nil }
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange.zero
        guard params.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range) else { return nil }
        return start
    }

    public init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        #if os(iOS)
        configureSession()
        observeSession()
        #endif
        attach(player)
        observeItemNotifications()
    }

    // MARK: - PlaybackEngine

    public func setItems(_ urls: [(UUID, URL)], startAt: Int) {
        list = urls.map { (id: $0.0, url: $0.1) }
        guard list.indices.contains(startAt) else {
            clearPlayer()
            return
        }
        let target = list[startAt]
        if let current = player.currentItem, let info = enqueued[ObjectIdentifier(current)],
           info.id == target.id, info.url == target.url {
            // Keep the item already enqueued right after it when it is still next, even on another URL:
            // swapping it would cost the gapless join.
            let nextId = list.indices.contains(startAt + 1) ? list[startAt + 1].id : nil
            for (offset, item) in player.items().dropFirst().enumerated() {
                if offset == 0, let nextId, enqueued[ObjectIdentifier(item)]?.id == nextId { continue }
                player.remove(item)
                forget(item)
            }
        } else {
            clearPlayer()
            haltedId = nil
            enqueue(target)
            lastTime = 0
            reportCurrent()
            if wantsToPlay { player.play() }
        }
        topUp()
    }

    public func play() {
        wantsToPlay = true
        #if os(iOS)
        activateSessionIfNeeded()
        #endif
        if player.currentItem == nil, let first = list.first {
            // Finished the list or halted on a failure: (re)load the first item.
            haltedId = nil
            enqueue(first)
            reportCurrent()
        }
        player.play()
    }

    public func pause() {
        wantsToPlay = false
        player.pause()
    }

    public func seek(to t: TimeInterval) {
        lastTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
    }

    public func setVolumes(_ volumes: [UUID: Float]) {
        self.volumes = volumes
        // Items already enqueued (the current one, a kept next one) take the new volume too.
        for item in player.items() {
            guard let id = enqueued[ObjectIdentifier(item)]?.id else { continue }
            apply(volumes[id] ?? 1, to: item)
        }
    }

    public func enqueuedURL(for id: UUID) -> URL? {
        enqueuedItems.first { $0.id == id }?.url
    }

    public func setVolume(_ volume: Float) {
        self.volume = volume
        updatePlayerVolume()
    }

    public func next() {
        guard let nextIndex = indexAfterCurrent() else {
            clearPlayer()
            continuation.yield(.ended)
            return
        }
        haltedId = nil
        if player.currentItem != nil, player.items().count >= 2 {
            player.advanceToNextItem()
        } else {
            clearPlayer()
            enqueue(list[nextIndex])
            if wantsToPlay { player.play() }
        }
        lastTime = 0
        reportCurrent()
        topUp()
    }

    // MARK: - Queue upkeep

    private func indexAfterCurrent() -> Int? {
        guard let id = reportedId, let i = list.firstIndex(where: { $0.id == id }), i + 1 < list.count else {
            return nil
        }
        return i + 1
    }

    /// Appends the item after the last enqueued one when the current item is close to its end.
    private func topUp() {
        guard let current = player.currentItem, current.status != .failed else { return }
        let items = player.items()
        guard items.count < Self.maxEnqueued, items.count == 1 else { return }
        let duration = current.duration.seconds
        let remaining = duration.isFinite ? duration - current.currentTime().seconds : 0
        guard remaining <= Self.prefetchLead, let next = indexAfterCurrent() else { return }
        enqueue(list[next])
    }

    private func enqueue(_ entry: (id: UUID, url: URL)) {
        let item = AVPlayerItem(url: entry.url)
        let oid = ObjectIdentifier(item)
        let observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "Playback failed"
            Task { @MainActor [weak self] in self?.itemFailed(oid, message) }
        }
        enqueued[oid] = Enqueued(item: item, id: entry.id, url: entry.url, statusObservation: observation)
        apply(volumes[entry.id] ?? 1, to: item, force: true)
        player.insert(item, after: nil)
    }

    /// Sets an item's own volume (ReplayGain) as an audio mix: one input parameter per audio track, which
    /// needs the tracks loaded first. A volume of 1 (or more) plays without a mix. Unchanged volumes are left
    /// alone unless `force` (a fresh item).
    private func apply(_ volume: Float, to item: AVPlayerItem, force: Bool = false) {
        let oid = ObjectIdentifier(item)
        // A mix still missing (loading, or its load failed) is asked for again.
        guard let info = enqueued[oid], force || info.volume != volume || !info.mixApplied else { return }
        // Drop any old mix at once: until the new one lands the player volume carries the item's volume.
        item.audioMix = nil
        enqueued[oid]?.volume = volume
        enqueued[oid]?.mixApplied = volume >= 1
        updatePlayerVolume()
        guard volume < 1 else { return }
        Task { @MainActor [weak self] in
            let tracks: [AVAssetTrack]
            do {
                tracks = try await item.asset.loadTracks(withMediaType: .audio)
            } catch {
                Log.logger("playback").error("audio tracks failed to load: \(Log.category(of: error), privacy: .public)")
                // `mixApplied` stays false: the player volume keeps carrying it while current, and the next
                // `apply` (any `setVolumes`) loads it again.
                return
            }
            // Dropped meanwhile, or a newer volume asked for: that one wins.
            guard let self, self.enqueued[oid]?.volume == volume else { return }
            let mix = AVMutableAudioMix()
            mix.inputParameters = tracks.map { track in
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(volume, at: .zero)
                return params
            }
            item.audioMix = mix
            self.enqueued[oid]?.mixApplied = true
            self.updatePlayerVolume()
        }
    }

    /// The overall volume, times the current item's ReplayGain volume while its audio mix doesn't carry it yet.
    private func updatePlayerVolume() {
        let pending = player.currentItem.flatMap { enqueued[ObjectIdentifier($0)] }.flatMap { info in
            info.mixApplied ? nil : info.volume
        }
        player.volume = volume * (pending ?? 1)
    }

    private func forget(_ item: AVPlayerItem) {
        enqueued.removeValue(forKey: ObjectIdentifier(item))?.statusObservation.invalidate()
    }

    private func clearPlayer() {
        player.removeAllItems()
        for e in enqueued.values { e.statusObservation.invalidate() }
        enqueued = [:]
        reportedId = nil
    }

    /// Emits `.itemChanged` when the current item differs from the last one reported, and drops
    /// bookkeeping for items AVQueuePlayer has already let go of.
    private func reportCurrent() {
        defer { updatePlayerVolume() }
        let live = Set(player.items().map(ObjectIdentifier.init))
        // AVQueuePlayer skips past a failed item on its own. If the item it dropped is the one we
        // reported as current and it failed, halt on it instead of reporting the next one.
        if let dropped = enqueued.values.first(where: { !live.contains(ObjectIdentifier($0.item)) && $0.id == reportedId }),
           dropped.item.status == .failed {
            haltOnFailure(dropped.id, dropped.item.error?.localizedDescription ?? "Playback failed")
            return
        }
        for (oid, e) in enqueued where !live.contains(oid) {
            e.statusObservation.invalidate()
            enqueued[oid] = nil
        }
        guard let current = player.currentItem, let info = enqueued[ObjectIdentifier(current)],
              info.id != reportedId else { return }
        reportedId = info.id
        continuation.yield(.itemChanged(info.id))
    }

    /// A failed current item stops playback (no auto-advance past it). A failed upcoming item is
    /// dropped from the AVQueuePlayer; `itemEnded` enqueues a fresh copy when it is reached.
    private func itemFailed(_ oid: ObjectIdentifier, _ message: String) {
        guard let info = enqueued[oid] else { return }
        if info.id == reportedId {
            haltOnFailure(info.id, message)
            return
        }
        if let item = player.items().first(where: { ObjectIdentifier($0) == oid }) {
            player.remove(item)
            forget(item)
        }
        continuation.yield(.failed(info.id, message))
    }

    /// Stops on the failed current entry: pause, empty the AVQueuePlayer (it may already sit on the
    /// next song), keep `reportedId` on the failed entry, and report the failure once.
    private func haltOnFailure(_ id: UUID, _ message: String) {
        guard haltedId != id else { return }
        wantsToPlay = false
        player.pause()
        clearPlayer()
        reportedId = id
        haltedId = id
        continuation.yield(.failed(id, message))
    }

    private func tick(_ time: CMTime) {
        guard let current = player.currentItem, let info = enqueued[ObjectIdentifier(current)] else { return }
        lastTime = time.seconds
        let d = current.duration.seconds
        continuation.yield(.time(info.id, time.seconds, duration: d.isFinite && d > 0 ? d : nil))
        topUp()
    }

    // MARK: - Observation

    private func attach(_ player: AVQueuePlayer) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        let currentItem = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.reportCurrent() }
        }
        playerObservers = [timeObserver, currentItem]
    }

    private func detach(_ player: AVQueuePlayer) {
        for observer in playerObservers {
            if let kvo = observer as? NSKeyValueObservation { kvo.invalidate() } else { player.removeTimeObserver(observer) }
        }
        playerObservers = []
    }

    private func observeItemNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                     object: nil, queue: .main) { [weak self] note in
            let oid = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.itemEnded(oid) }
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification,
                                                     object: nil, queue: .main) { [weak self] note in
            let oid = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let oid, self.enqueued[oid] != nil else { return }
                self.continuation.yield(.stalled)
            }
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                     object: nil, queue: .main) { [weak self] note in
            let oid = (note.object as AnyObject?).map(ObjectIdentifier.init)
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "Playback failed"
            MainActor.assumeIsolated {
                guard let oid else { return }
                self?.itemFailed(oid, message)
            }
        })
    }

    private func itemEnded(_ oid: ObjectIdentifier?) {
        guard let oid, let info = enqueued[oid] else { return }
        if list.last?.id == info.id {
            wantsToPlay = false
            continuation.yield(.ended)
            return
        }
        // Nothing queued behind the finished item (the next one failed earlier and was dropped):
        // enqueue a fresh copy of the next entry so playback carries on instead of stopping silently.
        let behind = player.items().drop { ObjectIdentifier($0) != oid }.dropFirst()
        guard behind.isEmpty, let i = list.firstIndex(where: { $0.id == info.id }), i + 1 < list.count else { return }
        enqueue(list[i + 1])
    }

    // MARK: - Audio session (iOS)

    #if os(iOS)
    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            Log.logger("playback").error("audio session category failed: \(Log.category(of: error), privacy: .public)")
        }
    }

    private func activateSessionIfNeeded() {
        guard !sessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActivated = true
        } catch {
            Log.logger("playback").error("audio session activation failed: \(Log.category(of: error), privacy: .public)")
        }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // Interruptions (iOS 27 API): the session goes inactive, later the system may recommend resuming.
        notificationTokens.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification,
                                                     object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionBecameInactive() }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification,
                                                     object: session, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            let shouldResume = context?.recommendation == .shouldResume
            MainActor.assumeIsolated { self?.resumptionRecommended(shouldResume) }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                     object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                // Headphones unplugged / car disconnected: pause rather than play out of the speaker.
                guard reason == .oldDeviceUnavailable, let self, self.wantsToPlay else { return }
                self.pause()
                self.continuation.yield(.playing(false))
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                     object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterMediaServicesReset() }
        })
    }

    /// The system has paused us. Keep `wantsToPlay` so a later recommendation can resume.
    private func sessionBecameInactive() {
        sessionActivated = false
        continuation.yield(.playing(false))
    }

    private func resumptionRecommended(_ shouldResume: Bool) {
        guard wantsToPlay, shouldResume else {
            wantsToPlay = false
            return
        }
        activateSessionIfNeeded()
        player.play()
        continuation.yield(.playing(true))
    }

    /// Media services restarted: every AV object is dead. Rebuild the player and reload the
    /// current item where it was.
    private func rebuildAfterMediaServicesReset() {
        let resumeId = player.currentItem.flatMap { enqueued[ObjectIdentifier($0)]?.id }
        let resumeAt = lastTime
        detach(player)
        clearPlayer()
        player = AVQueuePlayer()
        player.volume = volume
        attach(player)
        sessionActivated = false
        configureSession()
        guard let id = resumeId, let start = list.firstIndex(where: { $0.id == id }) else { return }
        setItems(list.map { ($0.id, $0.url) }, startAt: start)
        seek(to: resumeAt)
        if wantsToPlay { play() }
    }
    #endif
}
