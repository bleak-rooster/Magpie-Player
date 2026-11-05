import Foundation
import LidarrKit
import MagpieCore
import Observation
import Requests
import Search

/// Round 15 C3 (owner item 6, D135, D136, D139, D146): the words (design language §5: about the music, never a
/// service's name).
enum LibraryFindsCopy {
    static let tryIt = "Try"
    static let tryNote = "A trial: keep it or let it go"
    static let addToLibrary = "Add to library"
    static let addNote = "Yours to keep"
    static let addAlbumNote = "The whole album, yours to keep"
    static let inLibrary = "In your library"
    static let onTrial = "On trial"
    static let coming = "Coming"
    static let couldntBringIn = "Couldn\u{2019}t bring it in"
    static let retry = "Retry"
    static let confirmTitle = "Add to your library?"
    static let add = "Add"
    static let unmatchedAlbumTitle = "Couldn\u{2019}t match this album"
    static let unmatchedAlbumMessage = "Magpie couldn\u{2019}t tell which album this is, so nothing was asked for. Search for it instead."
    static let singlesTitle = "Include singles for this artist?"
    static let includeSingles = "Include singles"
    static let couldntCheck = "Couldn\u{2019}t check what comes with it, so nothing was asked for. Try again in a moment."
    static let singlesPending = "Listing their singles is waiting on your server. It finishes by itself, and the song comes then."
    static let singlesRolledBack = "Couldn\u{2019}t list an artist\u{2019}s singles, so everything was put back as it was."
    static let singlesNotStarted = "Couldn\u{2019}t list their singles this time. Nothing was changed."
    static func unmatchedLeft(_ n: Int) -> String {
        n == 1 ? "1 song couldn\u{2019}t be matched, so it was left in your playlists."
               : "\(n) songs couldn\u{2019}t be matched, so they were left in your playlists."
    }
    static let singlesFailed = "Couldn\u{2019}t list their singles this time. Their new-release setting is as it was."
    static let singlesFailedNeedsLook = "Couldn\u{2019}t list their singles this time, and their new-release setting couldn\u{2019}t be put back. It needs a look."
    static let singlesUndone = "Singles are no longer listed for this artist."
    static let undo = "Undo"

    /// D146's confirmation names exactly what happens.
    static func singlesMessage(artist: String, song: String) -> String {
        "Singles will be listed for \(NewMusicCopy.name(artist)). Only \u{201C}\(song)\u{201D} downloads; nothing else changes."
    }

    // D147: a library trial in Finds.
    static let onTrialHeader = "On trial in your library"
    static let keep = "Keep"
    static let kept = "Kept. It stays in your library."
    static let rejected = "Gone from your library."
    static let rejectTitle = "Not for me?"
    static let rejectMessage = "This release\u{2019}s files are deleted from your library. Nothing else of the artist changes."
    static let rejectRefused = "This one can\u{2019}t be let go from here any more. Nothing was changed."
    static let trialUnavailable = "Can\u{2019}t do that right now. Try again in a moment."
    static let trialNeedsLook = "Its files are gone, but it couldn\u{2019}t be unmonitored. It needs a look."

    static func message(for error: Error) -> String {
        switch error as? RequestRunner.TrialError {
        case .changesOff?: TryAvailability.changesOff.message!
        case .notATrial?, .refused?: rejectRefused
        case .needsAttention?: trialNeedsLook
        case .unavailable?, nil: trialUnavailable
        }
    }

    /// "This song comes with the album “Lowlands”."
    static func comesWithAlbum(_ title: String) -> String { "This song comes with the album \u{201C}\(title)\u{201D}." }

    static func added(_ title: String) -> String {
        "Adding \u{201C}\(title)\u{201D} to your library. It comes in as it\u{2019}s found."
    }

    static func trying(_ title: String) -> String { "Trying \u{201C}\(title)\u{201D}. It shows up in your Finds when it\u{2019}s here." }

    static func status(_ status: LibraryAdds.Status, removeOn: Date? = nil) -> String {
        switch status {
        case .inLibrary: inLibrary
        case .onTrial: removeOn.map { "\(onTrial) \u{00B7} until \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? onTrial
        case .coming(let progress?): "\(coming) \u{00B7} \(Int((progress * 100).rounded()))%"
        case .coming(nil): coming
        case .couldntBringIn: couldntBringIn
        }
    }
}

/// An album from outside the library (a Trending tile, an outside artist page's row, the outside album page).
struct OutsideAlbumRef: Hashable, Sendable, Identifiable {
    var title: String
    var artist: String
    /// Release group.
    var releaseGroup: MBID?
    var artistMBID: MBID?
    var id: String { "\(artist)|\(title)|\(releaseGroup?.rawValue ?? "")" }

