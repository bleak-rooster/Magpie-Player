import Foundation
import LidarrKit
import MagpieCore
import NavidromeKit
import Requests

/// Y5 (plan items 8 and 9): what the find flow says (design §2, the round-11 glossary: no service names), "Remove the
/// MP3 now", the MP3's song leaving the queue (M1), and the library lookup for files without MusicBrainz tags (9.2).
enum FindCopy {
    static let inYourFinds = "In your Finds"
    static let addingQueued = "Adding when your server is free\u{2026}"
    static let adding = "Adding to your library\u{2026}"
    static let keptInFinds = "Kept \u{00B7} in your Finds folder for now"
    static let lossless = "In your library \u{00B7} Lossless"
    static let losslessSoon = "In your library \u{00B7} lossless soon"
    static let waitingForLossless = "Waiting for a lossless copy"
    static let mp3NeedsAttention = "Couldn't remove the MP3 \u{00B7} needs a look"
    static let keepNeedsAttention = "Couldn't finish adding it \u{00B7} needs a look"
    static let letGoNeedsAttention = "Couldn't finish letting it go \u{00B7} needs a look"
    static let unmatched = "Couldn't match this artist"
    static let collision = "Your library already has a folder for this artist, so it stays in your Finds for now."
    static let removeMP3 = "Remove the MP3 now"
    static let removeMP3Title = "Remove the MP3 now?"
    static let removeMP3Message = "This song leaves your library until a lossless copy arrives."
    /// I7: Lidarr's recycle bin is unset.
    static let cantBeUndone = "This can't be undone."
    static let removed = "The MP3 is gone. The lossless copy is still being looked for."
    static let nothingToRemove = "There's no MP3 left to remove."
    static let removeLater = "Can't remove it right now. It'll be tried again shortly."
    static let removeFailed = "Couldn't remove the MP3. It needs a look."
    static let removeUnavailable = "Can't remove it right now. Try again in a moment."

    /// "The MP3 is removed on 9 Nov unless a lossless copy turns up."
    static func removedOn(_ date: Date) -> String {
        "The MP3 is removed on \(date.formatted(.dateTime.day().month(.abbreviated))) unless a lossless copy turns up."
    }

    static func confirmMessage(permanent: Bool) -> String {
        permanent ? "\(removeMP3Message) \(cantBeUndone)" : removeMP3Message
    }

    /// The status line of a find (artist line, song and album rows; CarPlay shows the same text).
    static func status(_ state: FindState, permanent: Bool = false) -> String {
        switch state {
        case .find: inYourFinds
        case .keptInFinds: keptInFinds
        case .adding(let queued): queued ? addingQueued : adding
        case .collision: collision
        case .needsAttention(.keep): keepNeedsAttention
        case .needsAttention(.letGo): letGoNeedsAttention
        case .needsAttention(.mp3): mp3NeedsAttention
        case .inLibrary(.lossless): lossless
        case .inLibrary(.mp3Removed): waitingForLossless
        case .inLibrary(.waiting(let date?)):
            "\(losslessSoon). \(removedOn(date))" + (permanent ? " \(cantBeUndone)" : "")
        case .inLibrary(.waiting(nil)): losslessSoon
        }
    }

    static func symbol(_ state: FindState) -> String {
        switch state {
        case .find, .keptInFinds, .collision: "record.circle"
        case .adding: "arrow.down.circle"
        case .needsAttention: "exclamationmark.circle"
        case .inLibrary(.lossless): "checkmark.circle"
        case .inLibrary: "clock"
        }
    }
}

extension AppModel {
    /// "Remove the MP3 now" is offered on a kept find whose MP3 Magpie recorded (fix I8: only where a file record
    /// exists; adopted and older kept finds show the watch status without it). The runner checks the ledger again.
    func canRemoveMP3(_ request: MagpieRequest) -> Bool { Self.canRemoveMP3(request) }

