import Foundation
import MagpieCore

public struct RequestID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }
}

/// How fast a request is likely to arrive (D8, review of D8): Standard when Tubifarry is detected, else Patient.
/// Quick fetch needs the Mac helper and is not in v1.
public enum Tier: String, Codable, Sendable, CaseIterable {
    case quickFetch, standard, patient

    public var title: String {
        switch self {
        case .quickFetch: "Quick fetch"
        case .standard: "Standard"
        case .patient: "Patient"
        }
    }

    /// The honest estimate shown before and while waiting.
    public var estimate: String {
        switch self {
        case .quickFetch: "usually under a minute"
        case .standard: "usually a few minutes"
        case .patient: "can take a few hours"
        }
    }

    /// D8: waits over ~10 minutes get "Ask for it" and no spinning wait screen.
    public var asksInsteadOfWaiting: Bool { self == .patient }
}

/// One Try: a song the owner asked Magpie to bring home, and the bookkeeping the runner needs to resume it
/// after a relaunch. Everything here is persisted (`RequestStore`).
public struct MagpieRequest: Sendable, Codable, Equatable, Identifiable {
    public var id: RequestID
    public var recording: ExternalRecording
    public var state: RequestState
    public var tier: Tier
    public var createdAt: Date
    /// The release being brought in (known once resolved).
    public var albumTitle: String?

    public var updatedAt: Date
    public var plan: Plan?
    /// R19 "Try this album": the release group to bring in, instead of the smallest one holding the song.
    public var albumTarget: MBID?
    public var lidarrArtistId: Int?
    public var albumId: Int?
    /// Root folder the artist was added to (new-artist branch), for the ledger.
    public var root: String?
    /// `POST /artist` was sent for this request. Set (and saved) before the write, so after a relaunch the
    /// artist is never mistaken for one the owner already had.
    public var addSent: Bool = false
    /// When `POST /artist` was sent. Lidarr applies `albumsToMonitor` only when its refresh of the new artist
    /// finishes, so for a while after this the album's monitored flag isn't final.
    public var addedAt: Date?
    /// Another request already asked for this release group; this one only follows it and never writes (G7).
    public var joinedTo: RequestID?
    /// The add already started the search (`searchForMissingAlbums`) or a joined request: skip the next AlbumSearch.
    public var skipNextSearch: Bool = false
    /// Runner contract of `RequestMachine.step`: the current waiting episode's reason, nil after forward progress.
    public var priorWait: WaitReason?
    public var searchStartedAt: Date?
    public var searchCommandId: Int?
    public var grabbed: Bool = false
    /// Date of the newest download failure already acted on.
    public var failureSeenAt: Date?
    public var lastScanAt: Date?
    /// When the request last entered `importing`.
    public var importingSince: Date?
    /// Set when the library still didn't list the song `RequestRunner.importingLimit` after import: the
    /// library is no longer polled for it until the owner taps Check again.
    public var notListedAt: Date?
    /// The library song once Navidrome lists it.
    public var songId: String?
    /// Cancel/fail clean-up (unmonitor) still to do.
    public var cleanupPending: Bool = false
    /// Lidarr's latest status message for the download, if any (display only).
    public var note: String?
    /// Finds mode was on, but the Finds root no longer checked out when the artist was added (G2): the song
    /// went into the library instead (B8).
    public var findsUnavailable: Bool {
        get { findsFellBack ?? false }
        set { findsFellBack = newValue ? true : nil }
    }
    /// Stored optional, so requests saved before Task 6.2a (no such key) still decode.
    var findsFellBack: Bool?

    // Keep (Task 6.2b). All optional, so requests saved before it still decode.

    /// A Keep that wrote to Lidarr and isn't settled yet (saved before the write, M6). While set, Keep never
    /// writes the move again: the runner only checks how it went (`RequestRunner.keep`, `tick`).
    public var keep: KeepProgress?
    /// Kept where it is: the main root already had a folder for the artist, so only `magpie-find` came off (G4).
    public var keptInPlace: Bool {
        get { stayedInFinds ?? false }
        set { stayedInFinds = newValue ? true : nil }
    }
    var stayedInFinds: Bool?
    /// The last Keep didn't go through (Lidarr couldn't move it); the find is as it was and can be kept again.
    public var keepFailed: Bool {
        get { lastKeepFailed ?? false }
        set { lastKeepFailed = newValue ? true : nil }
    }
    var lastKeepFailed: Bool?
    /// The last Keep couldn't be settled from here (a move that never finished, a find that couldn't be put
    /// back, files that aren't where Lidarr says): it needs the owner's look. The ledger keeps saying kept, so
    /// nothing deletes it and Keep isn't offered again.
    public var keepNeedsAttention: Bool {
        get { keepStuck ?? false }
        set { keepStuck = newValue ? true : nil }
    }
    var keepStuck: Bool?
    /// Lidarr's artist folder after a confirmed move (the kept song is looked up there, A3).
    public var movedTo: String?
    /// Kept and moved: the library song is looked up again by MBID (A3). False once found or given up; nil
    /// for requests that never moved.
    public var relinkPending: Bool?
    /// When the move was confirmed (the re-resolve gives up `RequestRunner.relinkLimit` after it).
    public var movedAt: Date?
    /// The library song's file type once re-resolved after Keep ("Lossless soon" until it is lossless).
    public var songSuffix: String?

