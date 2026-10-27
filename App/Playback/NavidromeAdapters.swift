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

/// D29: which songs are finds, for the player's scrobble guard. Read on every scrobble. A song is a find when
/// it is in the Finds library: by its library id (native API songs; authoritative when present) or, since
/// Subsonic songs carry none, by being one of the Finds library's songs as last read (or saved from an earlier
/// read).
///
/// Fails closed (fix 6.2a-1): while a Finds library is set but its songs are not known yet (cold or offline
/// start, never read), every song without a library id counts as a find and is not scrobbled.
///
/// Keep (Task 6.2b): a song found in the main library after Keep (`markKept`) is not a find, even where a stale
/// read of the Finds library or the fail-closed rule would say so (Navidrome keeps the song id across the move).
final class FindsIdentity: Sendable {
    private struct State {
        var libraryId: Int?
        /// Nil: not known yet.
        var songIds: Set<String>?
        /// Song ids confirmed in the main library after Keep.
        var kept: Set<String> = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// `songIds` nil: the Finds library's songs aren't known yet. Kept songs are remembered while the Finds
    /// library stays the same.
    func set(libraryId: Int?, songIds: Set<String>?) {
        lock.withLock {
            let kept = $0.libraryId == libraryId ? $0.kept : []
            $0 = State(libraryId: libraryId, songIds: libraryId == nil ? nil : songIds, kept: kept)
        }
    }

    /// The song was found in the main library after Keep.
    func markKept(_ songId: String) {
        lock.withLock { _ = $0.kept.insert(songId) }
    }

    func isFind(_ song: Song) -> Bool {
        lock.withLock { s in
            guard let libraryId = s.libraryId else { return false }
            if let songLibrary = song.libraryId { return songLibrary == libraryId }
            if s.kept.contains(song.id) { return false }
            guard let known = s.songIds else { return true }
            return known.contains(song.id)
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
