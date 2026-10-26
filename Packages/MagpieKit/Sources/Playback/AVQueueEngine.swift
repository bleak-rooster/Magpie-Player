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
    }

    private var player = AVQueuePlayer()
    private var list: [(id: UUID, url: URL)] = []
    private var enqueued: [ObjectIdentifier: Enqueued] = [:]
    private var reportedId: UUID?
    private var lastTime: TimeInterval = 0
    /// What the user asked for; survives interruptions so we know whether to resume.
    private var wantsToPlay = false
    private var playerObservers: [Any] = []
    private var notificationTokens: [NSObjectProtocol] = []
    #if os(iOS)
    private var sessionActivated = false
    #endif

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
            for item in player.items().dropFirst() {
                player.remove(item)
                forget(item)
            }
        } else {
            clearPlayer()
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
            // Finished the list earlier; play it again from its first item.
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

    public func next() {
        guard let nextIndex = indexAfterCurrent() else {
            clearPlayer()
            continuation.yield(.ended)
            return
        }
        if player.items().count < 2 { enqueue(list[nextIndex]) }
        player.advanceToNextItem()
        lastTime = 0
        reportCurrent()
        topUp()
    }

    // MARK: - Queue upkeep

    private func indexAfterCurrent() -> Int? {
        guard let current = player.currentItem, let info = enqueued[ObjectIdentifier(current)],
              let i = list.firstIndex(where: { $0.id == info.id }), i + 1 < list.count else { return nil }
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
        player.insert(item, after: nil)
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
        let live = Set(player.items().map(ObjectIdentifier.init))
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
        if let current = player.currentItem, ObjectIdentifier(current) == oid {
            wantsToPlay = false
            player.pause()
            for item in player.items().dropFirst() {
                player.remove(item)
                forget(item)
            }
        } else if let item = player.items().first(where: { ObjectIdentifier($0) == oid }) {
            player.remove(item)
            forget(item)
        }
        continuation.yield(.failed(info.id, message))
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
            Log.logger("playback").error("audio session category failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func activateSessionIfNeeded() {
        guard !sessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActivated = true
        } catch {
            Log.logger("playback").error("audio session activation failed: \(error.localizedDescription, privacy: .public)")
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