    // Not for me (Task 6.2c). Optional, so requests saved before it still decode.

    /// A Not for me under way: saved before its first Lidarr write (M6). While set, every step is proven again
    /// from fresh Lidarr state before it is sent; nothing is ever sent on the saved state alone.
    public var notForMe: NotForMeProgress?
    /// Not for me couldn't finish from here (Lidarr refused part of it, or it couldn't be proven safe to go on):
    /// it needs the owner's look. Nothing more is deleted, and neither Keep nor Not for me is offered again.
    public var notForMeNeedsAttention: Bool {
        get { letGoStuck ?? false }
        set { letGoStuck = newValue ? true : nil }
    }
    var letGoStuck: Bool?

    // Bring in more (security FL4). Optional, so requests saved before it still decode.

    /// Releases a Bring in more from this kept find monitored and searched that haven't arrived yet. Each counts
    /// toward the limit of 5 (G7) like a request on its way, until Lidarr has files for it, it is no longer
    /// monitored, or `RequestMachine.giveUpAfter` has passed since `bringInAt`. Nil: none.
    public var bringingIn: [Int]?
    /// When the latest Bring in more of this find was sent.
    public var bringInAt: Date?

    // Stalled Soulseek downloads and Search again (R17, RequestRunner+Stall.swift). Optional, so older requests decode.

    /// Stalled downloads removed and searched again automatically (at most `RequestRunner.maxStallRetries`); Search
    /// again starts the count over.
    public var stallRetries: Int?
    /// When Magpie last gave up on a stalled download for it ("That copy stopped coming. Looking for another…").
    public var sourceStalledAt: Date?
    /// When Search again last ran for it (once per `RequestRunner.searchAgainInterval`).
    public var searchAgainAt: Date?

    // Y5 (Find → Add). Optional, so older requests decode.

    /// After the Keep's commit: the lossless search, the upgrade watch and the MP3 rule (`RequestRunner+Lossless`).
    public var lossless: LosslessWatch?
    /// The MP3 couldn't be removed safely (no mapping, a changed size, a refusal): "Couldn't remove the MP3".
    public var mp3NeedsAttention: Bool {
        get { mp3Stuck ?? false }
        set { mp3Stuck = newValue ? true : nil }
    }
    var mp3Stuck: Bool?
    /// C1: the main root already has a folder of the artist's name, so Add to your library refused (nothing written).
    public var collision: Bool {
        get { folderTaken ?? false }
        set { folderTaken = newValue ? true : nil }
    }
    var folderTaken: Bool?
    /// The search's start in Lidarr's time (item 9.7): the history filter compares Lidarr's dates with it.
    public var searchStartedAtServer: Date?
    /// The highest `/command` id before `POST /artist` (item 9.8): only a later RefreshArtist naming the artist counts.
    public var addCommandBaseline: Int?
    /// That RefreshArtist completed (I12): only after it may an album's absence mean something.
    public var addRefreshDone: Bool?
    /// The album was listed by Lidarr at least once (I12/6: `stoppedInLidarr` needs that).
    public var albumSeen: Bool?

    // Round 15 C3 (owner item 6, D135, D139). Optional, so older requests decode.

