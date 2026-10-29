import MagpieCore
import Observation
import Playback

extension AppModel {
    /// What a song streams at right now: Wi-Fi or mobile quality by the network (Low Data Mode counts as mobile).
    var currentStreamQuality: StreamQuality { preferences.playback.quality(for: network.status) }

    static let transcodeHint = "Your server couldn't convert this song; playing the original"

    func dismissPlaybackHint() { playbackHint = nil }

    /// Keeps the stream quality current, and shows the transcode hint when the player falls back to the original
    /// (once per process: one hint is a heads-up, a second is nagging).
    func watchPlaybackQuality() {
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
            }
        }
        hintWatch = Task { [weak self, player] in
            let fallbacks = Observations { @MainActor in player.lastFallbackSongId }
            for await songId in fallbacks where songId != nil {
                guard let self else { return }
                guard !self.shownTranscodeHint else { continue }
                self.shownTranscodeHint = true
                self.playbackHint = Self.transcodeHint
            }
        }
    }
}