    init(title: String, artist: String, releaseGroup: MBID? = nil, artistMBID: MBID? = nil) {
        self.title = title; self.artist = artist; self.releaseGroup = releaseGroup; self.artistMBID = artistMBID
    }

    init(_ album: NotYetAlbum) {
        self.init(title: album.title, artist: album.artist, releaseGroup: album.mbid, artistMBID: album.artistMBID)
    }
}

/// D139: hidden without Lidarr; with Lidarr but Try not usable (Allow changes off, not set up, offline…) the actions
/// show and say why, so no button is ever dead.
enum LibraryActionsState: Equatable {
    case hidden
    case explained(String)
    case available
}

/// A question before Add to library sends anything: the album a song comes with, or the singles switch.
struct LibraryConfirm: Identifiable {
    enum Kind { case album(RequestRunner.TargetPreview), singles(artistId: Int, single: MBID?) }
    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    let recording: ExternalRecording

    var isSingles: Bool {
        if case .singles = kind { return true }
        return false
    }
}

extension AppModel {
    // MARK: - Availability (D139)

    var libraryActions: LibraryActionsState {
        guard outsideSongMenuAvailable else { return .hidden }
        if case .available = tryAvailability { return .available }
        return .explained(tryAvailability.message ?? TryCopy.notSetUp)
    }

    /// A reason to say instead of acting, or nil to go ahead.
    func libraryActionRefusal() -> String? {
        switch libraryActions {
        case .available: nil
        case .explained(let why): why
        case .hidden: TryAvailability.noLidarr.message
        }
    }

    // MARK: - Try (temporary)

    /// Try on an outside song: the existing Try sheet, as a trial (D139).
    func tryOutside(_ song: OutsideSong) async {
        if let why = libraryActionRefusal() { return libraryEdits.notify(why, symbol: "info.circle") }   // D139, no reads
        let key = SongActions.key(song)
        guard songActions.begin(key) else { return }
        defer { songActions.end(key) }
        do {
            songActions.trying = TryTarget(recording: try await resolveOutsideSong(song), intent: .trial)
        } catch {
            songActions.unmatched = song
        }
    }

    /// Try on an outside album: the existing Try this album sheet, as a trial.
    func tryOutsideAlbum(_ album: OutsideAlbumRef) async {
        if let why = libraryActionRefusal() { return libraryEdits.notify(why, symbol: "info.circle") }   // D139, no reads
        let key = "album|\(album.id)|try"
        guard songActions.begin(key) else { return }
        defer { songActions.end(key) }
        guard let (first, group) = await resolveOutsideAlbum(album) else {
            songActions.unmatchedAlbum = album
            return
        }
        songActions.trying = TryTarget(recording: first,
                                       album: NotYetAlbum(title: album.title, artist: album.artist, mbid: group,
                                                          artistMBID: album.artistMBID),
                                       albumGroup: group, intent: .trial)
    }

    // MARK: - Add to library (permanent)

    /// Add to library on an outside song: the release is the smallest the artist's listing has that holds it (a new
    /// artist's: the smallest a Finds-style add can monitor). An album is said before anything is sent; a song no listed
    /// release holds offers the singles switch (D146). When what comes with it can't be checked, nothing is sent (M1).
    func addToLibrary(_ song: OutsideSong) async {
        if let why = libraryActionRefusal() { return libraryEdits.notify(why, symbol: "info.circle") }
        let key = SongActions.key(song) + "|library"
        guard songActions.begin(key) else { return }
        defer { songActions.end(key) }
        let recording: ExternalRecording
        do { recording = try await resolveOutsideSong(song) } catch {
            songActions.unmatched = song
            return
        }
        guard let runner, let preview = try? await runner.targetPreview(recording) else {
            return libraryEdits.notify(LibraryFindsCopy.couldntCheck, symbol: "exclamationmark.circle")
        }
        switch preview {
        case .listed(let title, true), .newArtist(let title, true, _):
            songActions.libraryConfirm = LibraryConfirm(kind: .album(preview), title: LibraryFindsCopy.confirmTitle,
                                                        message: LibraryFindsCopy.comesWithAlbum(title), recording: recording)
        case .notListed(let artistId, let single):
            songActions.libraryConfirm = LibraryConfirm(kind: .singles(artistId: artistId, single: single),
                                                        title: LibraryFindsCopy.singlesTitle,
                                                        message: LibraryFindsCopy.singlesMessage(artist: song.artist, song: song.title),
                                                        recording: recording)
        default:
            await sendToLibrary(recording, album: nil, title: song.title, preview: preview)
        }
    }

