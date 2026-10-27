import Foundation
import MagpieCore
import NavidromeKit
import os
import Playback

/// The session's current client. `Player` is created once, but the client is replaced on sign-in,
/// sign-out and address failover, so the adapters read it from here on every call.
final class ClientBox: Sendable {
    private let lock = OSAllocatedUnfairLock<NavidromeClient?>(initialState: nil)

    var client: NavidromeClient? { lock.withLock { $0 } }

    func set(_ client: NavidromeClient?) { lock.withLock { $0 = client } }
}

/// G8 "Count plays": whether plays are scrobbled. Read on every scrobble, so the switch takes effect at once.
final class PlayCounting: Sendable {
    private let lock: OSAllocatedUnfairLock<Bool>
    init(on: Bool) { lock = OSAllocatedUnfairLock(initialState: on) }
    var isOn: Bool { lock.withLock { $0 } }
    func set(_ on: Bool) { lock.withLock { $0 = on } }
}

/// D29: which songs are finds, for the player's scrobble guard. A song is a find when it is in the Finds
/// library: by its library id (native API songs) or, since Subsonic songs carry none, by being one of the
/// Finds library's songs as last read. Read on every scrobble.
final class FindsIdentity: Sendable {
    private struct State {
        var libraryId: Int?
        var songIds: Set<String> = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func set(libraryId: Int?, songIds: Set<String>) {
        lock.withLock { $0 = State(libraryId: libraryId, songIds: libraryId == nil ? [] : songIds) }
    }

    func isFind(_ song: Song) -> Bool {
        lock.withLock { s in
            guard let libraryId = s.libraryId else { return false }
            return song.libraryId == libraryId || s.songIds.contains(song.id)
        }
    }
}

/// Scrobbles through Navidrome (which forwards to the owner's ListenBrainz/Last.fm), unless Count plays is off.
struct NavidromeScrobbler: Scrobbler {
    let box: ClientBox
    var counting = PlayCounting(on: true)

    func scrobble(songId: String, submission: Bool, at: Date?) async throws {
        guard counting.isOn else { return }
        guard let client = box.client else { return }   // signed out meanwhile
        try await client.scrobble(songId: songId, submission: submission, at: at)
    }
}

/// Stream URLs built against the client's active base address. After a failover the app calls
/// `Player.urlsInvalidated()` so queued items pick up the new base.
@MainActor
final class NavidromeStreamURLs: StreamURLProvider {
    let box: ClientBox
    var maxBitRate: Int?
    var format: String?

    init(box: ClientBox, maxBitRate: Int? = nil, format: String? = nil) {
        self.box = box; self.maxBitRate = maxBitRate; self.format = format
    }

    func streamURL(for song: Song) -> URL {
        // The queue is emptied on sign-out, so a missing client only happens in a race; the item fails.
        box.client?.streamURL(songId: song.id, maxBitRate: maxBitRate, format: format)
            ?? URL(string: "about:blank")!
    }
}
