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
///
/// Security FM2: the song of a Finds-mode request that is ready counts as a find from the moment the request is
/// known ready (`markLanded`, `setRequestFinds`), before any read of the Finds library lists it, so a find that
/// lands and plays at once is never sent as now playing. That holds without a Finds library id too (fail closed).
final class FindsIdentity: Sendable {
    private struct State {
        var libraryId: Int?
        /// Nil: not known yet.
        var songIds: Set<String>?
        /// Song ids confirmed in the main library after Keep.
        var kept: Set<String> = []
        /// Songs of finds that became ready this session (the runner's ready callback).
        var landed: Set<String> = []
        /// Songs of the ready Finds-mode requests (the runner's list).
        var requestFinds: Set<String> = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// `songIds` nil: the Finds library's songs aren't known yet. Kept songs are remembered while the Finds
    /// library stays the same.
    func set(libraryId: Int?, songIds: Set<String>?) {
        lock.withLock {
            let kept = $0.libraryId == libraryId ? $0.kept : []
            $0 = State(libraryId: libraryId, songIds: libraryId == nil ? nil : songIds, kept: kept,
                       landed: $0.landed, requestFinds: $0.requestFinds)
        }
    }

    /// FM2: a find became ready with this song (before its request list or any library read says so).
    func markLanded(_ songId: String) {
        lock.withLock { _ = $0.landed.insert(songId) }
    }

    /// FM2: the songs of the ready Finds-mode requests now.
    func setRequestFinds(_ songIds: Set<String>) {
        lock.withLock { $0.requestFinds = songIds }
    }

    /// Sign-out: nothing of the account is remembered.
    func forgetAccount() {
        lock.withLock { $0 = State() }
    }

    /// The song was found in the main library after Keep.
    func markKept(_ songId: String) {
        lock.withLock { _ = $0.kept.insert(songId) }
    }

    func isFind(_ song: Song) -> Bool {
        lock.withLock { s in
            if let libraryId = s.libraryId, let songLibrary = song.libraryId { return songLibrary == libraryId }
            if s.kept.contains(song.id) { return false }
            if s.landed.contains(song.id) || s.requestFinds.contains(song.id) { return true }
            guard s.libraryId != nil else { return false }
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

/// The streaming quality the next stream URL is built with. Written on the main actor when the network or the
/// preference changes, read on every URL build.
final class QualityBox: Sendable {
    private let lock: OSAllocatedUnfairLock<StreamQuality>
    init(_ quality: StreamQuality) { lock = OSAllocatedUnfairLock(initialState: quality) }
    var value: StreamQuality { lock.withLock { $0 } }
    func set(_ quality: StreamQuality) { lock.withLock { $0 = quality } }
}

/// Stream URLs built against the client's active base address and the current quality. After a failover the app
/// calls `Player.urlsInvalidated()` so queued items pick up the new base.
@MainActor
final class NavidromeStreamURLs: StreamURLProvider {
    let box: ClientBox
    let quality: QualityBox
    /// A downloaded copy of the song, preferred over streaming (Task 13 fills it in).
    let localURL: @MainActor (String) -> URL?

    init(box: ClientBox, quality: QualityBox, localURL: @escaping @MainActor (String) -> URL? = { _ in nil }) {
        self.box = box; self.quality = quality; self.localURL = localURL
    }

    func streamURL(for song: Song) -> URL {
        if let local = localURL(song.id) { return local }
        let q = quality.value
        // The queue is emptied on sign-out, so a missing client only happens in a race; the item fails.
        return box.client?.streamURL(songId: song.id, maxBitRate: q.maxBitRate, format: q.format)
            ?? URL(string: "about:blank")!
    }

    /// The untranscoded stream, nil for a local file. Whether it is a fallback is the player's call (it compares
    /// with the URL the song loaded with, which the quality may have changed from since).
    func originalURL(for song: Song) -> URL? {
        guard localURL(song.id) == nil else { return nil }
        return box.client?.streamURL(songId: song.id, maxBitRate: nil, format: StreamQuality.original.format)
    }
}
