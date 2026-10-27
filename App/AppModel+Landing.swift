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
            let slot = player.queue.upNext.first { $0.song.id == song.id } ?? player.queue.current
            guard let entry = slot?.id else { return }
            playNowBanner = PlayNowBanner(request: id, song: song, entry: entry)
        }
    }

    /// The banner while its song isn't playing yet and is still in the queue.
    var visibleBanner: PlayNowBanner? {
        guard let banner = playNowBanner else { return nil }
        let queue = player.queue
        if queue.current?.id == banner.entry { return player.isPlaying ? nil : banner }
        return queue.upcoming.contains { $0.id == banner.entry } ? banner : nil
    }

    /// "Play now": the find plays now; what was queued after it stays.
    func playNow(_ banner: PlayNowBanner) {
        playNowBanner = nil
        let queue = player.queue
        if queue.current?.id == banner.entry {
            if !player.isPlaying { player.toggle() }
        } else if queue.upcoming.contains(where: { $0.id == banner.entry }) {
            player.move(id: banner.entry, to: 0)
            player.next()
            if !player.isPlaying { player.toggle() }
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
        player.next()
        if !player.isPlaying { player.toggle() }
    }
}
