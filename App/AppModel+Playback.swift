import MagpieCore
import Observation
import Playback

extension AppModel {
    /// What a song streams at right now: Wi-Fi or mobile quality by the network (Low Data Mode counts as mobile).
    var currentStreamQuality: StreamQuality { preferences.playback.quality(for: network.status) }

    static let transcodeHint = "Your server couldn't convert this song; playing the original"
    /// Round 27 P (D278): while a dropped converted stream is picked up (plan §8).
    static let reconnectingHint = "Connection dropped. Picking up where it left off…"

    func dismissPlaybackHint() {
        playbackHint = nil
        playbackHintSongId = nil
    }

    /// Round 27 P (D276, D278): what Now Playing's hint follows: the current song, the last fallback to the original,
    /// and the song whose dropped connection is being picked up.
    struct PlaybackHintInputs: Equatable {
        var current: String?
        var fallback: String?
        var reconnecting: String?
    }

    /// Keeps the stream quality current, and shows the transcode hint when the player falls back to the original
    /// (once per process: one hint is a heads-up, a second is nagging).
    func watchPlaybackQuality() {
        // Round 27 P (D278, D281): a dropped stream is picked up only with a connection, and part-way only where the
        // server says it can start a conversion there (read with the other extensions, once per session).
        player.canReachServer = { [weak self] in
            guard let self else { return false }
            return self.network.status.isConnected && !self.isOffline
        }
        player.startsConversionsPartWay = { [weak self] in self?.advertisedExtensions?.contains("transcodeOffset") ?? false }
        qualityBox.set(currentStreamQuality)
        qualityWatch = Task { [weak self] in
            guard let network = self?.network else { return }
            let statuses = Observations { @MainActor in network.status }
            for await _ in statuses {
                guard let self else { return }
                let quality = self.currentStreamQuality
                guard quality != self.qualityBox.value else { continue }   // a change that keeps the quality
                self.qualityBox.set(quality)
                self.player.upcomingURLsChanged()
                self.cacheQualityTargetChanged()   // round 13 item 7
            }
        }
        hintWatch = Task { [weak self, player] in
            let inputs = Observations { @MainActor in
                PlaybackHintInputs(current: player.queue.current?.song.id, fallback: player.lastFallbackSongId,
                                   reconnecting: player.reconnectingSongId)
            }
            var previous: PlaybackHintInputs?
            for await now in inputs {
                guard let self else { return }
                self.playbackHintInputsChanged(now, previous: previous)
                previous = now
            }
        }
    }

    /// Round 27 P (owner item 10, D276): the hint belongs to the song it was raised for. When another song becomes
    /// current it goes, at once and without a word (no animation, no announcement). The pick-up hint (D278) shows while
    /// the player picks the current song up and goes when sound arrives. The transcode hint still shows once a process.
    private func playbackHintInputsChanged(_ now: PlaybackHintInputs, previous: PlaybackHintInputs?) {
        if let previous, previous.current != now.current, playbackHint != nil, playbackHintSongId != now.current {
            playbackHint = nil
            playbackHintSongId = nil
        }
        if let song = now.reconnecting, song == now.current {
            playbackHint = Self.reconnectingHint
            playbackHintSongId = song
        } else if playbackHint == Self.reconnectingHint {
            playbackHint = nil
            playbackHintSongId = nil
        }
        if let song = now.fallback, song != previous?.fallback, !shownTranscodeHint {
            shownTranscodeHint = true
            playbackHint = Self.transcodeHint
            playbackHintSongId = song
        }
        readTranscodeOffsetIfStreaming()
    }

    /// Round 27 P (D278, D281): once a converted stream plays, learn whether the server starts conversions part-way
    /// (`transcodeOffset`), with the other extensions, once a session (`serverAdvertises` keeps the answer).
    private func readTranscodeOffsetIfStreaming() {
        guard advertisedExtensions == nil, session != nil, let url = player.currentURL, !url.isFileURL,
              url.scheme == "http" || url.scheme == "https", !NavidromeStreamURLs.isOriginalStream(url) else { return }
        Task { [weak self] in _ = try? await self?.serverAdvertises("transcodeOffset") }
    }
}
