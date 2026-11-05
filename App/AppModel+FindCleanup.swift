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

    func forget() {
        jobs = []; store = nil; loadedScope = nil; loaded = false; running = []; posted = []
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

    /// Unfinished clean-ups (an interruption, a server that didn't answer): tried again, from a fresh read.
    func resumeLetGoCleanups() async {
        for job in letGo.jobs where job.finishedAt == nil { await runCleanup(job.id, announce: true) }
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

    /// The Release UI check of the clean-up (round 15 C3): with `-MagpieUITesting YES -MagpieUITestLetGo <song id>` the
    /// clean-up a Not for me runs is run for that song, as if its find had just been let go (the dev stack can't make a
    /// real find without the internet). A production launch never passes these.
    func runUITestLetGoIfAsked(_ defaults: UserDefaults = .standard) async {
        guard defaults.string(forKey: "MagpieUITesting") == "YES", !letGo.uiTestRan,
              let songId = defaults.string(forKey: "MagpieUITestLetGo"), !songId.isEmpty else { return }
        letGo.uiTestRan = true
        let title = (try? await request { try await $0.song(id: songId) })?.title ?? "this song"
        await cleanUpAfterLetGo(requestId: RequestID(), title: title, songIds: [songId])
    }
}
