import Foundation
import LidarrKit
import MagpieCore
import os

// Round 24 (owner, 2026-11-08, item 10): "Lidarr-monitored artists: change what is monitored (more or less). On reducing,
// ask delete-or-keep; if kept, a later 'Clean up unmatched songs' in the artist's More menu. The owner's own artists are
// in scope." D237 (the change), D238 (only Magpie's profiles), D239 (more: the existing shapes), D240 (reducing asks,
// Keep by default), D241 (the kept set), D242 (the clean-up), D243 (the gate's proofs), D244 (Revert).
//
// Every write is named `ConfinedShape.ownedChange` or `.unmatchedCleanup`; the gate lets it through only as the artist's
// open `MonitoringIntent` in the ledger says (saved before the first write, each step saved before its write, M6), proven
// from its own fresh reads. After a lost answer, Lidarr is read before anything is sent again.

/// What the owner favourited, saved to a playlist or keeps on the phone, read by the app (Navidrome and the phone) when
/// it asks. A file whose song matches (its recording, or its title, or its album's title, folded) is never deleted
/// ("Kept because you favourited it"). Matching loosely only keeps more.
public struct MonitoringKeepList: Sendable, Equatable {
    public var recordings: Set<String>
    public var titles: Set<String>
    public var albumTitles: Set<String>

    public init(recordings: Set<String> = [], titles: Set<String> = [], albumTitles: Set<String> = []) {
        self.recordings = Set(recordings.map { $0.lowercased() })
        self.titles = Set(titles.map(Self.fold).filter { !$0.isEmpty })
        self.albumTitles = Set(albumTitles.map(Self.fold).filter { !$0.isEmpty })
    }

    public var isEmpty: Bool { recordings.isEmpty && titles.isEmpty && albumTitles.isEmpty }

    /// Case, diacritics and width folded, trimmed.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func keeps(recording: String?, title: String?, album: String?) -> Bool {
        if let recording, recordings.contains(recording.lowercased()) { return true }
        if let title, titles.contains(Self.fold(title)) { return true }
        if let album, albumTitles.contains(Self.fold(album)) { return true }
        return false
    }
}

/// D240: the answer to "Delete them now, or keep them?". Keep is the default (the bold button): when in doubt, keep.
public enum ReduceChoice: Sendable, Equatable {
    case keep
    case delete
    public static let `default` = ReduceChoice.keep
}

public enum MonitoringChangeError: Error, Sendable, Equatable {
    /// "Allow Magpie to change your library" is off.
    case changesOff
    /// "Let Magpie change what Lidarr monitors for my artists" is off.
    case switchOff
    /// Lidarr or the ledger couldn't be read: nothing was sent.
    case unavailable
    /// The intent couldn't be saved: nothing was sent.
    case notSaved
    /// Not an artist in the main root folder (a find, or another root): never changed here.
    case notInMainRoot
    /// A change of this artist is under way (or waiting to be finished).
    case busy
    /// No change of Magpie's to put back, or the owner changed the profile since.
    case nothingToRevert
    /// Lidarr changed since the owner looked: ask again.
    case stale
    /// A Try of Magpie's is under way for the artist: nothing is deleted.
    case tryUnderWay
    /// Lidarr has a profile with Magpie's name, set up differently: nothing was written.
    case profileConflict(String)
}

/// Where the artist stands, for the sheet's preset (D237).
public struct MonitoringCurrent: Sendable, Equatable {
    public var artistId: Int
    public var artistName: String
    public var profileId: Int
    /// The choice the artist's profile stands for, when it is one of Magpie's; nil: "Custom (set in Lidarr)".
    public var types: ReleaseTypes?
    /// D244: a change of Magpie's can be put back.
    public var canRevert: Bool
    /// D241: songs kept on reducing are waiting to be cleaned up.
    public var hasKept: Bool
    /// A change is under way or waiting to be finished.
    public var busy: Bool
    /// Fix round 1 I4: the artist's last change (or Revert) stopped partway (refused or given up): said on the page
    /// and in the sheet, with "Put back how it was" when `canRevert`.
    public var stoppedPartway: Bool = false
}

/// What a change would do, read before anything is asked or sent (D240).
public struct MonitoringPreview: Sendable, Equatable {
    public internal(set) var artistId: Int
    public internal(set) var artistName: String
    public internal(set) var artistMbid: MBID
    public internal(set) var currentProfileId: Int
    public internal(set) var currentTypes: ReleaseTypes?
    /// The owner's own profile, recorded so Revert can go back to it.
    public internal(set) var previousProfileId: Int
    public internal(set) var target: ReleaseTypes
    public internal(set) var beforeAlbumIds: [Int]
    /// Monitored albums the new choice doesn't include.
    public internal(set) var unmonitorAlbumIds: [Int]
    /// Every file of those albums.
    public internal(set) var files: [OwnedFile]
    /// Files the owner favourited, saved or keeps on the phone (or whose size Lidarr doesn't say): never deleted.
    public internal(set) var excludedFileIds: [Int]

