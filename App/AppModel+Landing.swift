import Foundation
import MagpieCore
import Playback
import Requests

/// The in-app "Play now" banner (D6): the ready find went next in the queue instead of cutting in.
struct PlayNowBanner: Equatable {
    var request: RequestID
    var song: Song
    /// The queue slot the find went into.
    var entry: UUID
    /// The queue was idle: the find became the current song, loaded but not playing.
    var idle = false
}

/// What `watchBanner` follows.
private struct BannerState: Equatable, Sendable {
    var current: UUID?
    var playing: Bool
}

enum LandingCopy {
    static let playNow = "Play now"
    static let upNext = "Next in your queue"

    static func title(_ song: Song) -> String { "\(song.title) is ready" }
}

/// D6, one landing rule (`LandingRule`): a find that just became ready plays at once only while the owner is still
/// on its wait screen (the app in the foreground) and nothing else is playing. Otherwise it goes next in the queue,
/// never cutting in, and the "Play now" banner offers it. Patient requests ("Ask for it", D8) don't land: they
/// show up in Finds or the library when they're home.
extension AppModel {
    func waitScreenAppeared(_ id: RequestID) { waitScreens[id, default: 0] += 1 }

    func waitScreenDisappeared(_ id: RequestID) {
        let left = (waitScreens[id] ?? 0) - 1
        waitScreens[id] = left > 0 ? left : nil
    }

    func isOnWaitScreen(_ id: RequestID) -> Bool { isForeground && waitScreens[id] != nil }

    /// A request just became ready: its library song lands by the rule.
    func land(_ request: MagpieRequest) async {
        guard request.tier != .patient, !landedRequests.contains(request.id),
              let song = await readySong(request) else { return }
        land(song, request: request.id)
    }

    /// Lands `song` for request `id` (once per request).
    func land(_ song: Song, request id: RequestID) {
        guard landedRequests.insert(id).inserted else { return }
        guard player.queue.current?.song.id != song.id else { return }   // playing it already
        switch LandingRule.landing(waitingOnScreen: isOnWaitScreen(id), playing: player.isPlaying) {
        case .play:
            playNow(song)
        case .queueNextWithBanner:
            player.playNext([song])
            let queued = player.queue.upNext.first { $0.song.id == song.id }
            guard let entry = (queued ?? player.queue.current)?.id else { return }
            playNowBanner = PlayNowBanner(request: id, song: song, entry: entry, idle: queued == nil)
        }
    }

    /// The banner while its song is still to come: upcoming in the queue, or (an idle queue's landing) loaded and
    /// never played yet. Once its slot is reached and plays, `watchBanner` clears it, so a find paused later never
    /// hides the mini player.
    var visibleBanner: PlayNowBanner? {
        guard let banner = playNowBanner else { return nil }
        let queue = player.queue
        if queue.current?.id == banner.entry { return banner.idle && !player.isPlaying ? banner : nil }
        return queue.upcoming.contains { $0.id == banner.entry } ? banner : nil
    }

    /// Clears the banner the first time its queue slot is current and playing (reached normally, or Play).
    func watchBanner() {
        bannerWatch = Task { [weak self, player] in
            let states = Observations { @MainActor in BannerState(current: player.queue.current?.id, playing: player.isPlaying) }
            for await state in states {
                guard let self else { return }
                if state.playing, let banner = self.playNowBanner, banner.entry == state.current {
                    self.playNowBanner = nil
                }
            }
        }
    }

    /// "Play now": the find plays now; what was queued after it stays.
    func playNow(_ banner: PlayNowBanner) {
        playNowBanner = nil
        let queue = player.queue
        if queue.current?.id == banner.entry {
            if !player.isPlaying { player.toggle() }
        } else if queue.upcoming.contains(where: { $0.id == banner.entry }) {
            jump(to: banner.entry)
        } else {
            playNow(banner.song)   // taken out of the queue meanwhile: put it back and play it
        }
    }

    func dismissBanner() { playNowBanner = nil }

    /// The wait screen's Play: the find plays now (through its banner when it went next in the queue, so it isn't
    /// queued twice), or resumes when it's the song already loaded.
    func playReady(_ song: Song, request id: RequestID) {
        landedRequests.insert(id)
        if let banner = playNowBanner, banner.request == id { return playNow(banner) }
        if player.queue.current?.song.id == song.id {
            if !player.isPlaying { player.toggle() }
            return
        }
        playNow(song)
    }

    /// Plays `song` now: an idle queue starts with it; otherwise it goes in ahead of everything and plays, and the
    /// rest of the queue stays after it.
    private func playNow(_ song: Song) {
        guard player.queue.current != nil else { return play([song], startAt: 0) }
        player.playNext([song])
        guard let entry = player.queue.upNext.first?.id else { return }
        jump(to: entry)
    }

    /// Makes the upcoming slot `entry` current and plays it. A paused song it would skip past isn't dropped into
    /// what has played: it goes back right after the find (from its start; the player keeps no position for a song
    /// that isn't current).
    private func jump(to entry: UUID) {
        let paused = player.isPlaying ? nil : player.queue.current
        player.move(id: entry, to: 0)
        player.next()
        if let paused, player.queue.current?.id == entry {
            player.remove(id: paused.id)
            player.playNext([paused.song])
        }
        if !player.isPlaying { player.toggle() }
    }
}
