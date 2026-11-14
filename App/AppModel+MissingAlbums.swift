import Foundation
import LidarrKit
import Observation
import Requests

/// Round 27 R (owner, 2026-11-14, D290–D292): Settings › Lidarr › Missing albums. What the section and the Downloads in
/// Lidarr page share: the last "Search for missing albums now" answer, and a Clear all's progress and outcome (held here,
/// so leaving either page doesn't lose a run).
@MainActor @Observable final class MissingAlbumsState {
    /// "Search for missing albums now" is on its way.
    var searching = false
    /// How the last search by hand went (the words under the button).
    var searchAnswer: MissingAlbumSchedule.Answer?
    /// Clear all is reading the queue for its confirmation.
    var preparing = false
    /// Clear all is under way: "Clearing downloads: done of total".
    var clearProgress: (done: Int, total: Int)?
    var clearing: Bool { clearProgress != nil }
    /// A Clear all's outcome, or why it couldn't start.
    var clearMessage: String?
    /// Changes when the schedule's saved choice or time changes, so the section re-reads them.
    var revision = 0
    /// An ask on schedule is on its way (one at a time).
    @ObservationIgnored var scheduleRunning = false
}

/// Round 27 R (D294): the section is there only while Lidarr is connected (Navidrome alone and + Aurral: none).
enum MissingAlbumsPresentation {
    static func shows(lidarrConnected: Bool, aurralConnected: Bool) -> Bool { lidarrConnected }
}

extension AppModel {
    /// Round 27 R (D294): Settings › Lidarr shows Missing albums.
    var showsMissingAlbums: Bool { MissingAlbumsPresentation.shows(lidarrConnected: lidarr != nil, aurralConnected: aurralClient != nil) }

    /// Its buttons and choice work: Lidarr connected, "Allow Magpie to change your library" on, online.
    var missingAlbumsUsable: Bool { lidarr != nil && changesAllowed && !isOffline }

    private var missingAlbumsStore: MissingAlbumSchedule.Store? {
        lidarrScope.map { MissingAlbumSchedule.Store(defaults: gateDefaults, scope: $0) }
    }

    /// "Search automatically" for the connected Lidarr; Off without one.
    var missingSearchEvery: MissingAlbumSchedule.Every {
        get {
            _ = missingAlbums.revision
            return missingAlbumsStore?.every ?? .off
        }
        set {
            missingAlbumsStore?.every = newValue
            missingAlbums.revision += 1
        }
    }

    /// When Magpie last asked the connected Lidarr (by hand or on schedule): "Last asked".
    var missingSearchLastAsked: Date? {
        _ = missingAlbums.revision
        return missingAlbumsStore?.lastAsked
    }

    /// The one send of `ConfinedShape.missingAlbumSearch` (D293): the gate decides everything else (the switch, none
    /// running in Lidarr, its ten-minute record saved before sending). `scripts/check-writes.sh` pins this line.
    private func askLidarrForMissingAlbums() async -> MissingAlbumSchedule.Answer {
        guard let gate else { return .refused }
        do {
            _ = try await gate.send("POST", "command", body: MissingAlbumSearch.Body(), confinedAs: .missingAlbumSearch)
            return .sent
        } catch {
            return MissingAlbumSchedule.answer(for: error)
        }
    }

    /// One ask, by hand or on schedule: the time saved before it (two activations can't both send), put back when it
    /// was refused before sending (D291).
    private func askAndRecord(now: Date) async -> MissingAlbumSchedule.Answer {
        guard let scope = lidarrScope else { return .refused }
        let store = MissingAlbumSchedule.Store(defaults: gateDefaults, scope: scope)
        let previous = store.lastAsked
        store.lastAsked = now
        missingAlbums.revision += 1
        let answer = await askLidarrForMissingAlbums()
        // Only while the same Lidarr is connected: a disconnect meanwhile forgot its keys, and they stay forgotten.
        if lidarrScope == scope {
            store.lastAsked = MissingAlbumSchedule.lastAsked(after: answer, previous: previous, askedAt: now)
        }
        missingAlbums.revision += 1
        return answer
    }