    public var deletable: [OwnedFile] { files.filter { !excludedFileIds.contains($0.id) } }
    public var albumCount: Int { unmonitorAlbumIds.count }
    public var songCount: Int { files.count }
    public var bytes: Int64 { files.reduce(0) { $0 + max(0, $1.size) } }
    /// Something stops being monitored.
    public var reduces: Bool { !unmonitorAlbumIds.isEmpty }
    /// Files would be left behind: the owner is asked to delete or keep them first.
    public var asksDeleteOrKeep: Bool { !files.isEmpty }
    public var defaultChoice: ReduceChoice { .default }
    /// The artist is already on the profile for this choice and nothing falls out.
    public var changesNothing: Bool { currentTypes == target && !reduces }
}

/// "Clean up unmatched songs" (D242): the kept files whose album is still unmonitored, read fresh.
public struct CleanupPreview: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public internal(set) var file: OwnedFile
        public internal(set) var title: String
        public internal(set) var album: String
        /// The song's recording (Lidarr's), so the app can say why a kept one stays.
        public internal(set) var recording: String?
        /// "Kept because you favourited it": never deleted.
        public internal(set) var kept: Bool
        public var id: Int { file.id }
    }

    public internal(set) var artistId: Int
    public internal(set) var artistName: String
    public internal(set) var artistMbid: MBID?
    public internal(set) var rows: [Row]

    public var files: [OwnedFile] { rows.filter { !$0.kept }.map(\.file) }
    public var excludedFileIds: [Int] { rows.filter(\.kept).map(\.file.id) }
    public var bytes: Int64 { files.reduce(0) { $0 + max(0, $1.size) } }
}