    /// "Add to library" (permanent). A new artist goes into the main root with the whole discography monitored and the
    /// lossless-preferred profile (this release searched first, the rest after); a find is kept on arrival (moved into
    /// the main library); an artist already in the library has this release monitored and searched.
    public var addToLibrary: Bool {
        get { intoLibrary ?? false }
        set { intoLibrary = newValue ? true : nil }
    }
    var intoLibrary: Bool?
    /// Asked for with round 15's Try (temporary, Keep or Reject). On an artist already in the main library (no Finds
    /// folder for one release, D139) the release is a trial there: `isLibraryTrial`.
    public var askedAsTry: Bool {
        get { tryOnly ?? false }
        set { tryOnly = newValue ? true : nil }
    }
    var tryOnly: Bool?
    /// Add to library of a new artist: the search for the rest of the discography was sent (after this release's).
    public var discographySearched: Bool?
    /// The artist was in Lidarr, not as a find, when this was resolved (the existing-artist branch).
    public var artistExisted: Bool?
    /// A trial on a library artist that was kept: the mark is cleared, the release stays.
    public var trialKept: Bool?
    /// D147: the ledger recorded this release as a trial (unmonitored, no files, when Magpie monitored it); when it ends.
    public var trialExpiresAt: Date?
    /// D147: Reject went through (the release's files deleted, the album unmonitored).
    public var trialRejected: Bool?
    /// Round 16: when the stopped find's clean-up started looking at removing its artist from Lidarr (the last find of
    /// an artist Magpie added into the Finds folder); it gives up after `RequestRunner.stoppedFindArtistLimit`.
    public var artistRemovalSince: Date?
    /// D136 (review M2): a new artist's Add to library: the owner's Add-defaults metadata profile and following.
    public var libraryMetadataProfileId: Int?
    public var libraryFollow: Bool?

    // Round 17 (owner, 2026-11-05): when the release Lidarr was asked for can't be found, the next one holding the song.
    // Optional, so older requests decode.

    /// The other release groups holding the song, best first (`ReleasePicker.ordered`), not tried yet.
    public var releaseAlternates: [MBID]?
    /// The release groups already tried for this request (none of them brought it in).
    public var releasesTried: [MBID]?
    /// The find's artist was moved to "Magpie Finds Any Format" (no MP3 of a release was found), or that couldn't be
    /// done (false): either way the MP3-only step is over for this request.
    public var anyFormat: Bool?

    // Round 18 (owner, 2026-11-05): a song's Try keeps only that song. Optional, so older requests decode.

    /// Asked for one song (not "Try this album") from round 18 on: once it is ready, the other songs of the release it
    /// came on leave the Finds folder (`RequestRunner+OnlyTheSong`). Requests from before are never trimmed.
    public var onlyTheSong: Bool?
    /// The trim is over: the other songs went, or they stay for good (kept, let go, not matched, out of tries).
    public var trimDone: Bool?
    /// Trims that couldn't finish (a refusal, no answer); bounded by `RequestRunner.trimTryLimit`.
    public var trimTries: Int?
    /// Round 19: the trim unmonitored the album (it had other songs); a Keep monitors it again for its lossless upgrade.
    public var trimUnmonitored: Bool?

    // Round 19 (owner, 2026-11-05: popular singles). Optional, so older requests decode.

    /// The song is only on soundtrack or remix releases: a new artist is added with "Magpie Finds Extras" (Soundtrack and
    /// Remix beside Studio), so Lidarr lists that release.
    public var findsExtras: Bool?

    public init(id: RequestID = RequestID(), recording: ExternalRecording, tier: Tier, createdAt: Date) {
        self.id = id
        self.recording = recording
        self.state = .pending
        self.tier = tier
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Counts toward the limit of 5 (G7) and is polled: not finished and not yet ready.
    public var isActive: Bool { !state.isTerminal && state != .ready }

    /// Whether Activity may remove it (security FL6): finished or ready, with no clean-up owed, no Keep or Not for me
    /// still going or needing a look, no kept song still being looked up, and nothing Bring in more is still
    /// bringing in. Removing any of those would drop their follow-up (a failed move's put-back, the relink).
    /// Round 18: never a ready find. Forgetting it left its songs in the Finds folder with no way to let them go.
    public var canBeRemoved: Bool {
        !isActive && !(state == .ready && isFind) && !cleanupPending && keep == nil && notForMe == nil && !keepNeedsAttention
            && !notForMeNeedsAttention && relinkPending != true && (bringingIn ?? []).isEmpty
            && !(lossless?.isActive ?? false) && !mp3NeedsAttention
    }

    /// How many places this request takes in the limit of 5 (G7): one while on its way, plus each release Bring in
    /// more is still bringing in (FL4).
    public var activePlaces: Int { (isActive ? 1 : 0) + (bringingIn?.count ?? 0) }

    /// Headed for (or added to) the Finds folder: a new artist added in Finds mode (Task 6.2a).
    public var isFind: Bool { plan?.mode == .finds }

    /// Round 15 C3 (D139): a Try of a release of an artist already in the main library: it comes into the main library,
    /// marked as a trial (Keep clears the mark; Reject removes only that release).
    public var isLibraryTrial: Bool {
        askedAsTry && !addToLibrary && trialExpiresAt != nil && !isFind && trialKept != true && trialRejected != true
    }

    /// Imported by Lidarr but not listed by the library after the time limit (Needs attention).
    public var isNotListed: Bool { state == .importing && notListedAt != nil }
}

/// A Keep in flight (Task 6.2b), saved before its first Lidarr write so a relaunch never writes it twice.
public struct KeepProgress: Sendable, Codable, Equatable {
    public enum Phase: String, Sendable, Codable {
        /// `PUT /artist/editor` with the main root was (maybe) sent: wait for `BulkMoveArtist` (A3).
        case moving
        /// The destination existed: only `magpie-find` is being removed (G4).
        case untagging
        /// The move failed: `magpie-find` and the earlier quality profile are being put back.
        case restoring
        /// Y5: the intent is saved (ledger `keepIntentAt`) and nothing is sent yet: it goes when Lidarr is free
        /// ("Adding when your server is free…", item 9.5).
        case queued
    }

