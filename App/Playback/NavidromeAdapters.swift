import Foundation
import MagpieCore
import NavidromeKit
import Playback

/// Scrobbles through Navidrome (which forwards to the owner's ListenBrainz/Last.fm).
struct NavidromeScrobbler: Scrobbler {
    let client: NavidromeClient

    func scrobble(songId: String, submission: Bool, at: Date?) async throws {
        try await client.scrobble(songId: songId, submission: submission, at: at)
    }
}

/// Stream URLs built against the client's active base address. After a failover the app calls
/// `Player.urlsInvalidated()` so queued items pick up the new base.
@MainActor
final class NavidromeStreamURLs: StreamURLProvider {
    let client: NavidromeClient
    var maxBitRate: Int?
    var format: String?

    init(client: NavidromeClient, maxBitRate: Int? = nil, format: String? = nil) {
        self.client = client; self.maxBitRate = maxBitRate; self.format = format
    }

    func streamURL(for song: Song) -> URL {
        client.streamURL(songId: song.id, maxBitRate: maxBitRate, format: format)
    }
}
