import Foundation
import MagpieCore
import NavidromeKit
import Observation
import Requests

/// Round 15 C3 (owner item 7, D137, D138): what a rejected find's playlist clean-up says.
enum FindCleanupCopy {
    static let recentlyLetGo = "Recently let go"
    static let notificationTitle = "Let go from your Finds"
    static let inNoPlaylist = "It wasn\u{2019}t in any of your playlists."

    static func skipped(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return list + (names.count == 1 ? " couldn\u{2019}t be checked, so it was left as it is."
                                         : " couldn\u{2019}t be checked, so they were left as they are.")
    }

    /// "Removed “Song” from 2 playlists: Road Trip, Chill", plus any playlist left alone; nil when there's nothing to say.
    static func message(_ job: FindCleanup) -> String? {
        let parts = [FindCleanups.message(title: job.title, playlists: job.playlists), skipped(job.skipped ?? [])]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    /// The history row's line.
    static func historyLine(_ job: FindCleanup) -> String {
        message(job) ?? inNoPlaylist
    }
}

/// The clean-ups for the connected Lidarr's finds (one file per Lidarr, beside the requests), and the notifications
/// posted (tests). One per app (`AppModel.letGo`).
@MainActor @Observable final class LetGoState {
    var jobs: [FindCleanup] = []
    /// Finished clean-ups, latest first: Finds › Recently let go.
    var history: [FindCleanup] {
        jobs.filter { $0.finishedAt != nil }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }
    @ObservationIgnored var store: FindCleanupStore?
    @ObservationIgnored var loadedScope: String?
    @ObservationIgnored var loaded = false
    @ObservationIgnored var running: Set<UUID> = []
    /// Local notifications posted (title, body), newest last.
    @ObservationIgnored var posted: [(title: String, body: String)] = []
    @ObservationIgnored var uiTestRan = false
    /// Review M4: retries of an unfinished clean-up, and when the next may run.
    @ObservationIgnored var tries: [UUID: Int] = [:]
    @ObservationIgnored var nextTry: [UUID: Date] = [:]

    func forget() {
        jobs = []; store = nil; loadedScope = nil; loaded = false; running = []; posted = []; tries = [:]; nextTry = [:]
    }
}

extension AppModel {
    // MARK: - The file (D138)

    /// Follows the connected Lidarr's clean-ups (called when the runner is rebuilt); unfinished ones are resumed.
    func followFindCleanups(instance: String?) {
        guard !letGo.loaded || letGo.loadedScope != instance else { return }
        letGo.loaded = true
        letGo.loadedScope = instance
        guard let instance else {
            letGo.store = nil
            letGo.jobs = letGo.jobs.filter { $0.finishedAt == nil }   // nothing of another Lidarr's history shows
            return
        }
        let store = FindCleanupStore(fileURL: FindCleanupStore.defaultURL(in: dataDirectory, instance: instance))
        letGo.store = store
        letGo.jobs = []
        Task { [weak self] in
            let saved = (try? await store.load()) ?? []
            guard let self, self.letGo.store === store else { return }
            self.letGo.jobs = saved + self.letGo.jobs.filter { j in !saved.contains { $0.id == j.id } }
            await self.resumeLetGoCleanups()
        }
    }

    private func saveLetGo() async {
        try? await letGo.store?.save(letGo.jobs)
    }

    private func updateJob(_ id: UUID, _ change: (inout FindCleanup) -> Void) {
        guard let i = letGo.jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&letGo.jobs[i])
    }

    // MARK: - The clean-up (D137)

    /// The find's songs leave every one of the owner's playlists, and any playlist add still waiting for it goes. Saved
    /// before anything is removed, so an interruption is finished later. Returns what to say (also shown in the app
    /// unless `announce` is false, when the caller says it).
    @discardableResult
    func cleanUpAfterLetGo(requestId: RequestID, title: String, songIds: Set<String>, announce: Bool = true) async -> String? {
        await dropPendingAdds(for: requestId)
        let job = FindCleanup(requestId: requestId, title: title, songIds: songIds.sorted(), createdAt: Date())
        letGo.jobs.append(job)
        await saveLetGo()
        await runCleanup(job.id, announce: announce)
        return letGo.jobs.first { $0.id == job.id }.flatMap(FindCleanupCopy.message)
    }

    /// Unfinished clean-ups (an interruption, a server that didn't answer): tried again, from a fresh read, backing off
    /// (review M4: 1, 5, then every 15 minutes) so a playlist that keeps failing isn't re-read on every poll.
    func resumeLetGoCleanups() async {
        let now = Date()
        for job in letGo.jobs where job.finishedAt == nil {
            if let next = letGo.nextTry[job.id], next > now { continue }
            let tries = letGo.tries[job.id, default: 0]
            letGo.tries[job.id] = tries + 1
            letGo.nextTry[job.id] = now.addingTimeInterval(Self.cleanupBackoff(tries))
            await runCleanup(job.id, announce: true)
        }
    }