    public var phase: Phase
    public var startedAt: Date
    public var artistId: Int
    /// The artist folder before the move (inside the Finds root).
    public var fromPath: String
    public var findsRoot: String
    public var mainRoot: String
    public var findTagId: Int
    /// The artist's quality profile before Keep, to put back if the move fails.
    public var priorQualityProfileId: Int?
    /// The highest `/command` id Lidarr listed before the move was asked for: only later ones are this move.
    public var commandBaseline: Int
    public var lastCheckAt: Date?
    /// When the move first looked finished but the track files weren't all in the main root yet (Lidarr updates
    /// track file paths shortly after the command completes): they get `RequestRunner.keepStartGrace` to settle.
    public var filesUnsettledSince: Date?
    /// Restore writes sent so far (bounded by `RequestRunner.keepRestoreLimit`).
    public var restoreAttempts: Int?
    /// Lidarr saved the main root as the artist path but the files never left `fromPath`: the restore also
    /// points the artist back at the Finds root, without moving files.
    public var revertPath: Bool?
    /// Y5 (I2): when the PUT was sent (saved just before it): the start grace and the move limit count from here.
    public var sentAt: Date?
    /// The time the move limits count from.
    public var since: Date { sentAt ?? startedAt }

    public init(phase: Phase, startedAt: Date, artistId: Int, fromPath: String, findsRoot: String, mainRoot: String,
                findTagId: Int, priorQualityProfileId: Int?, commandBaseline: Int) {
        self.phase = phase; self.startedAt = startedAt; self.artistId = artistId; self.fromPath = fromPath
        self.findsRoot = findsRoot; self.mainRoot = mainRoot; self.findTagId = findTagId
        self.priorQualityProfileId = priorQualityProfileId; self.commandBaseline = commandBaseline
    }
}

/// Y5 (§5): after a Keep, Magpie asks for the lossless copy, watches for it, and (only for a Keep the owner tapped,
/// C2) removes the MP3 after the deadline. Times are Lidarr's (item 9.7).
public struct LosslessWatch: Sendable, Codable, Equatable {
    /// The find's albums.
    public var albumIds: [Int]
    public var startedAt: Date
    /// A Y5 owner-tapped Keep: the MP3 goes at `deadline`. Adopted, hand-moved and older kept finds: never (C2).
    public var autoDelete: Bool
    public var deadline: Date?
    public var searches: Int = 0
    public var lastSearchAt: Date?
    public var lastCheckAt: Date?
    /// The MP3 is gone (a read showed it, never claimed without one).
    public var removedAt: Date?
    /// Every track of the find is lossless now.
    public var losslessAt: Date?
    /// The watch ended: lossless, or 30 days (I5).
    public var doneAt: Date?
    /// Fix I8: the ledger holds the find's file record, so "Remove the MP3 now" can work (nil: older, no record).
    public var hasRecord: Bool?
    /// Fix I5: the removal's RefreshArtist, sent and not yet seen completed (checked on later passes).
    public var refreshCommandId: Int?
    public var refreshSentAt: Date?

    public init(albumIds: [Int], startedAt: Date, autoDelete: Bool, deadline: Date?) {
        self.albumIds = albumIds; self.startedAt = startedAt; self.autoDelete = autoDelete; self.deadline = deadline
    }

