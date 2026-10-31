import Foundation
import MagpieCore
import Requests

/// R16 + R20 (appraisal "R16 / Activity"): what a Ready find offers on its own request page (Play · Keep · Not for
/// me…) and as the leading swipe on Library › Requests (Keep). The same rules as the Finds shelf (`FindsShelf`), asked
/// of the request itself; the runner checks everything again on fresh state.
enum ReadyFindActions {
    /// The find to Keep, or nil: a Ready find, listed by the library, with no Keep or Not for me under way.
    static func keep(_ request: MagpieRequest) -> RequestID? {
        guard request.isFind, let song = song(request) else { return nil }
        return FindsShelf.keepRequest(for: song, in: [request])
    }

    /// The find to let go (Not for me), or nil: as Keep, and only for a new artist that Magpie added.
    static func notForMe(_ request: MagpieRequest) -> RequestID? {
        guard let song = song(request) else { return nil }
        return FindsShelf.notForMeRequest(for: song, in: [request])
    }

    private static func song(_ request: MagpieRequest) -> Song? {
        request.songId.map { Song(id: $0, title: request.recording.title, artist: request.recording.artist, album: "", duration: 0) }
    }
}

extension RequestCopy {
    /// R20: under the wait view's stages in the Try sheet, whose button says Done (never "Leave").
    static let keepBrowsing = "You can keep browsing. It plays next when it's here."
    /// R20: Not for me on a request page asks first, so it carries the ellipsis.
    static let notForMeAsks = "\(NotForMeCopy.action)…"
    static let keep = "Keep"
}
