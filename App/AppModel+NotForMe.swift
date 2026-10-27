import Foundation
import MagpieCore
import Requests

/// What Not for me says (design language §5: about the music, never the services).
enum NotForMeCopy {
    static let action = "Not for me"
    static let confirmTitle = "Not for me?"
    /// G3: Lidarr's recycle bin is unset. Verbatim.
    static let permanent = "This deletes the files permanently."
    static let recycled = "Its files go to your recycle bin."
    static let removed = "Gone from your Finds."
    static let stillGoing = "Letting it go. It'll be gone from your Finds soon."
    static let failed = "Couldn't let it go this time. It's still in your Finds."
    static let notAFind = "This one can't be let go from here."
    static let unavailable = "Can't let it go right now. Try again in a moment."
    static let changesOff = "Letting finds go is switched off. Turn it on in Settings."
    static let notSetUp = "Letting finds go needs one more step in Settings."
    /// The recycle bin was switched off after the sheet said the files could come back.
    static let confirmAgain = "Your recycle bin was switched off, so nothing was deleted yet. Tap Not for me again to confirm."
    /// It couldn't be finished; nothing more is changed and it isn't offered again.
    static let needsAttention = "Letting this one go didn't finish, and it needs a look."

    /// The confirm sheet (G3.5): the whole release goes, and whether the files can come back.
    static func confirmMessage(album: String?, permanent: Bool) -> String {
        let named = album.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let what = named.map { "\u{201C}\($0)\u{201D} and every song on it leave your Finds." }
            ?? "This song and the rest of its release leave your Finds."
        return what + " " + (permanent ? Self.permanent : recycled)
    }

    static func message(_ outcome: RequestRunner.NotForMeOutcome) -> String {
        switch outcome {
        case .removed: removed
        case .stillGoing: stillGoing
        }
    }

    static func message(for error: Error) -> String {
        switch error as? RequestRunner.NotForMeError {
        case .changesOff?: changesOff
        case .notSetUp?: notSetUp
        case .notAFind?: notAFind
        case .confirmAgain?: confirmAgain
        case .failed?: failed
        case .needsAttention?: needsAttention
        case .unavailable?, nil: unavailable
        }
    }
}

/// The confirm sheet for one find.
struct NotForMeConfirm: Equatable, Identifiable {
    let request: RequestID
    let message: String
    /// Lidarr's recycle bin is unset: the owner confirms a permanent delete.
    let permanent: Bool
    var id: RequestID { request }
}

/// Not for me (Task 6.2c): the runner deletes the find's release from the Finds folder (G3, A16); the app asks
/// first, then takes the find's songs out of the queue and the Finds shelf.
extension AppModel {
    enum NotForMeAsk: Equatable {
        case confirm(NotForMeConfirm)
        case message(String)
    }

    /// What the confirm sheet says, from a fresh read of Lidarr (nothing is written), or why it can't be done.
    func notForMeAsk(_ id: RequestID) async -> NotForMeAsk {
        guard let runner else { return .message(NotForMeCopy.unavailable) }
        do {
            let check = try await runner.notForMeCheck(id)
            return .confirm(NotForMeConfirm(request: id, message: NotForMeCopy.confirmMessage(album: check.albumTitle,
                                                                                              permanent: check.permanent),
                                            permanent: check.permanent))
        } catch {
            return .message(NotForMeCopy.message(for: error))
        }
    }

    /// Lets the find go after the owner confirmed; returns what to tell the owner. Whenever files may have gone
    /// (done, still going, or needing a look), the find's songs leave the queue and the shelf at once.
    func notForMe(_ confirm: NotForMeConfirm) async -> String {
        guard let runner else { return NotForMeCopy.unavailable }
        let songs = requests.first { $0.id == confirm.request }.map(letGoSongIds) ?? []
        defer { pollRequests() }   // a Not for me still going is followed by `tick`
        do {
            let outcome = try await runner.notForMe(confirm.request, permanentConfirmed: confirm.permanent)
            findLetGo(songs)
            return NotForMeCopy.message(outcome)
        } catch {
            if error as? RequestRunner.NotForMeError == .needsAttention { findLetGo(songs) }
            return NotForMeCopy.message(for: error)
        }
    }

    /// The request's song and the other songs of its release in the Finds library: the whole release goes.
    func letGoSongIds(_ request: MagpieRequest) -> Set<String> {
        guard let songId = request.songId else { return [] }
        guard let album = findSongs.first(where: { $0.id == songId })?.albumId else { return [songId] }
        return Set([songId] + findSongs.filter { $0.albumId == album }.map(\.id))
    }

    /// Ruling 8: out of the queue (the one playing gives way to the next) and off the shelf. They stay in the
    /// saved Finds ids, so they are never scrobbled (D29).
    func findLetGo(_ songIds: Set<String>) {
        guard !songIds.isEmpty else { return }
        lettingGoSongIds.formUnion(songIds)
        player.removeSongs(songIds)
        if findSongs.contains(where: { songIds.contains($0.id) }) { findSongs.removeAll { songIds.contains($0.id) } }
        Task { await refreshFinds() }
    }
}
