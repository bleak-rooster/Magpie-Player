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

/// The streaming quality the next stream URL is built with. Written on the main actor when the network or the
/// preference changes, read on every URL build.
final class QualityBox: Sendable {
    private let lock: OSAllocatedUnfairLock<StreamQuality>
    init(_ quality: StreamQuality) { lock = OSAllocatedUnfairLock(initialState: quality) }
    var value: StreamQuality { lock.withLock { $0 } }
    func set(_ quality: StreamQuality) { lock.withLock { $0 = quality } }
}

/// The ReplayGain mode songs are levelled with. Written on the main actor when the preference changes, read
/// for every song sent to the engine.
final class ReplayGainBox: Sendable {
    private let lock: OSAllocatedUnfairLock<ReplayGainMode>
    init(_ mode: ReplayGainMode) { lock = OSAllocatedUnfairLock(initialState: mode) }
    var mode: ReplayGainMode { lock.withLock { $0 } }
    func set(_ mode: ReplayGainMode) { lock.withLock { $0 = mode } }
}

/// The songs on the phone (downloads and cache), by song id: what `DownloadManager.localFiles` last said. The player
/// is built before the model (and its manager) exist, so stream URLs read the files from here; empty when signed out.
///
/// A file that failed to play is left out for the rest of the session (it streams instead), until the store no longer
/// lists it (it was dropped; a fresh download of it counts again). Only a damaged one is handed to `onDamaged`, which
/// checks it and may drop it; any other failure keeps the file.
final class LocalFilesBox: Sendable {
    private struct State {
        var files: [String: URL] = [:]
        var bad: Set<String> = []
        var onDamaged: (@MainActor @Sendable (String) -> Void)?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// The file to play `songId` from. One that failed this session is left out (it streams instead), except
    /// `includingFailed` (offline: there is nothing to stream, so every file on the phone is tried).
    func url(for songId: String, includingFailed: Bool = false) -> URL? {
        lock.withLock { !includingFailed && $0.bad.contains(songId) ? nil : $0.files[songId] }
    }

    /// Whether `songId` is on the phone (a download or in the cache), whether or not its file failed this session.
    func hasFile(_ songId: String) -> Bool { lock.withLock { $0.files[songId] != nil } }

    func set(_ files: [String: URL]) {
        lock.withLock {
            $0.files = files
            $0.bad = $0.bad.filter { files[$0] != nil }
        }
    }

    func setOnDamaged(_ handler: (@MainActor @Sendable (String) -> Void)?) { lock.withLock { $0.onDamaged = handler } }

    /// The file of `songId` failed to play (`damaged`: a format or decode error).
    @MainActor func markFailed(_ songId: String, damaged: Bool) {
        let handler = lock.withLock { s -> (@MainActor @Sendable (String) -> Void)? in
            s.bad.insert(songId)
            return damaged ? s.onDamaged : nil
        }
        handler?(songId)
    }
}

/// Stream URLs built against the client's active base address and the current quality. After a failover the app
/// calls `Player.urlsInvalidated()` so queued items pick up the new base.
@MainActor
final class NavidromeStreamURLs: StreamURLProvider {
    let box: ClientBox
    let quality: QualityBox
    /// The song's file on the phone, preferred over streaming (Task 13): it plays with no network.
    let localURL: @MainActor (String) -> URL?

    /// The song's file failed to play (`damaged`: a decode error), online: the app streams it this session, and
    /// checks a damaged file (dropping it if it really is).
    let localFailed: @MainActor (_ songId: String, _ damaged: Bool) -> Void
    /// Whether the server can be reached right now (a connection, and not offline, Task 14); offline a failed file
    /// is kept and the song skipped, and no original is tried.
    let isOnline: @MainActor () -> Bool
    /// Offline (Task 14): a song not on the phone gets no server URL, so nothing is streamed; it fails and is skipped.
    let isOffline: @MainActor () -> Bool

    init(box: ClientBox, quality: QualityBox, localURL: @escaping @MainActor (String) -> URL? = { _ in nil },
         localFailed: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
         isOnline: @escaping @MainActor () -> Bool = { true }, isOffline: @escaping @MainActor () -> Bool = { false }) {
        self.box = box; self.quality = quality; self.localURL = localURL; self.localFailed = localFailed
        self.isOnline = isOnline; self.isOffline = isOffline
    }

    func streamURL(for song: Song) -> URL {
        if let local = localURL(song.id) { return local }
        if isOffline() { return URL(string: "about:blank")! }
        // The queue is emptied on sign-out, so a missing client only happens in a race; the item fails.
        return remoteURL(for: song) ?? URL(string: "about:blank")!
    }

    private func remoteURL(for song: Song) -> URL? {
        let q = quality.value
        return box.client?.streamURL(songId: song.id, maxBitRate: q.maxBitRate, format: q.format)
    }

    /// Online: the song streams at the current quality instead (and a damaged file is checked). Offline: nil, and
    /// nothing is marked or dropped, so a good download is never lost to a failure that may pass.
    func localFileFailed(_ song: Song, undecodable: Bool) -> URL? {
        guard isOnline(), let remote = remoteURL(for: song) else { return nil }
        localFailed(song.id, undecodable)
        return remote
    }

    /// The untranscoded stream, nil for a local file and offline (no server to ask, so no fallback is tried).
    /// Whether it is a fallback is the player's call (it compares with the URL the song loaded with, which the
    /// quality may have changed from since).
    func originalURL(for song: Song) -> URL? {
        guard isOnline(), localURL(song.id) == nil else { return nil }
        return box.client?.streamURL(songId: song.id, maxBitRate: nil, format: StreamQuality.original.format)
    }

    /// A server stream of the file as it is (`format=raw`, no bit-rate cap), whatever auth it was signed with.
    func isOriginal(_ url: URL) -> Bool {
        guard !url.isFileURL, url.path.hasSuffix("/rest/stream"),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return query.first { $0.name == "format" }?.value == StreamQuality.original.format
            && !query.contains { $0.name == "maxBitRate" }
    }
}