    nonisolated static func cleanupBackoff(_ tries: Int) -> TimeInterval {
        switch tries {
        case 0: 60
        case 1: 300
        default: 900
        }
    }

    /// D101's pending playlist adds for the rejected find: they'd never arrive.
    private func dropPendingAdds(for requestId: RequestID) async {
        guard songActions.pending.contains(where: { $0.requestId == requestId }) else { return }
        songActions.pending.removeAll { $0.requestId == requestId }
        try? await songActions.store?.save(songActions.pending)
        playlistsChanged(nil)
    }

    private func runCleanup(_ id: UUID, announce: Bool) async {
        guard let job = letGo.jobs.first(where: { $0.id == id }), job.finishedAt == nil,
              !letGo.running.contains(id), session != nil, !isOffline else { return }
        letGo.running.insert(id)
        defer { letGo.running.remove(id) }
        let wanted = Set(job.songIds)
        guard !wanted.isEmpty else { return await finish(id, skipped: [], announce: announce) }
        guard let lists = try? await editablePlaylists() else { return }   // tried again later
        var skipped: [String] = []
        var incomplete = false
        var changed = false
        for list in lists {
            do {
                switch try await removeEverywhere(wanted, from: list) {
                case true?:
                    changed = true
                    updateJob(id) { if !$0.playlists.contains(list.name) { $0.playlists.append(list.name) } }
                    await saveLetGo()
                case false?: break
                case nil: skipped.append(list.name)
                }
            } catch PlaylistEditError.notYours {
                continue   // not the user's any more: never touched
            } catch {
                incomplete = true
            }
        }
        if changed { playlistsChanged(nil) }
        guard !incomplete else { return }
        await finish(id, skipped: skipped, announce: announce)
    }

    private func finish(_ id: UUID, skipped: [String], announce: Bool) async {
        updateJob(id) {
            $0.finishedAt = Date()
            $0.skipped = skipped.isEmpty ? nil : skipped
        }
        await saveLetGo()
        guard let job = letGo.jobs.first(where: { $0.id == id }), let message = FindCleanupCopy.message(job) else { return }
        if announce { libraryEdits.notify(message, symbol: "music.note.list", shown: .seconds(6)) }
        // Finished away from the app: a local notification, when they're on (D7's: only while Magpie runs).
        if !isForeground, notifications {
            ReadyNotifier.shared.postLetGo(id: id.uuidString, title: FindCleanupCopy.notificationTitle, body: message)
            letGo.posted.append((FindCleanupCopy.notificationTitle, message))
        }
    }

    // MARK: - UI tests only

    /// Review M5: the UI-test hooks act only on a dev server on this machine (localhost / 127.0.0.1).
    var signedInToLoopback: Bool {
        guard let session, !session.endpoint.bases.isEmpty else { return false }
        return session.endpoint.bases.allSatisfy { ["localhost", "127.0.0.1"].contains($0.host()?.lowercased() ?? "") }
    }

    /// The Release UI check of library trials in Finds (round 15 C3, D147): with `-MagpieUITesting YES
    /// -MagpieUITestLibraryTrial <song id>` that dev song is shown as a library trial (a request in memory only; nothing
    /// is written anywhere). A production launch never passes these.
    func seedUITestLibraryTrialIfAsked(_ defaults: UserDefaults = .standard) async {
        guard defaults.string(forKey: "MagpieUITesting") == "YES", signedInToLoopback,
              let songId = defaults.string(forKey: "MagpieUITestLibraryTrial"), !songId.isEmpty,
              !requests.contains(where: { $0.songId == songId }),
              let song = try? await request({ try await $0.song(id: songId) }) else { return }
        var r = MagpieRequest(recording: ExternalRecording(title: song.title, artist: song.artist, duration: song.duration,
                                                           source: .lidarr), tier: .standard, createdAt: Date())
        r.state = .ready
        r.songId = song.id
        r.askedAsTry = true
        r.trialExpiresAt = Date().addingTimeInterval(TimeInterval(RequestRunner.trialDays) * 86_400)
        r.albumId = 1
        r.lidarrArtistId = 1
        readySongs[r.id] = song
        requests.append(r)
    }

    /// The Release UI check of the clean-up (round 15 C3): with `-MagpieUITesting YES -MagpieUITestLetGo <song id>` the
    /// clean-up a Not for me runs is run for that song, as if its find had just been let go (the dev stack can't make a
    /// real find without the internet). A production launch never passes these.
    func runUITestLetGoIfAsked(_ defaults: UserDefaults = .standard) async {
        guard defaults.string(forKey: "MagpieUITesting") == "YES", !letGo.uiTestRan, signedInToLoopback,
              let songId = defaults.string(forKey: "MagpieUITestLetGo"), !songId.isEmpty else { return }
        letGo.uiTestRan = true
        let title = (try? await request { try await $0.song(id: songId) })?.title ?? "this song"
        await cleanUpAfterLetGo(requestId: RequestID(), title: title, songIds: [songId])
    }
}
