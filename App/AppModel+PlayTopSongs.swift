import AurralKit
import Foundation
import ListenBrainzKit
import MagpieCore
import Observation
import Playback
import Search

/// What an artist page knows of its top songs when Play top songs is tapped (D304).
struct TopSongsPlayRequest {
    var name: String
    var mbid: MBID?
    /// The library songs known now, in order: an artist Lidarr has, their saved fifteen (D303); otherwise the shown
    /// rows' library songs (D104's source, or Popular's list).
    var known: [Song]
    /// `known` is the whole list (Lidarr's fifteen): nothing is filled behind it.
    var complete: Bool
    /// The D104 source the shown rows came from, for its further rows; nil for Popular and Lidarr's list.
    var provider: TopSongsProvider?
}

/// Round 27 A (owner item 1, 2026-11-14: "When you go into an artist, there should be an option to play the top songs. It
/// should start in sequence, but in the queue there should be maximum 15 of the top songs so you can then select to
/// shuffle them."; D304): the songs known at the tap play at once, in order and never shuffled; the rest of the fifteen
/// (`TopSongsToPlay`: Navidrome's top songs, then the source's further library rows) is added behind by the queue
/// builder (`AppModel+Automix`), only while the queue is still these songs. Never a Discover copy or a find; offline only
/// songs on the phone, and nothing is read.
extension AppModel {
    /// The songs Play top songs would start with: the button shows only when there is one (D304).
    func topSongsPlayable(_ known: [Song]) -> [Song] {
        let excluded = mixExclusion()
        return TopSongsToPlay.list([known], discoverSongIds: knownAurralSongIds, discoverLibraries: discoverLibraryIds,
                                   isFind: excluded)
    }

    /// Play top songs. Returns once the first songs are playing (or the "Replace your queue?" question is up); the fill
    /// runs on in the background.
    func playTopSongs(_ request: TopSongsPlayRequest) async {
        var list = topSongsPlayable(request.known)
        if isOffline {
            let onPhone = Set(await offlineCatalog.songs().map(\.id))
            list = list.filter { onPhone.contains($0.id) }
        }
        guard !list.isEmpty else { return }
        queueBuilder.cancel()
        let asked = queueActions.pendingReplace?.id
        play(list, startAt: 0)   // "Ask before replacing the queue" applies, as to any tap to play
        let question = queueActions.pendingReplace.flatMap { $0.id == asked ? nil : $0.id }
        guard !request.complete, !isOffline, list.count < TopSongsToPlay.limit else { return }
        queueBuilder.start { [weak self] generation in
            await self?.fillTopSongs(request, queued: list, question: question, generation: generation)
        }
    }

    private func fillTopSongs(_ request: TopSongsPlayRequest, queued: [Song], question: UUID?, generation: Int) async {
        async let fullRead = topSongsFull(request)
        if let question { await waitForReplaceAnswer(question) }
        let builder = queueBuilder
        // The queue must be these songs (on "Play next" or Cancel they aren't: nothing is added).
        guard builder.isCurrent(generation), player.queue.main.map(\.song.id) == queued.map(\.id) else { return }
        builder.entries = Set(player.queue.main.map(\.id))
        builder.anchor = player.queue.main.last?.id
        let full = await fullRead
        guard builder.isCurrent(generation) else { return }
        var placed: [Song] = []
        _ = await appendToMix(TopSongsToPlay.fill(queued: queued, full: full), placed: &placed, generation: generation)
    }

    /// The whole list in order: what was known, Navidrome's top songs, then the source's further library rows; each read
    /// within `QueueBuilder.readWait` (a slow one adds nothing).
    private func topSongsFull(_ request: TopSongsPlayRequest) async -> [Song] {
        let (wait, sleep, name) = (QueueBuilder.readWait, queueBuilder.sleep, request.name)
        async let navidrome = Deadline.run(wait, sleep: sleep) { @MainActor in
            try await self.request { try await $0.topSongs(artistName: name) }
        }
        async let further = furtherTopSongs(request)
        let tiers = [request.known, (try? await navidrome.get()) ?? [], await further]
        return TopSongsToPlay.list(tiers, discoverSongIds: knownAurralSongIds, discoverLibraries: discoverLibraryIds,
                                   isFind: mixExclusion())
    }

    /// The D104 source's rows past the five shown, as library songs: ListenBrainz's (read to depth 25, at most ten looked
    /// up) or Aurral's (at most six in all). None for Popular, which is Navidrome's list already.
    private func furtherTopSongs(_ request: TopSongsPlayRequest) async -> [Song] {
        guard let mbid = request.mbid, !isOffline else { return [] }
        let shown = Self.topSongsShown
        switch request.provider {
        case .listenBrainz?:
            guard hasListenBrainzToken else { return [] }
            let client = ListenBrainzClient(transport: transport, token: tokenStore.load(), limiter: listenBrainzLimiter)
            let depth = LidarrTopSongs.readDepth(.listenBrainz)
            // Fix round 1 (design M5, review M2): the read and the look-ups together within the builder's deadline.
            let found = await Deadline.run(QueueBuilder.readWait, sleep: queueBuilder.sleep) { @MainActor in
                let recordings = try await client.topRecordingsForArtist(mbid, limit: depth)
                var songs: [Song] = []
                for recording in recordings.dropFirst(shown).prefix(10) {
                    try Task.checkCancellation()
                    if let song = await self.librarySong(for: recording) { songs.append(song) }
                }
                return songs
            }
            return (try? found.get()) ?? []
        case .aurral?:
            let rows = Array(await artistPreviewSongs(mbid, artistName: request.name).dropFirst(shown))
            let copies = await libraryCopies(of: rows.map(ChartSong.init))
            return rows.indices.compactMap { copies[$0] }
        case .library?, nil:
            return []
        }
    }

    /// Waits until "Replace your queue?" (`id`) is answered or dismissed.
    private func waitForReplaceAnswer(_ id: UUID) async {
        while queueActions.pendingReplace?.id == id, !Task.isCancelled {
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = queueActions.pendingReplace?.id } onChange: { resume.resume() }
            }
        }
    }
}