    nonisolated static func canRemoveMP3(_ request: MagpieRequest) -> Bool {
        guard request.state == .kept, let w = request.lossless, w.hasRecord == true else { return false }
        return w.isActive && w.removedAt == nil && w.losslessAt == nil && !request.mp3NeedsAttention
    }

    /// Fix I7: a scan of exactly this artist folder (Lidarr's path) in the one library it's in. False when it can't be
    /// placed: never the whole main library, never a full scan.
    func scanArtistFolder(_ artistFolder: String) async -> Bool {
        guard let finds = findsSetup, let findsLibrary = finds.library,
              let libraries = try? await navidromeLibraries(),
              let (library, relative) = Self.keptLocation(artistFolder, findsLibrary: findsLibrary, mapping: finds.mapping,
                                                          libraries: libraries), !relative.isEmpty else { return false }
        let target = "\(library.id):\(relative)"
        return (try? await request { try await $0.startScan(targets: [target]) }) != nil
    }

    /// I7: true when Lidarr's recycle bin is unset (or can't be read: say the worst).
    func mp3RemovalIsPermanent() async -> Bool {
        guard let runner else { return true }
        return await runner.mp3RemovalIsPermanent() ?? true
    }

    /// "Remove the MP3 now", confirmed by the owner. Returns what to say.
    func removeMP3Now(_ id: RequestID) async -> String {
        guard let runner, !isOffline else { return FindCopy.removeUnavailable }
        defer { pollRequests() }
        do {
            switch try await runner.removeMP3Now(id) {
            case .removed: return FindCopy.removed
            case .nothingToRemove: return FindCopy.nothingToRemove
            case .later: return FindCopy.removeLater
            }
        } catch RequestRunner.MP3Error.needsAttention {
            return FindCopy.removeFailed
        } catch RequestRunner.MP3Error.changesOff {
            return KeepCopy.changesOff
        } catch {
            return FindCopy.removeUnavailable
        }
    }

    /// M1: the MP3's song is gone from the library: queue entries go. A phone download of it stays on the phone (it
    /// still plays offline until removed in Downloads), and its star and plays stay on Navidrome's (now gone) song id;
    /// both are documented in docs/decisions.md.
    func mp3Removed(_ request: MagpieRequest, songId: String?) {
        if let songId { player.removeSongs([songId]) }
        Task { await refreshFinds() }
    }

    /// Item 9.2: the library's songs titled like `title` inside Lidarr's artist folder, with their paths in Lidarr's
    /// terms. Same paths on both servers, or the Finds mapping; anything that can't be placed is left out.
    func songsTitled(_ title: String, artistFolder: String) async -> [(song: Song, lidarrPath: String)]? {
        guard let finds = findsSetup, let findsLibrary = finds.library,
              let libraries = try? await navidromeLibraries() else { return nil }
        var all = libraries
        if !all.contains(where: { $0.id == findsLibrary.id }) { all.append(findsLibrary) }
        let mapped = finds.mapping.map { $0.toNavidrome(artistFolder) } ?? PathGuard.standardize(artistFolder)
        guard let navidromeFolder = mapped else { return nil }
        for library in all {
            guard let base = PathGuard.standardize(library.path),
                  PathGuard(findsRoot: library.path, otherRoots: [], caseInsensitive: false).isInside(navidromeFolder) else { continue }
            let relative = navidromeFolder.split(separator: "/").dropFirst(base.split(separator: "/").count).joined(separator: "/")
            let id = library.id
            guard let rows = try? await request({ try await $0.songs(titled: title, inLibrary: id, under: relative) }) else {
                return nil
            }
            // Back into Lidarr's terms: the artist folder plus the path below it.
            return rows.compactMap { row in
                let parts = row.path.split(separator: "/")
                let depth = relative.split(separator: "/").count
                guard parts.count > depth else { return nil }
                return (row.song, artistFolder + "/" + parts.dropFirst(depth).joined(separator: "/"))
            }
        }
        return nil
    }
}
