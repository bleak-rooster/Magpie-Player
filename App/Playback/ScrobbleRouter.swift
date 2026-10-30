import Foundation
import ListenBrainzKit
import MagpieCore
import NavidromeKit
import os
import Playback

/// Sends plays to each destination the owner picked (spec §7): through Navidrome (which may forward them), straight
/// to ListenBrainz with the saved token, or both.
///
/// - Nothing is sent while Count plays is off, and a find is never sent (D29), on either path. The same fail-closed
///   `FindsIdentity` check runs again when a queued play is dequeued.
/// - "Now playing" is best-effort: sent to each destination, never queued.
/// - A play that can't go now (offline, forced On included, or the send failed and may work later) is queued per
///   destination (`ScrobbleQueue`) with when it was heard, and goes again on `drain()`: at launch, on reconnect, when
///   offline mode ends, when Count plays or a ListenBrainz token comes back, and every `retryInterval` while anything
///   is queued. A ListenBrainz refusal that would repeat (400, 413) isn't queued.
/// - A 401 from ListenBrainz means the token no longer works: nothing more goes there (plays queue) until a token is
///   saved again (`listenBrainzTokenReplaced`), and Settings › Scrobbling says so (`onListenBrainzRejected`). A 401
///   answering a token that has been replaced since is ignored.
final class ScrobbleRouter: Scrobbler {
    private struct State {
        /// Bumped by `clearQueue` (sign-out): a send or drain started before it never queues or sends after it.
        var generation = 0
        /// The last `clearQueue`'s clear: a drain waits for it before reading the queue.
        var clearing: Task<Void, Never>?
        var draining = false
        var drainAgain = false
        /// The retry timer, while anything is queued.
        var retry: Task<Void, Never>?
        /// Bumped whenever the token is saved or removed: a 401 counts only for the token it answered.
        var tokenGeneration = 0
        var listenBrainzRejected = false
        var onListenBrainzRejected: (@Sendable () -> Void)?
    }

    /// The ListenBrainz client for one send, and which token it carries.
    private struct LBClient {
        var client: ListenBrainzClient
        var tokenGeneration: Int
    }

    let box: ClientBox
    let counting: PlayCounting
    let findsIdentity: FindsIdentity
    let settings: ScrobbleSettings
    let queue: ScrobbleQueue
    /// How often what is queued is tried again (fix round 1, ruling b).
    let retryInterval: Duration
    /// A client with the token read from the Keychain now; nil without one.
    private let listenBrainz: @Sendable () -> ListenBrainzClient?
    private let isOffline: @Sendable () -> Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(box: ClientBox, counting: PlayCounting, findsIdentity: FindsIdentity, settings: ScrobbleSettings,
         queue: ScrobbleQueue, listenBrainz: @escaping @Sendable () -> ListenBrainzClient?,
         isOffline: @escaping @Sendable () -> Bool, retryInterval: Duration = .seconds(300)) {
        self.box = box; self.counting = counting; self.findsIdentity = findsIdentity; self.settings = settings
        self.queue = queue; self.listenBrainz = listenBrainz; self.isOffline = isOffline
        self.retryInterval = retryInterval
    }

    /// ListenBrainz refused the token (401); cleared when a token is saved again.
    var listenBrainzRejected: Bool { state.withLock { $0.listenBrainzRejected } }

    var tokenGeneration: Int { state.withLock { $0.tokenGeneration } }