    public var isActive: Bool { doneAt == nil }
}

/// A Not for me in flight (Task 6.2c), saved before its first Lidarr write so a relaunch picks it up and proves
/// each remaining step again before sending it.
public struct NotForMeProgress: Sendable, Codable, Equatable {
    public enum Phase: String, Sendable, Codable {
        /// `DELETE /trackfile/bulk` (or one file at a time) for the album's files (A16).
        case deleting
        /// `PUT /album/monitor {monitored: false}` (A16).
        case unmonitoring
        /// `DELETE /artist/{id}?deleteFiles=false&addImportListExclusion=false`, only when nothing is left (A16).
        case removingArtist
    }

    public var phase: Phase
    public var startedAt: Date
    public var artistId: Int
    public var albumId: Int
    /// The artist folder proven inside the Finds root before the first write: every later step needs the same.
    public var artistPath: String
    public var findsRoot: String
    public var mainRoot: String
    public var findTagId: Int
    /// The owner confirmed "This deletes the files permanently." (Lidarr's recycle bin was unset).
    public var permanentConfirmed: Bool
    /// A write was sent (or may have been): from here a refusal needs the owner's look instead of undoing nothing.
    public var sent: Bool
    /// Lidarr answered the bulk delete with 404 / 405: one track file at a time from now on.
    public var oneByOne: Bool?
    /// Writes sent so far, bounded by `writeBudget`.
    public var writes: Int
    public var writeBudget: Int
    /// Writes whose answer never came, bounded by `RequestRunner.notForMeUnansweredLimit`.
    public var unanswered: Int
    public var lastCheckAt: Date?

    public init(phase: Phase, startedAt: Date, artistId: Int, albumId: Int, artistPath: String, findsRoot: String,
                mainRoot: String, findTagId: Int, permanentConfirmed: Bool, writeBudget: Int) {
        self.phase = phase; self.startedAt = startedAt; self.artistId = artistId; self.albumId = albumId
        self.artistPath = artistPath; self.findsRoot = findsRoot; self.mainRoot = mainRoot; self.findTagId = findTagId
        self.permanentConfirmed = permanentConfirmed; self.sent = false; self.writes = 0
        self.writeBudget = writeBudget; self.unanswered = 0
    }
}

public enum RequestStoreError: Error, Equatable {
    /// The file exists but cannot be read right now (protected data before first unlock). Nothing is written
    /// until it can be read, so in-flight requests are never lost.
    case unavailable
}

/// The requests on disk (`Application Support/Magpie/requests.json`), written atomically with file protection.
public actor RequestStore {
    /// `Application Support/Magpie/requests-<instance>.json`: one file per Lidarr server
    /// (`LidarrClient.instanceScope`), so requests never cross servers.
    public static func defaultURL(in directory: URL = URL.applicationSupportDirectory, instance: String) -> URL {
        directory.appending(path: "Magpie/requests-\(instance).json")
    }

    nonisolated let fileURL: URL?
    private var memory: [MagpieRequest] = []

    /// `fileURL` nil keeps the requests in memory only.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// The saved requests; empty when there are none. A damaged file is moved aside and an empty list returned.
    public func load() throws -> [MagpieRequest] {
        guard let fileURL else { return memory }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw RequestStoreError.unavailable }
        do {
            return try JSONDecoder().decode([MagpieRequest].self, from: data)
        } catch {
            let aside = fileURL.deletingLastPathComponent()
                .appending(path: "\(fileURL.lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970))")
            do { try FileManager.default.moveItem(at: fileURL, to: aside) } catch { throw RequestStoreError.unavailable }
            Log.logger("requests").error("damaged requests file; kept aside, starting empty")
            return []
        }
    }

    public func save(_ requests: [MagpieRequest]) throws {
        guard let fileURL else { memory = requests; return }
        try AtomicFile.write(requests, to: fileURL)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = fileURL
        try? file.setResourceValues(values)
    }

    /// Forgets every request (sign-out). The Lidarr ledger is kept: it is the owner's undo map.
    public func erase() {
        memory = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Sign-out (V-fix): removes the requests of every Lidarr in `directory` (`requests-<instance>.json`, and copies
    /// of a damaged one kept aside), not only the connected one's. Call with no runner using them.
    public static func eraseAll(in directory: URL = URL.applicationSupportDirectory) {
        let folder = defaultURL(in: directory, instance: "x").deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // Round 14 A3 (D101): the playlist adds waiting for their songs go with the requests; round 15 C3 (D138): so do
        // the rejected finds' playlist clean-ups and their history.
        for name in names where (name.hasPrefix("requests-") || name.hasPrefix("runner-state-")
                                 || name.hasPrefix("playlist-adds-") || name.hasPrefix("find-cleanups-") || name.hasPrefix("singles-switch-"))
                                && name.contains(".json") {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}
