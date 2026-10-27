import CarPlayUI
import Foundation
import LidarrKit
import MagpieCore
import NavidromeKit
import Requests

/// What Keep says, and whether "Bring in more" follows: only after the find moved into the library (D5), never
/// after a Keep that stayed in Finds, one still moving, or one that failed.
struct KeepReply: Equatable {
    var message: String
    var bringsInMore = false
}

/// What Keep says afterwards (design language §5: about the music, never the services).
enum KeepCopy {
    // The car says these too (CPKeepResult); one source so they can't drift.
    static let moved = CPKeepResult.moved.message
    /// G4: the main root already had a folder for the artist, so the find stays where it is.
    static let keptInPlace = CPKeepResult.keptInPlace.message
    static let stillMoving = CPKeepResult.stillMoving.message
    static let moveFailed = "Couldn't keep it this time. It's still in your Finds, so you can try again."
    static let notAFind = CPKeepResult.notAFind.message
    static let unavailable = "Can't keep it right now. Try again in a moment."
    static let changesOff = "Keeping finds is switched off. Turn it on in Settings."
    static let notSetUp = "Keeping finds needs one more step in Settings."
    /// The Keep couldn't be settled; nothing more is changed and it isn't offered again.
    static let needsAttention = "Keeping this one didn't finish, and it needs a look before it can be tried again."

    static func reply(_ outcome: RequestRunner.KeepOutcome) -> KeepReply {
        KeepReply(message: message(outcome), bringsInMore: outcome == .moved)
    }

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
        case .needsAttention?: needsAttention
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

    /// Keeps the find; returns what to tell the owner and whether Bring in more follows.
    func keep(_ id: RequestID) async -> KeepReply {
        do {
            return KeepCopy.reply(try await keepFind(id))
        } catch {
            return KeepReply(message: KeepCopy.message(for: error))
        }
    }

    /// The one Keep, for the phone and the car (AppModel+CarPlay.swift): the runner checks everything on fresh state.
    func keepFind(_ id: RequestID) async throws -> RequestRunner.KeepOutcome {
        guard let runner else { throw RequestRunner.KeepError.unavailable }
        defer { pollRequests() }   // a move still going, or a song still to look up, is followed by `tick`
        let outcome = try await runner.keep(id)
        if outcome == .moved { Task { await refreshFinds() } }
        return outcome
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
        guard let (library, relative) = keptLocation(to, findsLibrary: findsLibrary, mapping: mapping,
                                                     libraries: libraries) else { return [] }
        return ["\(findsLibrary.id):", "\(library.id):\(relative)"]
    }

    /// The Navidrome library a Lidarr artist folder is in (exactly one, not the Finds library) and the folder
    /// relative to it, through the Finds mapping.
    nonisolated static func keptLocation(_ artistPath: String, findsLibrary: NavidromeLibrary, mapping: PathMapping?,
                                         libraries: [NavidromeLibrary]) -> (NavidromeLibrary, String)? {
        guard let mapped = mapping.map({ $0.toNavidrome(artistPath) }) ?? PathGuard.standardize(artistPath) else {
            return nil
        }
        let holders = libraries.filter { library in
            library.id != findsLibrary.id
                && PathGuard(findsRoot: library.path, otherRoots: [], caseInsensitive: false).isInside(mapped)
        }
        guard holders.count == 1, let library = holders.first,
              let base = PathGuard.standardize(library.path) else { return nil }
        return (library, mapped.split(separator: "/").dropFirst(base.split(separator: "/").count).joined(separator: "/"))
    }

    /// The kept recording's song in the folder the artist moved to (nil while Navidrome hasn't listed it there,
    /// or when that folder can't be placed in a library: then the song isn't relinked). Never the owner's own
    /// copy of the recording on another release.
    func keptSong(_ recording: MBID, artistPath: String) async throws -> Song? {
        guard let finds = findsSetup, let findsLibrary = finds.library,
              let (library, folder) = Self.keptLocation(artistPath, findsLibrary: findsLibrary, mapping: finds.mapping,
                                                        libraries: try await navidromeLibraries()) else { return nil }
        let id = library.id
        return try await request { try await $0.songs(recordingMBID: recording, inLibrary: id, under: folder) }.first
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
