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
///   destination (`ScrobbleQueue`) with when it was heard, and goes again on `drain()`: at launch, on reconnect and
///   when a ListenBrainz token is saved. A ListenBrainz refusal that would repeat (400, 413) isn't queued.
/// - A 401 from ListenBrainz means the token no longer works: nothing more goes there (plays queue) until a token is
///   saved again (`listenBrainzTokenReplaced`), and Settings › Scrobbling says so (`onListenBrainzRejected`).
final class ScrobbleRouter: Scrobbler {
    private struct State {
        /// Bumped by `clearQueue` (sign-out): a send or drain started before it never queues or sends after it.
        var generation = 0
        /// The last `clearQueue`'s clear: a drain waits for it before reading the queue.
        var clearing: Task<Void, Never>?
        var draining = false
        var drainAgain = false
        var listenBrainzRejected = false
        var onListenBrainzRejected: (@Sendable () -> Void)?
    }

    let box: ClientBox
    let counting: PlayCounting
    let findsIdentity: FindsIdentity
    let settings: ScrobbleSettings
    let queue: ScrobbleQueue
    /// A client with the token read from the Keychain now; nil without one.
    private let listenBrainz: @Sendable () -> ListenBrainzClient?
    private let isOffline: @Sendable () -> Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(box: ClientBox, counting: PlayCounting, findsIdentity: FindsIdentity, settings: ScrobbleSettings,
         queue: ScrobbleQueue, listenBrainz: @escaping @Sendable () -> ListenBrainzClient?,
         isOffline: @escaping @Sendable () -> Bool) {
        self.box = box; self.counting = counting; self.findsIdentity = findsIdentity; self.settings = settings
        self.queue = queue; self.listenBrainz = listenBrainz; self.isOffline = isOffline
    }

    /// ListenBrainz refused the token (401); cleared when a token is saved again.
    var listenBrainzRejected: Bool { state.withLock { $0.listenBrainzRejected } }

    func setOnListenBrainzRejected(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.onListenBrainzRejected = handler }
    }

    /// A token was saved or removed: ListenBrainz may be tried again.
    func listenBrainzTokenReplaced() {
        state.withLock { $0.listenBrainzRejected = false }
    }

    /// Sign-out: every queued play is forgotten, and nothing under way queues or sends after this.
    func clearQueue() {
        state.withLock { s in
            s.generation += 1
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
        let listenBrainz = prefs.viaListenBrainz ? self.listenBrainz() : nil
        // `single` must carry `listened_at`, so a submission always has one.
        let heard = at ?? .now
        async let viaNavidrome: Void = prefs.viaNavidrome
            ? sendToNavidrome(song, submission: submission, at: heard, offline: offline, generation: generation) : ()
        async let viaListenBrainz: Void = sendToListenBrainz(listenBrainz, song, submission: submission, at: heard,
                                                             offline: offline, generation: generation)
        _ = await (viaNavidrome, viaListenBrainz)
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

    /// `client` nil: ListenBrainz is off, or no token is saved.
    private func sendToListenBrainz(_ client: ListenBrainzClient?, _ song: Song, submission: Bool, at: Date,
                                    offline: Bool, generation: Int) async {
        guard let client else { return }
        guard !offline, !listenBrainzRejected else {
            if submission { await enqueue(song, .listenBrainz, at: at, generation: generation) }
            return
        }
        do {
            try await client.submitListens([Self.listen(AudioMetadata(song), at: at)], type: submission ? .single : .playingNow)
        } catch {
            switch Self.disposition(error) {
            case .invalidToken:
                tokenRejected()
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
    }

    // MARK: - Draining

    /// Sends what is queued, oldest first, per destination; one at a time (a drain asked for meanwhile runs once more
    /// after). Each destination stops at its first failure and keeps the rest. Offline, or with Count plays off,
    /// nothing is sent.
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
    }

    private func drainOnce() async {
        await state.withLock { $0.clearing }?.value
        guard counting.isOn, !isOffline() else { return }
        let prefs = settings.value
        let generation = state.withLock { $0.generation }
        if prefs.viaNavidrome { await drainNavidrome(generation: generation) }
        if prefs.viaListenBrainz, !listenBrainzRejected, let client = listenBrainz() {
            await drainListenBrainz(client, generation: generation)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { state.withLock { $0.generation } == generation }

    /// D29 on dequeue: finds are removed unsent.
    private func dropFinds(_ items: [QueuedScrobble]) async -> [QueuedScrobble] {
        var finds: Set<UUID> = [], rest: [QueuedScrobble] = []
        for item in items {
            if findsIdentity.isFind(item.playedSong) { finds.insert(item.id) } else { rest.append(item) }
        }
        await queue.remove(ids: finds)
        return rest
    }

    /// One request per play, each with its original `time`, removed once the server took it. A song the server no
    /// longer has (Subsonic error 70) is dropped; any other failure stops the drain.
    private func drainNavidrome(generation: Int) async {
        for item in await dropFinds(await queue.pending(.navidrome)) {
            guard isCurrent(generation), let client = box.client else { return }
            do {
                try await client.scrobble(songId: item.song.songId, submission: true, at: item.listenedAt)
            } catch NavidromeError.api(code: 70, _) {
                // gone from the server: sending it again can't work
            } catch {
                return
            }
            await queue.remove(ids: [item.id])
        }
    }

    /// `import` requests of up to `maxListensPerCall` listens, oldest first; each chunk is removed once it was taken,
    /// so it is never sent again. A permanent refusal drops that chunk and goes on; a 401 marks the token rejected.
    private func drainListenBrainz(_ client: ListenBrainzClient, generation: Int) async {
        let items = await dropFinds(await queue.pending(.listenBrainz))
        for start in stride(from: 0, to: items.count, by: ListenBrainzClient.maxListensPerCall) {
            guard isCurrent(generation), !listenBrainzRejected else { return }
            let chunk = items[start..<min(start + ListenBrainzClient.maxListensPerCall, items.count)]
            do {
                try await client.submitListens(chunk.map { Self.listen($0.song, at: $0.listenedAt) }, type: .importBatch)
            } catch {
                switch Self.disposition(error) {
                case .permanent:
                    Log.logger("playback").error("ListenBrainz refused queued listens: \(error.localizedDescription, privacy: .private)")
                case .invalidToken:
                    tokenRejected()
                    return
                case .retry:
                    return
                }
            }
            await queue.remove(ids: Set(chunk.map(\.id)))
        }
    }

    // MARK: - Helpers

    private func tokenRejected() {
        let handler = state.withLock { s -> (@Sendable () -> Void)? in
            guard !s.listenBrainzRejected else { return nil }
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
               durationMs: song.duration > 0 ? Int(song.duration * 1000) : nil)
    }
}