    /// "Search for missing albums now", after its confirmation (D290).
    func searchMissingAlbumsNow(now: Date = Date()) async {
        guard !missingAlbums.searching else { return }
        guard missingAlbumsUsable else {
            missingAlbums.searchAnswer = .refused
            return
        }
        missingAlbums.searching = true
        defer { missingAlbums.searching = false }
        missingAlbums.searchAnswer = await askAndRecord(now: now)
    }

    /// Hook from `scenePhaseChanged` (D291): Magpie became active (the launch's first phase included).
    func missingAlbumsSceneChanged(active: Bool) {
        guard active, lidarr != nil else { return }
        Task { await runMissingAlbumSchedule() }
    }

    /// The schedule's check: due only when Magpie is active, online, Lidarr connected and changes allowed, and the
    /// chosen day or week has passed since the last ask (D291). Never called by a background request pass.
    func runMissingAlbumSchedule(now: Date = Date()) async {
        guard !missingAlbums.scheduleRunning, let store = missingAlbumsStore else { return }
        if let saved = store.lastAsked, saved > now {   // the phone's clock went back: the wait starts from now
            store.lastAsked = MissingAlbumSchedule.lastAskedClamped(saved, now: now)
            missingAlbums.revision += 1
        }
        let situation = MissingAlbumSchedule.Situation(trigger: .becameActive, online: !isOffline,
                                                       lidarrConnected: lidarr != nil && gate != nil,
                                                       changesAllowed: changesAllowed)
        guard MissingAlbumSchedule.isDue(every: store.every, lastAsked: store.lastAsked, now: now, situation: situation) else {
            return
        }
        missingAlbums.scheduleRunning = true
        defer { missingAlbums.scheduleRunning = false }
        _ = await askAndRecord(now: now)
    }

    /// Disconnect and sign-out forget the schedule and the gate's record with the other Lidarr keys.
    func forgetMissingAlbums(scope: String) {
        MissingAlbumSchedule.Store(defaults: gateDefaults, scope: scope).forget()
        MissingAlbumSearch.forgetRecord(scope: scope, in: gateDefaults)
        missingAlbums.searchAnswer = nil
        missingAlbums.clearMessage = nil
        missingAlbums.revision += 1
    }

    // MARK: Clear all downloads and search again (D292)

    private var clearAllRestarter: LidarrDownloadRestarter? {
        guard let gate, let client = lidarrClient else { return nil }
        return LidarrDownloadRestarter(lidarr: client, gate: gate, runner: runner)
    }

    /// Reads the whole queue for the confirmation. Nil (with the reason in `clearMessage`) when there's nothing to clear
    /// or Lidarr can't be read; nothing is sent.
    func prepareClearAll() async -> ClearAllPlan? {
        guard missingAlbumsUsable, !missingAlbums.clearing, !missingAlbums.preparing,
              let restarter = clearAllRestarter else { return nil }
        missingAlbums.preparing = true
        defer { missingAlbums.preparing = false }
        missingAlbums.clearMessage = nil
        do {
            let plan = try await restarter.clearAllPlan()
            if plan.count == 0 { missingAlbums.clearMessage = LidarrDownloadsCopy.empty; return nil }
            return plan
        } catch {
            missingAlbums.clearMessage = MissingAlbumsCopy.unreachable
            return nil
        }
    }

    /// Clear all, after its confirmation. `includeForeign` comes only from that confirmation (per Q2 it names how many
    /// another app started); `scripts/check-writes.sh` pins the lines that pass it on.
    func clearAllDownloads(_ plan: ClearAllPlan, includeForeign: Bool) async {
        guard missingAlbumsUsable, !missingAlbums.clearing, let restarter = clearAllRestarter else { return }
        let state = missingAlbums
        state.clearMessage = nil
        state.clearProgress = (0, plan.count)
        let outcome = await restarter.clearAll(plan, includeForeign: includeForeign) { done, total in
            await MainActor.run { state.clearProgress = (done, total) }
        }
        state.clearProgress = nil
        state.clearMessage = MissingAlbumsCopy.clearOutcome(outcome)
    }
}