    func setOnListenBrainzRejected(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.onListenBrainzRejected = handler }
    }

    /// A token was saved or removed: ListenBrainz may be tried again.
    func listenBrainzTokenReplaced() {
        state.withLock {
            $0.tokenGeneration += 1
            $0.listenBrainzRejected = false
        }
    }

    /// Sign-out: every queued play is forgotten, and nothing under way queues or sends after this.
    func clearQueue() {
        state.withLock { s in
            s.generation += 1
            s.retry?.cancel()
            s.retry = nil
            s.clearing = Task { [queue, previous = s.clearing] in
                await previous?.value
                await queue.clear()
            }
        }
    }

    // MARK: - Sending

    func scrobble(_ song: Song, submission: Bool, at: Date?) async throws {
        guard counting.isOn, !findsIdentity.isFind(song) else { return }   // G8, D29
        let prefs = settings.value
        let generation = state.withLock { $0.generation }
        let offline = isOffline()
        let listenBrainz = prefs.viaListenBrainz ? listenBrainzClient() : nil
        // `single` must carry `listened_at`, so a submission always has one.
        let heard = at ?? .now
        async let viaNavidrome: Void = prefs.viaNavidrome
            ? sendToNavidrome(song, submission: submission, at: heard, offline: offline, generation: generation) : ()
        async let viaListenBrainz: Void = sendToListenBrainz(listenBrainz, song, submission: submission, at: heard,
                                                             offline: offline, generation: generation)
        _ = await (viaNavidrome, viaListenBrainz)
    }

    private func listenBrainzClient() -> LBClient? {
        let tokenGeneration = self.tokenGeneration
        return listenBrainz().map { LBClient(client: $0, tokenGeneration: tokenGeneration) }
    }

    private func sendToNavidrome(_ song: Song, submission: Bool, at: Date, offline: Bool, generation: Int) async {
        guard !offline else {
            if submission { await enqueue(song, .navidrome, at: at, generation: generation) }
            return
        }
        guard let client = box.client else { return }   // signed out meanwhile
        do {
            try await client.scrobble(songId: song.id, submission: submission, at: submission ? at : nil)
        } catch {
            if submission { await enqueue(song, .navidrome, at: at, generation: generation) }
        }
    }

    /// `lb` nil: ListenBrainz is off, or no token is saved.
    private func sendToListenBrainz(_ lb: LBClient?, _ song: Song, submission: Bool, at: Date,
                                    offline: Bool, generation: Int) async {
        guard let lb else { return }
        guard !offline, !listenBrainzRejected else {
            if submission { await enqueue(song, .listenBrainz, at: at, generation: generation) }
            return
        }
        do {
            try await lb.client.submitListens([Self.listen(AudioMetadata(song), at: at)], type: submission ? .single : .playingNow)
        } catch {
            switch Self.disposition(error) {
            case .invalidToken:
                tokenRejected(generation: lb.tokenGeneration)
                if submission { await enqueue(song, .listenBrainz, at: at, generation: generation) }
            case .retry:
                if submission { await enqueue(song, .listenBrainz, at: at, generation: generation) }
            case .permanent:
                Log.logger("playback").error("ListenBrainz refused a listen: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func enqueue(_ song: Song, _ destination: ScrobbleDestination, at: Date, generation: Int) async {
        let item = QueuedScrobble(destination: destination, song: song, listenedAt: at)
        await queue.enqueue(item) { [state] in state.withLock { $0.generation } == generation }
        startRetryTimer()
    }

    // MARK: - Draining

    /// Sends what is queued, oldest first, per destination; one at a time (a drain asked for meanwhile runs once more
    /// after). Each destination stops at a failure that may pass and keeps the rest. Offline, or with Count plays off,
    /// nothing is sent. While anything stays queued, the retry timer runs.
    func drain() async {
        let starts = state.withLock { s -> Bool in
            if s.draining { s.drainAgain = true; return false }
            s.draining = true
            return true
        }
        guard starts else { return }
        var again = true
        while again {
            await drainOnce()
            again = state.withLock { s -> Bool in
                let again = s.drainAgain
                s.drainAgain = false
                if !again { s.draining = false }
                return again
            }
        }
        if await hasQueued() { startRetryTimer() }
    }

    private func drainOnce() async {
        await state.withLock { $0.clearing }?.value
        guard counting.isOn, !isOffline() else { return }
        let prefs = settings.value
        let generation = state.withLock { $0.generation }
        if prefs.viaNavidrome { await drainNavidrome(generation: generation) }
        if prefs.viaListenBrainz, !listenBrainzRejected, let lb = listenBrainzClient() {
            await drainListenBrainz(lb, generation: generation)
        }
    }

    private func hasQueued() async -> Bool {
        let nd = await queue.pending(.navidrome), lb = await queue.pending(.listenBrainz)
        return !nd.isEmpty || !lb.isEmpty
    }

    /// Every `retryInterval` while anything is queued: a drain (which sends only to enabled destinations, online).
    private func startRetryTimer() {
        state.withLock { s in
            guard s.retry == nil else { return }
            let interval = retryInterval
            s.retry = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    guard await self.hasQueued() else { break }
                    await self.drain()
                }
                guard let self, !Task.isCancelled else { return }
                self.state.withLock { $0.retry = nil }
                if await self.hasQueued() { self.startRetryTimer() }   // queued while it was stopping
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { state.withLock { $0.generation } == generation }

    /// D29 on dequeue: finds are removed unsent. Run on the whole queue first, and again on each item or chunk just
    /// before it is sent (a song may have become a find meanwhile).
    private func dropFinds<C: Collection<QueuedScrobble>>(_ items: C) async -> [QueuedScrobble] {
        var finds: Set<UUID> = [], rest: [QueuedScrobble] = []
        for item in items {
            if findsIdentity.isFind(item.playedSong) { finds.insert(item.id) } else { rest.append(item) }
        }
        await queue.remove(ids: finds)
        return rest
    }

    /// One request per play, each with its original `time`, removed once the server took it. A Subsonic error other
    /// than auth means the server won't take that play (a song it no longer has, say): it is dropped and the rest go
    /// on. Auth, connection and other failures stop the drain and keep the rest.
    private func drainNavidrome(generation: Int) async {
        for item in await dropFinds(await queue.pending(.navidrome)) {
            guard isCurrent(generation), let client = box.client else { return }
            guard !(await dropFinds([item])).isEmpty else { continue }   // D29 just before the send
            do {
                try await client.scrobble(songId: item.song.songId, submission: true, at: item.listenedAt)
            } catch NavidromeError.api(let code, _) where !Self.subsonicAuthCodes.contains(code) {
                Log.logger("playback").error("Navidrome refused a queued play (\(code))")
            } catch {
                return
            }
            await queue.remove(ids: [item.id])
        }
    }

    /// Subsonic's auth errors (wrong credentials, token auth not supported, invalid API key).
    static let subsonicAuthCodes: Set<Int> = [40, 41, 44]

    /// `import` requests of up to `maxListensPerCall` listens, oldest first; each chunk is removed once it was taken,
    /// so it is never sent again. A permanent refusal (400, 413) sends that chunk's listens one at a time, dropping
    /// only those refused; a 401 marks the token rejected.
    private func drainListenBrainz(_ lb: LBClient, generation: Int) async {
        let items = await dropFinds(await queue.pending(.listenBrainz))
        for start in stride(from: 0, to: items.count, by: ListenBrainzClient.maxListensPerCall) {
            guard isCurrent(generation), !listenBrainzRejected else { return }
            let chunk = await dropFinds(items[start..<min(start + ListenBrainzClient.maxListensPerCall, items.count)])
            guard !chunk.isEmpty else { continue }
            switch await submit(chunk, lb) {
            case nil: await queue.remove(ids: Set(chunk.map(\.id)))
            case .permanent?: guard await sendOneByOne(chunk, lb, generation: generation) else { return }
            case .invalidToken?, .retry?: return
            }
        }
    }

    /// After a permanent refusal of a whole chunk: each listen on its own. Refused ones are dropped, taken ones
    /// removed. False when the drain has to stop (a failure that may pass, the token, a sign-out).
    private func sendOneByOne(_ chunk: [QueuedScrobble], _ lb: LBClient, generation: Int) async -> Bool {
        for item in chunk {
            guard isCurrent(generation), !listenBrainzRejected else { return false }
            switch await submit([item], lb) {
            case nil: break
            case .permanent?:
                Log.logger("playback").error("ListenBrainz refused a queued listen; dropped")
            case .invalidToken?, .retry?: return false
            }
            await queue.remove(ids: [item.id])
        }
        return true
    }

    /// One `import` request; nil when it was taken. A 401 marks the token rejected.
    private func submit(_ items: [QueuedScrobble], _ lb: LBClient) async -> ListenBrainzError.Disposition? {
        do {
            try await lb.client.submitListens(items.map { Self.listen($0.song, at: $0.listenedAt) }, type: .importBatch)
            return nil
        } catch {
            let disposition = Self.disposition(error)
            if disposition == .invalidToken { tokenRejected(generation: lb.tokenGeneration) }
            return disposition
        }
    }

    // MARK: - Helpers

    /// A 401 for the token of `generation`; ignored when that token has been replaced since.
    func tokenRejected(generation: Int) {
        let handler = state.withLock { s -> (@Sendable () -> Void)? in
            guard s.tokenGeneration == generation, !s.listenBrainzRejected else { return nil }
            s.listenBrainzRejected = true
            return s.onListenBrainzRejected
        }
        handler?()
    }

    /// Anything but a ListenBrainz error (a connection error, a cancellation) may work later.
    private static func disposition(_ error: Error) -> ListenBrainzError.Disposition {
        (error as? ListenBrainzError)?.disposition ?? .retry
    }

    static func listen(_ song: AudioMetadata, at: Date) -> Listen {
        Listen(listenedAt: at, trackName: song.title, artistName: song.artist,
               releaseName: song.album.isEmpty ? nil : song.album,
               durationMs: durationMs(song.duration))
    }

    /// Whole milliseconds, nil when unknown or absurd. Past what an Int holds `Int(_:)` traps (crash hunt 1); a length
    /// of 1e12 s or more is a broken one, and ListenBrainz shouldn't be sent it (crash hunt 2).
    static func durationMs(_ seconds: TimeInterval) -> Int? {
        guard seconds > 0, seconds < 1e12 else { return nil }
        return Int(exactly: (seconds * 1000).rounded(.towardZero))
    }
}