public actor MonitoringChanger {
    public enum Outcome: Sendable, Equatable {
        case finished
        /// Not finished yet (Lidarr's refresh not confirmed, an answer lost…): resumed later from the ledger.
        case pending
        /// The gate refused (something changed since the owner confirmed) or it kept failing: nothing more is sent.
        case abandoned
    }

    let lidarr: LidarrClient
    let gate: LidarrWriteGate
    let ledger: Ledger
    let roots: @Sendable () async -> WriteConfinement.Roots
    let checks: Int
    let pause: Duration
    let now: @Sendable () -> Date
    /// Failures of one intent before it is given up.
    public static let maxFailures = 5

    /// One change per artist and Lidarr, whichever changer (a page and a resume) runs it.
    private static let busy = OSAllocatedUnfairLock(initialState: Set<String>())

    public init(lidarr: LidarrClient, gate: LidarrWriteGate, ledger: Ledger,
                roots: @escaping @Sendable () async -> WriteConfinement.Roots, checks: Int = 30,
                pause: Duration = .seconds(2), now: @escaping @Sendable () -> Date = Date.init) {
        self.lidarr = lidarr; self.gate = gate; self.ledger = ledger; self.roots = roots
        self.checks = checks; self.pause = pause; self.now = now
    }

    /// The ledger's file (or, kept in memory, the ledger itself), its Lidarr, and the artist.
    private func key(_ artistId: Int) -> String {
        "\(ledger.monitoringBookKey)|\(ledger.instance ?? "-")|\(artistId)"
    }

    private func exclusive<T: Sendable>(_ artistId: Int, _ body: () async throws -> T) async throws -> T {
        let k = key(artistId)
        guard Self.busy.withLock({ $0.insert(k).inserted }) else { throw MonitoringChangeError.busy }
        defer { _ = Self.busy.withLock { $0.remove(k) } }
        return try await body()
    }

    private func book() async throws -> MonitoringBook {
        do { return try await ledger.monitoringBook } catch { throw MonitoringChangeError.unavailable }
    }

    private func reading<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw MonitoringChangeError.unavailable }
    }

    // MARK: - Reads

    /// The artist, only when it is in the main root folder and not a find (the gate's own proofs, asked early so the
    /// owner is told before anything is recorded).
    private func ownedArtist(_ artistId: Int) async throws -> LidarrArtist {
        let roots = await self.roots()
        let (fresh, artist) = try await reading { (try await lidarr.rootFolders().map(\.path), try await lidarr.artist(id: artistId)) }
        guard let main = roots.mainRoot, fresh.contains(where: { Self.same($0, main) }),
              let root = artist.rootFolderPath, Self.same(root, main), let folder = artist.path, artist.foreignArtistId != nil,
              PathGuard(findsRoot: main, otherRoots: fresh.filter { !Self.same($0, main) } + [roots.findsRoot].compactMap { $0 },
                        caseInsensitive: false).isInside(folder),
              !(roots.findTagId.map(artist.tags.contains) ?? false) else {
            throw MonitoringChangeError.notInMainRoot
        }
        return artist
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        guard let x = PathGuard.standardize(a), let y = PathGuard.standardize(b) else { return false }
        return Array(x.utf8) == Array(y.utf8)
    }

    /// The newest closed change of the artist (finished, or stopped partway) whose profile the artist is on now (fix round
    /// 2 R1: a later change that stopped before its profile was sent never hides the one that set it).
    private static func lastChange(_ book: MonitoringBook, _ artistId: Int, onProfile current: Int?) -> MonitoringIntent? {
        guard let current else { return nil }
        return book.intents.filter {
            $0.artistId == artistId && $0.kind == .monitoringChange && ($0.step == .done || $0.step == .abandoned)
                && $0.targetProfileId == current
        }.max { $0.createdAt < $1.createdAt }
    }

    /// Fix round 1 I4: the artist's last change or Revert stopped partway (refused, or given up).
    private static func stoppedPartway(_ book: MonitoringBook, _ artistId: Int) -> Bool {
        book.intents.filter { $0.artistId == artistId && $0.kind != .unmatchedCleanup }
            .max { $0.createdAt < $1.createdAt }?.step == .abandoned
    }

    /// D244: the change Revert puts back: the last closed one (finished or stopped partway), while the artist is still on
    /// the profile it set.
    private static func revertSource(_ book: MonitoringBook, _ artist: LidarrArtist) -> MonitoringIntent? {
        guard book.open(artistId: artist.id).isEmpty, let current = artist.metadataProfileId,
              let last = lastChange(book, artist.id, onProfile: current), current != last.previousProfileId else {
            return nil
        }
        return last
    }

    public func current(artistId: Int) async throws -> MonitoringCurrent {
        let artist = try await ownedArtist(artistId)
        guard let profileId = artist.metadataProfileId else { throw MonitoringChangeError.unavailable }
        let profiles = try await reading { try await lidarr.metadataProfiles() }
        let book = try await book()
        let name = profiles.first { $0.id == profileId }?.name
        return MonitoringCurrent(artistId: artistId, artistName: artist.artistName, profileId: profileId,
                                 types: name.flatMap { ReleaseTypes(magpieProfileName: $0) },
                                 canRevert: Self.revertSource(book, artist) != nil,
                                 hasKept: !(book.kept(artistId: artistId)?.files.isEmpty ?? true),
                                 busy: !book.open(artistId: artistId).isEmpty,
                                 stoppedPartway: Self.stoppedPartway(book, artistId))
    }

    /// Whether songs kept on reducing wait to be cleaned up (the More menu's item). False when the ledger can't be read.
    public func hasKept(artistId: Int) async -> Bool {
        !((try? await ledger.monitoringBook.kept(artistId: artistId))?.files.isEmpty ?? true)
    }

    /// The choice with Magpie's secondary types: the current Magpie profile's, else Studio only (the Q10 ruling: Albums,
    /// EPs and Singles are the only switches).
    static func target(_ types: ReleaseTypes, current: ReleaseTypes?) -> ReleaseTypes {
        var t = types
        let base = current ?? ReleaseTypes(albums: true, eps: false, singles: false, studio: true, soundtrack: false, live: false)
        t.studio = base.studio; t.soundtrack = base.soundtrack; t.live = base.live
        return t
    }

    /// What `types` would do to the artist: reads only, nothing recorded (D240: the owner is asked first).
    public func preview(artistId: Int, types: ReleaseTypes, keep: MonitoringKeepList) async throws -> MonitoringPreview {
        guard types.hasKind else { throw MonitoringChangeError.stale }
        let artist = try await ownedArtist(artistId)
        guard let profileId = artist.metadataProfileId, let mbid = artist.foreignArtistId else { throw MonitoringChangeError.unavailable }
        let (profiles, albums, files) = try await reading {
            (try await lidarr.metadataProfiles(), try await lidarr.albums(artistId: artistId),
             try await lidarr.trackFiles(artistId: artistId))
        }
        let book = try await book()
        let currentTypes = profiles.first { $0.id == profileId }.flatMap { ReleaseTypes(magpieProfileName: $0.name) }
        let target = Self.target(types, current: currentTypes)
        let falling = albums.filter { $0.monitored && !target.includes(albumType: $0.albumType, secondaryTypes: $0.secondaryTypes) }
        let unmonitor = Set(falling.map(\.id))
        let shown = files.filter { $0.albumId.map(unmonitor.contains) == true && $0.artistId.map { $0 == artistId } != false }
        let owned = shown.compactMap { f in f.albumId.map { OwnedFile(id: f.id, albumId: $0, size: f.size ?? -1) } }
            .sorted { $0.id < $1.id }
        var excluded = owned.filter { $0.size < 0 }.map(\.id)   // a size Lidarr doesn't say can't be checked: kept
        if !owned.isEmpty, !keep.isEmpty {
            let tracks = try await reading { try await lidarr.tracks(artistId: artistId) }
            excluded += Self.kept(owned, tracks: tracks, albums: albums, keep: keep)
        }
        // The owner's own profile, kept across Magpie's changes: what Revert goes back to.
        let previous = Self.lastChange(book, artistId, onProfile: profileId)?.previousProfileId ?? profileId
        return MonitoringPreview(artistId: artistId, artistName: artist.artistName, artistMbid: mbid, currentProfileId: profileId,
                                 currentTypes: currentTypes, previousProfileId: previous, target: target,
                                 beforeAlbumIds: albums.map(\.id).sorted(), unmonitorAlbumIds: unmonitor.sorted(),
                                 files: owned, excludedFileIds: Array(Set(excluded)).sorted())
    }

    /// The files whose song the owner keeps.
    static func kept(_ files: [OwnedFile], tracks: [LidarrTrack], albums: [LidarrAlbum], keep: MonitoringKeepList) -> [Int] {
        files.filter { f in
            let album = albums.first { $0.id == f.albumId }?.title
            let songs = tracks.filter { $0.trackFileId == f.id }
            return keep.keeps(recording: nil, title: nil, album: album)
                || songs.contains { keep.keeps(recording: $0.foreignRecordingId, title: $0.title, album: nil) }
        }.map(\.id)
    }

    // MARK: - Apply

    /// Fix round 1 I5: a request of Magpie's under way for the artist (an open entry nobody kept): nothing is recorded
    /// or sent (the gate refuses the profile and the refresh too).
    private func noLiveTry(_ artistId: Int) async throws {
        let entries = try await reading { try await ledger.entries }
        guard !entries.contains(where: { $0.lidarrArtistId == artistId && $0.isOpen && !$0.isConfirmedKept }) else {
            throw MonitoringChangeError.tryUnderWay
        }
    }

    private func writable() async throws {
        guard await gate.enabled else { throw MonitoringChangeError.changesOff }
        guard await gate.monitoringChangesEnabled else { throw MonitoringChangeError.switchOff }
    }

    /// The owner's answer: `preview` as shown, and on reducing his choice. Lidarr is read again first (a change since
    /// he looked: `stale`, nothing sent); the intent is saved before the first write.
    public func apply(_ preview: MonitoringPreview, choice: ReduceChoice) async throws -> Outcome {
        try await exclusive(preview.artistId) {
            try await writable()
            guard try await book().open(artistId: preview.artistId).isEmpty else { throw MonitoringChangeError.busy }
            try await noLiveTry(preview.artistId)
            let artist = try await ownedArtist(preview.artistId)
            let albums = try await reading { try await lidarr.albums(artistId: preview.artistId) }
            let unmonitor = albums.filter {
                $0.monitored && !preview.target.includes(albumType: $0.albumType, secondaryTypes: $0.secondaryTypes)
            }.map(\.id).sorted()
            guard artist.metadataProfileId == preview.currentProfileId, artist.foreignArtistId == preview.artistMbid,
                  unmonitor == preview.unmonitorAlbumIds else { throw MonitoringChangeError.stale }
            if preview.currentTypes == preview.target, unmonitor.isEmpty { return .finished }
            // Fix round 1 I2: only files of albums that stop being monitored now, whatever the preview carries.
            let falling = Set(unmonitor)
            let files = preview.files.filter { falling.contains($0.albumId) }
            let excluded = preview.excludedFileIds.filter { id in files.contains { $0.id == id } }
            let deletable = files.filter { !excluded.contains($0.id) }
            // Fix round 1 I1: the intent is saved before any write, the Magpie profile included: its id isn't known yet
            // (`sending = .profileCreated`); `change` makes or reuses it and records the id before the first change write.
            var intent = MonitoringIntent(kind: .monitoringChange, artistId: preview.artistId, artistMbid: preview.artistMbid,
                                          previousProfileId: preview.previousProfileId, targetProfileId: nil,
                                          targetTypes: preview.target, beforeAlbumIds: albums.map(\.id).sorted(),
                                          unmonitorAlbumIds: unmonitor, keepFiles: choice == .keep || deletable.isEmpty,
                                          files: files, excludedFileIds: excluded, createdAt: now())
            intent.sending = .profileCreated
            do { try await ledger.saveIntent(intent) } catch { throw MonitoringChangeError.notSaved }
            await gate.note(Self.note(intent, from: preview.currentProfileId, instance: lidarr.instanceScope))
            return await advance(intent)
        }
    }

    /// The change log's line (information only; the ledger's intent is the record).
    static func note(_ i: MonitoringIntent, from: Int, instance: String) -> String {
        "monitoring change: artist \(i.artistId) metadataProfileId \(from) -> \(i.targetProfileId.map(String.init) ?? "-")"
            + " unmonitor \(i.unmonitorAlbumIds.count) albums \(i.keepFiles ? "keep" : "remove") \(i.files.count) files instance \(instance)"
    }

    /// Every open intent of the artist, carried on from the ledger. Nil when there is none; pending while changes are off.
    public func resume(artistId: Int) async -> Outcome? {
        do {
            return try await exclusive(artistId) { () async -> Outcome? in
            guard let open = try? await ledger.monitoringBook.open(artistId: artistId), !open.isEmpty else { return nil }
            guard (try? await writable()) != nil else { return .pending }
            var last: Outcome?
            for intent in open.sorted(by: { $0.createdAt < $1.createdAt }) {
                // Fresh from the ledger: an earlier one may have just made this one.
                guard let fresh = try? await ledger.monitoringBook.intents.first(where: { $0.id == intent.id }), fresh.isOpen else { continue }
                last = await advance(fresh)
                if last == .pending { break }
            }
            return last
            }
        } catch {
            return .pending   // another change of the artist is running it
        }
    }

    /// Every artist with an open intent.
    public func resumeAll() async {
        guard let book = try? await ledger.monitoringBook else { return }
        for artistId in Set(book.intents.filter(\.isOpen).map(\.artistId)).sorted() { _ = await resume(artistId: artistId) }
    }

    // MARK: - Clean up (D242)

    /// The kept files of the artist whose album is still unmonitored and that are unchanged (read fresh), the owner's
    /// favourites and saved songs marked kept.
    public func cleanupPreview(artistId: Int, keep: MonitoringKeepList) async throws -> CleanupPreview {
        let artist = try await ownedArtist(artistId)
        guard let kept = try await book().kept(artistId: artistId), kept.artistMbid == artist.foreignArtistId else {
            return CleanupPreview(artistId: artistId, artistName: artist.artistName, artistMbid: artist.foreignArtistId, rows: [])
        }
        let (albums, files, tracks) = try await reading {
            (try await lidarr.albums(artistId: artistId), try await lidarr.trackFiles(artistId: artistId),
             try await lidarr.tracks(artistId: artistId))
        }
        let keptIds = Set(Self.kept(kept.files, tracks: tracks, albums: albums, keep: keep))
        let rows: [CleanupPreview.Row] = kept.files.sorted { $0.id < $1.id }.compactMap { owned in
            guard let file = files.first(where: { $0.id == owned.id }), file.albumId == owned.albumId, file.size == owned.size,
                  let album = albums.first(where: { $0.id == owned.albumId }), !album.monitored else { return nil }
            let track = tracks.first { $0.trackFileId == owned.id }
            return .init(file: owned, title: track?.title ?? WriteConfinement.lastComponent(file.path), album: album.title,
                         recording: track?.foreignRecordingId, kept: keptIds.contains(owned.id))
        }
        return CleanupPreview(artistId: artistId, artistName: artist.artistName, artistMbid: artist.foreignArtistId, rows: rows)
    }

    /// The owner confirmed `preview`: exactly its files go (50 at a time), the kept ones stay.
    public func cleanUp(_ preview: CleanupPreview) async throws -> Outcome {
        try await exclusive(preview.artistId) {
            try await writable()
            guard !preview.files.isEmpty else { return .finished }
            guard let mbid = preview.artistMbid else { throw MonitoringChangeError.unavailable }
            let book = try await book()
            guard book.open(artistId: preview.artistId).isEmpty else { throw MonitoringChangeError.busy }
            try await noLiveTry(preview.artistId)
            // Fix round 1 I2: only rows whose file (id, album, size) is in the artist's kept set, whatever the caller hands.
            guard let kept = book.kept(artistId: preview.artistId), kept.artistMbid == mbid else { return .finished }
            let keptFiles = Set(kept.files)
            let rows = preview.rows.filter { keptFiles.contains($0.file) }
            guard rows.contains(where: { !$0.kept }) else { return .finished }
            let intent = MonitoringIntent(kind: .unmatchedCleanup, artistId: preview.artistId, artistMbid: mbid,
                                          previousProfileId: 0, files: rows.map(\.file),
                                          excludedFileIds: rows.filter(\.kept).map(\.file.id), createdAt: now())
            do { try await ledger.saveIntent(intent) } catch { throw MonitoringChangeError.notSaved }
            return await advance(intent)
        }
    }

    // MARK: - Revert (D244)

    /// Puts the artist back on the profile recorded before Magpie's first change, then refreshes it. Only while it is still
    /// on the profile Magpie's last change set.
    public func revert(artistId: Int) async throws -> Outcome {
        try await exclusive(artistId) {
            try await writable()
            try await noLiveTry(artistId)
            let artist = try await ownedArtist(artistId)
            guard let source = Self.revertSource(try await book(), artist), let mbid = artist.foreignArtistId else {
                throw MonitoringChangeError.nothingToRevert
            }
            let intent = MonitoringIntent(kind: .revert, artistId: artistId, artistMbid: mbid,
                                          previousProfileId: source.previousProfileId, targetProfileId: source.previousProfileId,
                                          createdAt: now())
            do { try await ledger.saveIntent(intent) } catch { throw MonitoringChangeError.notSaved }
            await gate.note("monitoring revert: artist \(artistId) metadataProfileId \(artist.metadataProfileId.map(String.init) ?? "-") -> \(source.previousProfileId) instance \(lidarr.instanceScope)")
            return await advance(intent)
        }
    }

    // MARK: - The steps

    private struct Pending: Error {}
    private struct Abandon: Error {}
    /// The profile wasn't the target after the confirmed refresh: sent again on the next pass (a counted failure).
    private struct ProfileReverted: Error {}
    /// Fix round 2 m3: Lidarr didn't take the profile, or the refresh failed: a counted failure.
    private struct NotTaken: Error {}

    private func advance(_ start: MonitoringIntent) async -> Outcome {
        var job = start
        do {
            switch job.kind {
            case .monitoringChange, .revert:
                try await change(&job)
                if let cleanup = try await finish(&job) { return await advance(cleanup) }
            case .unmatchedCleanup:
                try await cleanup(&job)
            }
            return .finished
        } catch is Pending {
            return .pending
        } catch {
            let refused: Bool = if case WriteGateError.forbidden = error { true } else { error is Abandon }
            if case WriteGateError.disabled = error { return .pending }
            job.failures += 1
            if refused || job.failures >= Self.maxFailures {
                Log.logger("requests").error("monitoring change given up: \(Log.category(of: error), privacy: .public)")
                if job.kind == .unmatchedCleanup { try? await closeCleanup(&job, as: .abandoned) } else {
                    job.step = .abandoned
                    job.finishedAt = now()
                    try? await ledger.saveIntent(job)
                }
                return .abandoned
            }
            try? await ledger.saveIntent(job)
            return .pending
        }
    }

    private func sending(_ job: inout MonitoringIntent, _ step: MonitoringIntent.Step) async throws {
        job.sending = step
        try await ledger.saveIntent(job)
    }

    private func saved(_ job: inout MonitoringIntent, _ step: MonitoringIntent.Step) async throws {
        job.step = step
        job.sending = nil
        try await ledger.saveIntent(job)
    }

    /// The albums are unmonitored (or gone) in Lidarr now.
    private func unmonitored(_ ids: [Int], artistId: Int) async throws -> Bool {
        let albums = try await lidarr.albums(artistId: artistId)
        return ids.allSatisfy { id in albums.first { $0.id == id }?.monitored != true }
    }

    /// Fix round 1 M2: the artist's profile read now; a read that fails stays pending (nothing is sent blind).
    private func profile(of artistId: Int) async throws -> Int? {
        do { return try await lidarr.artist(id: artistId).metadataProfileId } catch { throw Pending() }
    }

    /// A change (or Revert): unmonitor what falls out, the profile, a confirmed refresh, then what it brings in.
    private func change(_ job: inout MonitoringIntent) async throws {
        if job.targetProfileId == nil {
            // Fix round 1 I1: the Magpie profile is made or reused only now that the intent is saved, and its id is
            // saved before any change write. A same-named profile set up differently stops it (G5).
            guard job.kind == .monitoringChange, job.sending == .profileCreated, let types = job.targetTypes else { throw Abandon() }
            let made: Int
            do { made = try await Provisioner().ensureReleaseTypes(types, gate: gate, client: lidarr) } catch is ProvisionError {
                throw Abandon()
            }
            job.targetProfileId = made
            job.sending = nil
            try await ledger.saveIntent(job)
        }
        guard let target = job.targetProfileId else { throw Abandon() }
        while true {
            switch job.step {
            case .saved:
                if !job.unmonitorAlbumIds.isEmpty {
                    // After a lost answer: read first, send only if Lidarr didn't do it.
                    var done = false
                    if job.sending == .unmonitored { done = try await unmonitored(job.unmonitorAlbumIds, artistId: job.artistId) }
                    if !done {
                        try await sending(&job, .unmonitored)
                        _ = try await gate.performOwned(intentId: job.id, step: .unmonitor)
                    }
                }
                try await saved(&job, .unmonitored)
            case .unmonitored:
                if try await profile(of: job.artistId) != target {
                    try await sending(&job, .profileSet)
                    _ = try await gate.performOwned(intentId: job.id, step: .profile)
                    // Fix round 2 m3: Lidarr didn't take it: a counted failure (5 at most), never an endless retry.
                    guard try await profile(of: job.artistId) == target else { throw NotTaken() }
                }
                try await saved(&job, .profileSet)
            case .profileSet:
                // Fix round 1 M2: a refresh whose answer was lost is looked for first: one still running is waited for,
                // not sent again. A list that can't be read stays pending.
                if job.sending == .refreshSent {
                    let commands: [CommandStatus]
                    do { commands = try await lidarr.commands() } catch { throw Pending() }
                    if let running = commands.first(where: {
                        $0.name.lowercased() == "refreshartist" && $0.artistIds.contains(job.artistId)
                            && ["queued", "started"].contains($0.status.lowercased())
                    }) {
                        job.refreshCommandId = running.id
                        try await saved(&job, .refreshSent)
                        continue
                    }
                }
                try await sending(&job, .refreshSent)
                let data = try await gate.performOwned(intentId: job.id, step: .refresh)
                guard let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue else { throw Pending() }
                job.refreshCommandId = id
                try await saved(&job, .refreshSent)
            case .refreshSent:
                guard let id = job.refreshCommandId else { job.step = .profileSet; continue }
                switch await refreshState(id) {
                case .completed: try await saved(&job, .refreshed)
                case .failed:
                    job.refreshCommandId = nil
                    job.step = .profileSet
                    try await ledger.saveIntent(job)
                    throw NotTaken()   // fix round 2 m3: counted
                case .unknown: throw Pending()
                }
            case .refreshed:
                // A refresh Lidarr started before ours (an add's) can save the artist with its old profile after our
                // editor write (seen on the dev stack): the profile is read again after the confirmed refresh, and sent
                // again (counted as a failure, so it can't loop) when it isn't the target.
                if job.sending != .searchSent, try await profile(of: job.artistId) != target {
                    job.step = .unmonitored
                    job.refreshCommandId = nil
                    try await ledger.saveIntent(job)
                    throw ProfileReverted()
                }
                // D239: more monitored types: the albums the refresh brought in, of a chosen type, monitored and searched.
                // Fix round 1 M2: a search whose answer was lost is never sent again (when in doubt, don't write).
                if job.kind == .monitoringChange, job.sending != .searchSent, let types = job.targetTypes {
                    let albums = try await lidarr.albums(artistId: job.artistId)
                    if job.monitorAlbumIds.isEmpty {
                        let before = Set(job.beforeAlbumIds)
                        job.monitorAlbumIds = albums.filter {
                            !before.contains($0.id) && !$0.monitored && types.includes(albumType: $0.albumType, secondaryTypes: $0.secondaryTypes)
                        }.map(\.id).sorted()
                    }
                    let ids = job.monitorAlbumIds
                    if !ids.isEmpty {
                        // Read first (above): only albums Lidarr doesn't monitor yet are sent.
                        if ids.contains(where: { id in albums.first { $0.id == id }?.monitored != true }) {
                            try await sending(&job, .monitored)
                            _ = try await gate.performOwned(intentId: job.id, step: .monitor)
                        }
                        try await sending(&job, .searchSent)
                        _ = try await gate.performOwned(intentId: job.id, step: .search)
                    }
                }
                try await saved(&job, .monitored)
            case .monitored, .done, .abandoned, .deleting, .profileCreated, .searchSent:
                return
            }
        }
    }

    /// The change is done: Keep records the kept set (D241), Delete them hands its files to a clean-up whose record is the
    /// very confirmation the owner gave (same hash), saved in the same write as the change's end. Returns that clean-up.
    private func finish(_ job: inout MonitoringIntent) async throws -> MonitoringIntent? {
        guard job.step == .monitored else { return nil }
        job.step = .done
        job.sending = nil
        job.finishedAt = now()
        let done = job
        var cleanup: MonitoringIntent?
        if done.kind == .monitoringChange, !done.keepFiles {
            let next = MonitoringIntent(kind: .unmatchedCleanup, artistId: done.artistId, artistMbid: done.artistMbid,
                                        previousProfileId: done.previousProfileId, files: done.files,
                                        excludedFileIds: done.excludedFileIds, createdAt: now())
            guard next.confirmationHash == done.confirmationHash else { throw Abandon() }
            cleanup = next
        }
        let at = now()
        let next = cleanup
        try await ledger.updateMonitoring { book in
            book.intents.removeAll { $0.id == done.id }
            book.intents.append(done)
            if let next { book.intents.append(next) }
            if done.kind == .monitoringChange, done.keepFiles, !done.files.isEmpty {
                let withFiles = Set(done.files.map(\.albumId))
                let old = book.kept(artistId: done.artistId).flatMap { $0.artistMbid == done.artistMbid ? $0 : nil }
                var files = old?.files ?? []
                for f in done.files where !files.contains(where: { $0.id == f.id }) { files.append(f) }
                let albums = Set(old?.albumIds ?? []).union(withFiles).sorted()
                book.kept.removeAll { $0.artistId == done.artistId }
                book.kept.append(UnmonitoredKept(artistId: done.artistId, artistMbid: done.artistMbid, albumIds: albums,
                                                 files: files, recordedAt: at))
            }
        }
        return cleanup
    }

    /// The clean-up's deletes, 50 at a time; a batch whose answer was lost is read again first (gone files count as
    /// deleted, the rest go with the next batch, checked again by the gate).
    private func cleanup(_ job: inout MonitoringIntent) async throws {
        guard job.matchesConfirmation else { throw Abandon() }
        if !job.pendingFileIds.isEmpty {
            var gone: [Int] = []
            for id in job.pendingFileIds {
                do { _ = try await lidarr.trackFile(id: id) } catch LidarrError.http(status: 404) { gone.append(id) }
            }
            job.deletedFileIds += gone
            job.pendingFileIds = []
            try await ledger.saveIntent(job)
        }
        let excluded = Set(job.excludedFileIds), deleted = Set(job.deletedFileIds)
        let remaining = job.files.map(\.id).filter { !excluded.contains($0) && !deleted.contains($0) }
        for start in stride(from: 0, to: remaining.count, by: WriteConfinement.maxCleanupFiles) {
            let ids = Array(remaining[start..<min(start + WriteConfinement.maxCleanupFiles, remaining.count)])
            job.pendingFileIds = ids
            job.step = .deleting
            try await sending(&job, .deleting)
            _ = try await gate.performCleanup(intentId: job.id)
            job.deletedFileIds += ids
            job.pendingFileIds = []
            try await ledger.saveIntent(job)
        }
        try await closeCleanup(&job, as: .done)
    }

    /// The clean-up ends (done or given up): the files it deleted leave the kept set, in the same write.
    private func closeCleanup(_ job: inout MonitoringIntent, as end: MonitoringIntent.Step) async throws {
        job.step = end
        job.sending = nil
        job.finishedAt = now()
        let closed = job
        let gone = Set(job.deletedFileIds)
        try await ledger.updateMonitoring { book in
            book.intents.removeAll { $0.id == closed.id }
            book.intents.append(closed)
            guard var kept = book.kept(artistId: closed.artistId) else { return }
            kept.files.removeAll { gone.contains($0.id) }
            kept.albumIds = kept.albumIds.filter { album in kept.files.contains { $0.albumId == album } }
            book.kept.removeAll { $0.artistId == closed.artistId }
            if !kept.files.isEmpty { book.kept.append(kept) }
        }
    }

    private enum RefreshState { case completed, failed, unknown }

    /// The RefreshArtist command's end, read from Lidarr (at most `checks` reads, `pause` apart).
    private func refreshState(_ id: Int) async -> RefreshState {
        for i in 0..<checks {
            if let c = try? await lidarr.command(id: id) {
                switch c.status.lowercased() {
                case "completed": return .completed
                case "failed", "aborted", "cancelled", "orphaned": return .failed
                default: break
                }
            }
            if i < checks - 1 { try? await Task.sleep(for: pause) }
        }
        return .unknown
    }

}