    /// The owner said yes.
    func confirmLibrary(_ confirm: LibraryConfirm) async {
        songActions.libraryConfirm = nil
        switch confirm.kind {
        case .album(let preview): await sendToLibrary(confirm.recording, album: nil, title: confirm.recording.title, preview: preview)
        case .singles(let artistId, let single): await includeSingles(artistId: artistId, single: single, then: confirm.recording)
        }
    }

    /// Add album to library.
    func addAlbumToLibrary(_ album: OutsideAlbumRef) async {
        if let why = libraryActionRefusal() { return libraryEdits.notify(why, symbol: "info.circle") }
        let key = "album|\(album.id)"
        guard songActions.begin(key) else { return }
        defer { songActions.end(key) }
        guard let (first, group) = await resolveOutsideAlbum(album) else {
            songActions.unmatchedAlbum = album
            return
        }
        guard let runner, let preview = try? await runner.targetPreview(first) else {
            return libraryEdits.notify(LibraryFindsCopy.couldntCheck, symbol: "exclamationmark.circle")
        }
        await sendToLibrary(first, album: group, title: album.title, preview: preview)
    }

    /// Sends Add to library. Only a new artist's add needs the main library's profiles (M3): "Magpie Lossless Preferred"
    /// and the owner's own Add defaults' metadata profile and following (D136, M2), made through the gate first.
    func sendToLibrary(_ recording: ExternalRecording, album: MBID?, title: String, preview: RequestRunner.TargetPreview?) async {
        do {
            var libraryAdd: RequestRunner.LibraryAddProfile?
            if case .newArtist(_, _, let isSingle)? = preview {
                try await ensureLibraryQuality()
                libraryAdd = try await newArtistProfile(includingSingles: isSingle && album == nil)
            }
            _ = try await startTry(recording, album: album, releaseGroup: nil, intent: .library, libraryAdd: libraryAdd)
            libraryEdits.notify(LibraryFindsCopy.added(title), symbol: "arrow.down.circle")
        } catch let error as ProvisionError {
            libraryEdits.notify(NewMusicCopy.message(for: ArtistLidarrError.profileConflict(Self.conflictName(error))),
                                symbol: "exclamationmark.circle")
        } catch {
            libraryEdits.notify(TryCopy.message(for: error), symbol: "exclamationmark.circle")
        }
    }

    nonisolated static func conflictName(_ error: ProvisionError) -> String {
        if case .conflict(let name) = error { return name }
        return Provisioner.losslessPreferredName
    }

    /// D136 (review M2): the owner's own Add defaults (Settings › New music): their release types' metadata profile (made
    /// through the gate if missing; with singles when the song only comes as one) and whether new releases follow.
    func newArtistProfile(includingSingles: Bool) async throws -> RequestRunner.LibraryAddProfile {
        guard let gate, let client = lidarrClient else { throw RequestRunner.TryError.notSetUp }
        let choices = newMusic.whenYouAdd
        var types = choices.types
        if includingSingles { types.kinds = .albumsEPsAndSingles }
        let profile = try await Provisioner().ensureReleaseTypes(types, gate: gate, client: client)
        return .init(metadataProfileId: profile, follow: choices.follow)
    }

    /// "Magpie Lossless Preferred", through the gate, once (D136): one creation at a time (M3).
    func ensureLibraryQuality() async throws {
        if let running = songActions.qualityTask { return try await running.value }
        guard lidarrSetup?.losslessPreferredProfileId == nil else { return }
        let task = Task { @MainActor in
            defer { self.songActions.qualityTask = nil }
            guard let gate = self.gate, let client = self.lidarrClient, var setup = self.lidarrSetup else {
                throw RequestRunner.TryError.notSetUp
            }
            guard await gate.enabled else { throw RequestRunner.TryError.changesOff }
            do {
                setup.losslessPreferredProfileId = try await Provisioner().ensureLosslessPreferred(gate: gate, client: client)
            } catch WriteGateError.disabled {
                throw RequestRunner.TryError.changesOff
            }
            self.lidarrSetup = setup
            self.setupStore.save(setup)
        }
        songActions.qualityTask = task
        try await task.value
    }

