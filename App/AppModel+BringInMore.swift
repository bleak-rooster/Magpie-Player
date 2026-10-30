import Foundation
import MagpieCore
import Requests

/// What the Bring in more sheet says (design language §5: about the music, never the services). Sizes only as
/// "about N hours of music", from the lengths Lidarr already knows; no number when it doesn't (A5).
enum BringInCopy {
    static let follow = "Follow new releases"
    static let followNote = "New releases come in as they come out."
    static let followingAlready = "You get new releases from this artist already."
    static let bring = "Bring them in"
    static let notNow = "Not now"
    static let loading = "Looking at what else there is…"
    static let retry = "Try again"

    /// A blank name (Lidarr has none) still reads as a sentence.
    static func title(_ artist: String) -> String {
        "Bring in more from \(artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "this artist" : artist)?"
    }

    static func choice(_ choice: RequestRunner.BringInChoice) -> String {
        switch choice {
        case .albumsAndEPs: "Albums and EPs"
        case .thisAlbum: "This album only"
        case .everything: "Everything"
        }
    }

    /// "about N hours of music" (at least 1), or nil when the length isn't known.
    static func size(_ duration: TimeInterval?) -> String? {
        // `Int(exactly:)`: a finite length past Int's range (`1e300` from Lidarr) is unknown too; `Int(_:)` trapped
        // (crash hunt 4, with hunter 1).
        guard let duration, duration > 0, let whole = Int(exactly: (duration / 3600).rounded()) else { return nil }
        let hours = max(1, whole)
        return "about \(hours) \(hours == 1 ? "hour" : "hours") of music"
    }

    static func releases(_ n: Int) -> String { "\(n) \(n == 1 ? "release" : "releases")" }

    /// The line under a choice: what it brings in and how much music that is.
    static func detail(_ option: RequestRunner.BringInOption) -> String {
        if let title = option.title {
            guard !option.albumIds.isEmpty else { return "\(title) · in your library already" }
            return ([title] + [size(option.duration)].compactMap { $0 }).joined(separator: " · ")
        }
        guard !option.albumIds.isEmpty else { return "Nothing more to bring in" }
        return ([releases(option.albumIds.count)] + [size(option.duration)].compactMap { $0 }).joined(separator: " · ")
    }

    /// G7: said plainly when a choice has more than one Bring in more brings in (the limit of five counts songs and
    /// releases on their way, FL4).
    static func capped(_ option: RequestRunner.BringInOption) -> String? {
        guard option.isCapped else { return nil }
        guard !option.albumIds.isEmpty else {
            return "Five songs and releases are already on their way, so these can come in later. You can still follow new releases."
        }
        return "That's a lot at once, so the newest \(option.albumIds.count) of \(option.available) come in now."
    }

    static func done(_ result: RequestRunner.BringInResult, artist: String) -> String {
        let followNote = result.following ? " New releases will come in too." : ""
        // FL4: fewer than the sheet said, because more is on its way now than when it opened.
        let waitNote = result.heldBack > 0
            ? " \(releases(result.heldBack)) more can come in when something on its way is home." : ""
        if result.albums > 0 {
            let asked = result.searching
                ? "Bringing in \(releases(result.albums)) from \(artist)."
                : "Asked for \(releases(result.albums)) from \(artist). They'll come in when they're found."
            return asked + followNote + waitNote
        }
        if result.following { return "New releases from \(artist) will come in as they come out." + waitNote }
        if result.heldBack > 0 { return "Five songs and releases are already on their way." + waitNote }
        return "Nothing more to bring in right now."
    }

    static func message(for error: Error) -> String {
        switch error as? RequestRunner.BringInError {
        case .changesOff?: "Bringing in more is switched off. Turn it on in Settings."
        case .notSetUp?: "Bringing in more needs one more step in Settings."
        case .notKept?: "This one can't bring in more from here."
        case .tooMany?: "Five songs and releases are already on their way. Bring in more when one of them is home or has stopped."
        case .failed?: "Couldn't bring them in this time. Nothing new is on its way yet."
        case .unconfirmed?: "Couldn't tell whether that went through. Try again to see what's still to come."
        case .unavailable?, nil: "Can't bring in more right now."
        }
    }

    /// The sheet offers Try again (a fresh look at what's still to bring in) after these.
    static func isRetryable(_ error: Error) -> Bool {
        switch error as? RequestRunner.BringInError {
        case .failed?, .unconfirmed?, .unavailable?, nil: true
        case .changesOff?, .notSetUp?, .notKept?, .tooMany?: false
        }
    }
}

/// Bring in more (Task 7.1b, D5): the runner reads and writes Lidarr (RequestRunner+BringInMore.swift); the app
/// shows the choices and says how it went.
extension AppModel {
    /// What to tell the owner, and whether the sheet offers Try again.
    struct BringInReply: Equatable {
        var message: String
        var retryable = false

        init(message: String, retryable: Bool = false) { self.message = message; self.retryable = retryable }

        init(error: Error) {
            self.init(message: BringInCopy.message(for: error), retryable: BringInCopy.isRetryable(error))
        }
    }

    enum BringInLoad {
        case offer(RequestRunner.BringInOffer)
        case message(BringInReply)
    }

    func bringInOffer(_ id: RequestID) async -> BringInLoad {
        guard let runner else { return .message(BringInReply(error: RequestRunner.BringInError.unavailable)) }
        do {
            return .offer(try await runner.bringInOffer(id))
        } catch {
            return .message(BringInReply(error: error))
        }
    }

    /// Brings in `choice` (nil: no releases) and follows new releases when `follow`. `offered`: the release ids the
    /// sheet showed, so never more than it said come in (FL4).
    func bringIn(_ id: RequestID, choice: RequestRunner.BringInChoice?, offered: [Int]?, follow: Bool,
                 artist: String) async -> BringInReply {
        guard let runner else { return BringInReply(error: RequestRunner.BringInError.unavailable) }
        do {
            let result = try await runner.bringIn(id, choice: choice, offered: offered, follow: follow)
            return BringInReply(message: BringInCopy.done(result, artist: artist))
        } catch {
            return BringInReply(error: error)
        }
    }
}
