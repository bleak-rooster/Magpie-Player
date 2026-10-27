import Foundation
import LidarrKit
import MagpieCore
import NavidromeKit
import Requests

/// What Keep says afterwards (design language §5: about the music, never the services).
enum KeepCopy {
    static let moved = "Kept. It's in your library now."
    /// G4: the main root already had a folder for the artist, so the find stays where it is.
    static let keptInPlace = "Kept. It'll stay in your Finds folder for now."
    static let stillMoving = "Moving it into your library. It'll be there soon."
    static let moveFailed = "Couldn't keep it this time. It's still in your Finds, so you can try again."
    static let notAFind = "This one can't be kept from here."
    static let unavailable = "Can't keep it right now. Try again in a moment."
    static let changesOff = "Turn on 'Allow Magpie to change Lidarr' in Settings to keep finds."
    static let notSetUp = "Tap 'Set up Magpie in Lidarr' in Settings to keep finds."

    static func message(_ outcome: RequestRunner.KeepOutcome) -> String {
        switch outcome {
        case .moved: moved
        case .keptInPlace: keptInPlace
        case .stillMoving: stillMoving
        }
    }

    static func message(for error: Error) -> String {
        switch error as? RequestRunner.KeepError {
        case .changesOff?: changesOff
        case .notSetUp?: notSetUp
        case .notAFind?: notAFind
        case .moveFailed?: moveFailed
        case .unavailable?, nil: unavailable
        }
    }
}

/// Keep (Task 6.2b): the runner moves the find in Lidarr (G4, A3); the app scans both folders, looks the song
/// up again by MBID, and points the queue and the finds identity at the library song (D29 stops there).
extension AppModel {
    /// Where Keep moves finds: the confirmed Finds root (even with "Use a Finds folder" off, finds already there
    /// can still be kept), the main root, "Magpie Lossless" and the `magpie-find` tag. The runner checks all of it
    /// again against fresh Lidarr state.
    var keepSetup: RequestRunner.KeepSetup? {
        guard let root = findsSetup?.findsRoot, let main = lidarrSetup?.rootFolderPath,
              let lossless = lidarrSetup?.losslessProfileId, let find = lidarrSetup?.findTagId,
              !Self.sameFolder(root, main) else { return nil }
        return RequestRunner.KeepSetup(findsRoot: root, mainRoot: main, losslessProfileId: lossless, findTagId: find)
    }

    /// Keeps the find; returns what to tell the owner.
    func keep(_ id: RequestID) async -> String {
        guard let runner else { return KeepCopy.unavailable }
        defer { pollRequests() }   // a move still going, or a song still to look up, is followed by `tick`
        do {
            let outcome = try await runner.keep(id)
            if outcome == .moved { Task { await refreshFinds() } }
            return KeepCopy.message(outcome)
        } catch {
            return KeepCopy.message(for: error)
        }
    }

    /// Songs kept from Finds that aren't lossless yet: "Lossless soon".
    func quality(of song: Song) -> Quality {
        let quality = Quality.from(suffix: song.suffix, bitRate: song.bitRate)
        let kept = requests.contains { $0.state == .kept && !$0.keptInPlace && $0.songId == song.id }
        return kept && quality != .lossless && quality != .hiRes ? .losslessSoon : quality
    }

    // MARK: - After the move

    /// A12 / A3: one quick scan of the Finds library (the old folder is gone) and the artist's new folder in
    /// the library it landed in, mapped to Navidrome's paths. Unknown libraries or mapping: one plain scan.
    func rescanMoved(from: String, to: String) async throws {
        var targets: [String] = []
        if let finds = findsSetup, let findsLibrary = finds.library,
           let libraries = try? await navidromeLibraries() {
            targets = Self.keepScanTargets(to: to, findsLibrary: findsLibrary, mapping: finds.mapping, libraries: libraries)
        }
        let scan = targets
        try await request { try await $0.startScan(targets: scan) }
    }

    /// `["<finds library id>:", "<library id>:<artist folder relative to it>"]`, or empty (a plain scan) when the
    /// new folder isn't inside exactly one other Navidrome library.
    nonisolated static func keepScanTargets(to: String, findsLibrary: NavidromeLibrary, mapping: PathMapping?,
                                            libraries: [NavidromeLibrary]) -> [String] {
        guard let mapped = mapping.map({ $0.toNavidrome(to) }) ?? PathGuard.standardize(to) else { return [] }
        let holders = libraries.filter { library in
            library.id != findsLibrary.id
                && PathGuard(findsRoot: library.path, otherRoots: [], caseInsensitive: false).isInside(mapped)
        }
        guard holders.count == 1, let library = holders.first,
              let base = PathGuard.standardize(library.path) else { return [] }
        let relative = mapped.split(separator: "/").dropFirst(base.split(separator: "/").count).joined(separator: "/")
        return ["\(findsLibrary.id):", "\(library.id):\(relative)"]
    }

    /// The kept recording's song outside the Finds library (nil while Navidrome hasn't listed it there yet).
    func keptSong(_ recording: MBID) async throws -> Song? {
        let finds = findsSetup?.library?.id
        return try await request { try await $0.songs(recordingMBID: recording, excludingLibrary: finds) }.first
    }

    /// The runner found the kept song in the library: queue slots now hold the library song, and the finds
    /// identity no longer counts it (D29 only blocks finds; Navidrome may keep the same id across the move).
    func keptSongRelinked(_ request: MagpieRequest, before: String?, song: Song) {
        let ids = Set([before, song.id].compactMap { $0 })
        findsIdentity.markKept(song.id)
        if let cache = findIdsCache, let known = cache.ids {
            let remaining = known.subtracting(ids)
            findIdsCache = (cache.key, remaining)
            appDefaults.set(Array(remaining).sorted(), forKey: cache.key)
        }
        if findSongs.contains(where: { ids.contains($0.id) }) { findSongs.removeAll { ids.contains($0.id) } }
        syncFindsIdentity()
        player.replaceSong(id: before ?? song.id, with: song)
        Task { await refreshFinds() }
    }
}