    // MARK: - Singles (D146)

    /// "Include singles for this artist", confirmed, for any artist: the journaled switch (`SinglesSwitcher`: the original
    /// profile and following saved first, following off, the artist's own profile plus Single, a confirmed refresh, every
    /// other new release unmonitored, following back). Then only this song's single is monitored and searched. A switch
    /// still waiting on Lidarr finishes by itself; the song is asked for then.
    func includeSingles(artistId: Int, single: MBID?, then recording: ExternalRecording) async {
        guard let switcher = singlesSwitcher else { return libraryEdits.notify(TryCopy.notSetUp, symbol: "info.circle") }
        guard let single else { return libraryEdits.notify(LibraryFindsCopy.singlesFailed, symbol: "exclamationmark.circle") }
        do {
            switch try await switcher.start(artistId: artistId, target: single) {
            case .finished, .alreadyListed:
                await sendToLibrary(recording, album: single, title: recording.title, preview: nil)
            case .pending:
                songActions.singlesWaiting[artistId] = (recording, single)
                libraryEdits.notify(LibraryFindsCopy.singlesPending, symbol: "clock")
            case .rolledBack:
                libraryEdits.notify(LibraryFindsCopy.singlesFailed, symbol: "exclamationmark.circle")
            }
        } catch SinglesSwitchError.changesOff {
            libraryEdits.notify(TryAvailability.changesOff.message!, symbol: "info.circle")
        } catch SinglesSwitchError.profileConflict(let name) {
            libraryEdits.notify(NewMusicCopy.message(for: ArtistLidarrError.profileConflict(name)), symbol: "exclamationmark.circle")
        } catch {
            libraryEdits.notify(LibraryFindsCopy.singlesNotStarted, symbol: "exclamationmark.circle")
        }
    }

    /// Unfinished switches, resumed (runner start, every requests update at most once a minute): finished ones bring in
    /// the song they were for; rolled-back ones say so.
    func resumeSinglesSwitches(force: Bool = false) async {
        guard let switcher = singlesSwitcher, !isOffline else { return }
        let now = Date()
        if !force, let last = songActions.singlesResumedAt, now.timeIntervalSince(last) < 60 { return }
        songActions.singlesResumedAt = now
        for (artistId, outcome) in await switcher.resumeAll() {
            let waiting = songActions.singlesWaiting.removeValue(forKey: artistId)
            switch outcome {
            case .finished:
                if let (recording, single) = waiting { await sendToLibrary(recording, album: single, title: recording.title, preview: nil) }
            case .rolledBack:
                libraryEdits.notify(LibraryFindsCopy.singlesRolledBack, symbol: "exclamationmark.circle")
            case .pending, .alreadyListed:
                if let waiting { songActions.singlesWaiting[artistId] = waiting }
            }
        }
    }

    /// The change log's Undo for a finished singles switch: the saved profile and following back, then a refresh (the
    /// journal is the source, never the capped log).
    func undoSingles(artistId: Int) async -> String {
        guard let switcher = singlesSwitcher else { return LibraryFindsCopy.trialUnavailable }
        do {
            try await switcher.undo(artistId: artistId)
            return LibraryFindsCopy.singlesUndone
        } catch SinglesSwitchError.changesOff {
            return TryAvailability.changesOff.message!
        } catch {
            return LibraryFindsCopy.trialUnavailable
        }
    }

    /// Artists whose finished singles switch can be undone (Settings › change log).
    func undoableSinglesSwitches() async -> Set<Int> {
        guard let jobs = try? await singlesSwitcher?.store.jobs() else { return [] }
        return Set(jobs.filter { $0.step == .done }.map(\.artistId))
    }

    // MARK: - Library trials in Finds (D147)

    /// Releases of library artists on trial that have arrived, and whose ledger entry is still an open trial (a later Try
    /// or Add of the same album supersedes it: review M8): Finds lists them beside the finds.
    var libraryTrials: [MagpieRequest] {
        requests.filter { r in
            r.isLibraryTrial && r.state == .ready && (songActions.openTrialAlbums.map { r.albumId.map($0.contains) ?? false } ?? true)
        }
    }

    /// Re-reads which albums the ledger holds as open trials (after each requests update).
    func refreshOpenTrials() async {
        guard let ledger, requests.contains(where: \.isLibraryTrial) else { return }
        guard let entries = try? await ledger.entries else { return }
        songActions.openTrialAlbums = Set(entries.filter(\.isOpenTrial).compactMap(\.albumId))
    }

    /// A trial's song as a row shows it (the library song once known).
    func trialSong(_ request: MagpieRequest) -> Song {
        readySongs[request.id] ?? Song(id: request.songId ?? request.id.description, title: request.recording.title,
                                       artist: request.recording.artist, album: request.albumTitle ?? "",
                                       duration: request.recording.duration ?? 0)
    }

    func keepLibraryTrial(_ request: MagpieRequest) async -> String {
        guard let runner else { return LibraryFindsCopy.trialUnavailable }
        do {
            try await runner.keepTrial(request.id)
            return LibraryFindsCopy.kept
        } catch {
            return LibraryFindsCopy.message(for: error)
        }
    }

    /// Reject: proven first (reads only); then, as for a find (D137), the songs whose files are the trial's leave the
    /// owner's playlists (review I5); then the album is unmonitored and its files go (I6).
    func rejectLibraryTrial(_ request: MagpieRequest) async -> String {
        guard let runner else { return LibraryFindsCopy.trialUnavailable }
        guard changesAllowed else { return TryAvailability.changesOff.message! }
        guard await runner.trialRejectable(request.id) else { return LibraryFindsCopy.rejectRefused }
        let (songs, unmatched) = await trialSongIds(request)
        let removed = await cleanUpAfterLetGo(requestId: request.id, title: Self.letGoTitle(request), songIds: songs,
                                              announce: false)
        let left = unmatched > 0 ? LibraryFindsCopy.unmatchedLeft(unmatched) : nil
        defer { pollRequests() }
        do {
            try await runner.rejectTrial(request.id)
            player.removeSongs(songs)
            return [LibraryFindsCopy.rejected, removed.map { $0 + "." }, left].compactMap { $0 }.joined(separator: " ")
        } catch {
            return [LibraryFindsCopy.message(for: error), removed.map { $0 + "." }, left].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Review I5: the songs whose files are the trial album's Lidarr track files, path to path (`TrialSongs`); the count
    /// of files no single song matched (left alone). Never a whole Navidrome album by name.
    func trialSongIds(_ request: MagpieRequest) async -> (ids: Set<String>, unmatched: Int) {
        guard let client = lidarrClient, let albumId = request.albumId, let artistId = request.lidarrArtistId,
              let folder = try? await client.artist(id: artistId).path,
              let files = try? await client.trackFiles(albumId: albumId),
              let tracks = try? await client.tracks(albumId: albumId) else { return ([], 0) }
        var candidates: [(song: Song, lidarrPath: String)] = []
        for title in Set(tracks.filter(\.hasFile).compactMap(\.title)) {
            candidates += await songsTitled(title, artistFolder: folder, anyLibrary: true) ?? []
        }
        return TrialSongs.match(files: files, candidates: candidates)
    }

    // MARK: - Albums

    /// The album's release group (its own, else the server's links by artist and title) and the first track of the
    /// release Magpie picks (the request names it; it lands when the album does).
    func resolveOutsideAlbum(_ album: OutsideAlbumRef) async -> (first: ExternalRecording, group: MBID)? {
        var group = album.releaseGroup
        if group == nil, let links = editorialLinks {
            group = try? await links(album.artist, album.title, nil).album
        }
        guard let group, let release = try? await outsideCatalog.release(releaseGroup: group),
              let first = OutsideReleasePick.recordings(release, artist: album.artist, artistMBID: album.artistMBID).first else {
            return nil
        }
        return (first, group)
    }

    // MARK: - Status (D136)

    /// A song's row: its live request (the same recording MBID, else artist, title and length).
    func libraryStatus(for song: OutsideSong) -> String? {
        let asked = ExternalRecording(recordingMBID: song.recordingMBID, artistMBID: song.artistMBID, title: song.title,
                                      artist: song.artist, releaseTitle: song.album, duration: song.duration, source: .lidarr)
        return statusLine(requests.last { RequestRunner.sameSong($0.recording, asked) && LibraryAdds.status($0) != nil })
    }

    /// An album's row: its live request (resolved to it, or a Try this album aimed at it).
    func libraryStatus(forAlbum releaseGroup: MBID?) -> String? {
        guard let releaseGroup else { return nil }
        return statusLine(requests.last {
            ($0.plan?.releaseGroupMBID ?? $0.albumTarget) == releaseGroup && LibraryAdds.status($0) != nil
        })
    }

    /// Review M8: an album known only by name (Trending's, from the charts, with no MusicBrainz id): its live album request
    /// by the same folded title and artist.
    func libraryStatus(forAlbumTitled title: String, artist: String) -> String? {
        let key = SongIdentity.titleKey(title), who = SongIdentity.artistKey(artist)
        guard !key.isEmpty else { return nil }
        return statusLine(requests.last {
            $0.albumTarget != nil && SongIdentity.titleKey($0.albumTitle ?? "") == key
                && SongIdentity.artistKey($0.recording.artist) == who && LibraryAdds.status($0) != nil
        })
    }

    /// The status for an outside album: by its release group, else by name.
    func libraryStatus(for album: OutsideAlbumRef) -> String? {
        libraryStatus(forAlbum: album.releaseGroup) ?? libraryStatus(forAlbumTitled: album.title, artist: album.artist)
    }

    private func statusLine(_ request: MagpieRequest?) -> String? {
        guard let request, let status = LibraryAdds.status(request) else { return nil }
        return LibraryFindsCopy.status(status, removeOn: status == .onTrial ? trialEnds(request) : nil)
    }

    /// When a trial ends: a library trial's date from the ledger (D147); a find's, the Finds' days from its arrival.
    func trialEnds(_ request: MagpieRequest) -> Date? {
        request.trialExpiresAt
            ?? Calendar.current.date(byAdding: .day, value: RequestRunner.trialDays, to: request.updatedAt)
    }

    /// The request a "Couldn't bring it in" row retries.
    func stoppedRequest(for song: OutsideSong) -> MagpieRequest? {
        let asked = ExternalRecording(recordingMBID: song.recordingMBID, title: song.title, artist: song.artist,
                                      duration: song.duration, source: .lidarr)
        return requests.last { RequestRunner.sameSong($0.recording, asked) && LibraryAdds.status($0) == .couldntBringIn }
    }

    /// Retry: the same intent again (a new request; the stopped one stays in Requests).
    func retry(_ request: MagpieRequest) async {
        let intent: RequestRunner.Intent = request.addToLibrary ? .library : request.askedAsTry ? .trial : .plain
        do {
            // A new artist's add again: its profiles as before (the quality made only then, M3).
            var libraryAdd: RequestRunner.LibraryAddProfile?
            if intent == .library, let profile = request.libraryMetadataProfileId {
                try await ensureLibraryQuality()
                libraryAdd = .init(metadataProfileId: profile, follow: request.libraryFollow ?? false)
            }
            _ = try await startTry(request.recording, album: request.albumTarget, releaseGroup: nil, intent: intent,
                                   libraryAdd: libraryAdd)
        } catch {
            libraryEdits.notify(TryCopy.message(for: error), symbol: "exclamationmark.circle")
        }
    }

    // MARK: - After arrival (D135)

    /// Finds asked into the library that have arrived are kept, once each (the runner proves every Keep again); once moved,
    /// the rest of the artist's discography comes in, lossless preferred (owner: "it should download the entire
    /// discography in the background").
    func evaluateLibraryAdds() async {
        guard songActions.requestsLoaded, !isOffline else { return }
        for r in requests {
            guard case .keep(let id) = LibraryAdds.step(r), !songActions.keepAsked.contains(id) else { continue }
            songActions.keepAsked.insert(id)
            songActions.keepAttempts.append(id)
            do {
                guard try await keepFind(id) == .moved else { continue }
                try? await ensureLibraryQuality()
                let reply = await bringIn(id, choice: .everything, offered: nil, follow: false, artist: r.recording.artist,
                                          qualityProfileId: lidarrSetup?.losslessPreferredProfileId)
                libraryEdits.notify(reply.succeeded ? LibraryFindsCopy.added(r.albumTitle ?? r.recording.title) : reply.message,
                                    symbol: reply.succeeded ? "checkmark.circle" : "exclamationmark.circle")
            } catch RequestRunner.KeepError.unavailable {
                songActions.keepAsked.remove(id)   // asked again on a later update
            } catch {
                libraryEdits.notify(KeepCopy.message(for: error), symbol: "exclamationmark.circle")
            }
        }
    }
}
