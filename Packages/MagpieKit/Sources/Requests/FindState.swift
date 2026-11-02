import Foundation
import LidarrKit
import MagpieCore

/// Y5 (plan items 8 and 9.3): where one of Magpie's finds stands, from Lidarr (tags, root path), the ledger (what
/// Magpie wrote) and the requests (intents and the lossless watch). One resolver feeds the artist line, the song and
/// album rows, Activity and CarPlay (through the app's adapters). Pure: no I/O.
public enum FindState: Sendable, Equatable {
    /// "In your Finds": Add to your library is offered.
    case find
    /// The old kept-in-place (I4): untagged but still in the Finds folder, as it was. Nothing offered.
    case keptInFinds
    /// "Adding when your server is free…" (queued) / "Adding to your library…" (sent).
    case adding(queued: Bool)
    /// C1: the main root already has a folder of the artist's name: it stays in Finds (nothing was written).
    case collision
    case inLibrary(Lossless)
    case needsAttention(Attention)

    public enum Lossless: Sendable, Equatable {
        case lossless
        /// The MP3 plays until the lossless copy lands; `removedOn` only for a Keep the owner tapped (C2).
        case waiting(removedOn: Date?)
        /// The MP3 was removed (a read showed it); the album is still searched.
        case mp3Removed
    }

    public enum Attention: Sendable, Equatable { case keep, letGo, mp3 }
}

public enum FindResolver {
    /// Nil: not one of Magpie's finds (the owner's artist, or one Magpie added straight into the library).
    ///
    /// Precedence (design §2): needs attention; a Keep under way; Lidarr says find (the `magpie-find` tag); the old
    /// kept-in-place; a collision the owner was told about; otherwise in the library, with the lossless watch's state.
    public static func resolve(artist: LidarrArtist, entries: [LedgerEntry], requests: [MagpieRequest],
                               findTagId: Int?, findsRoot: String?) -> FindState? {
        let mine = entries.filter { $0.lidarrArtistId == artist.id }
        guard mine.contains(where: { $0.created(artist) }), mine.contains(where: { $0.mode == .finds }) else { return nil }
        let own = requests.filter { $0.lidarrArtistId == artist.id }
        if own.contains(where: { $0.keepNeedsAttention }) { return .needsAttention(.keep) }
        if own.contains(where: { $0.notForMeNeedsAttention }) { return .needsAttention(.letGo) }
        if own.contains(where: { $0.mp3NeedsAttention }) { return .needsAttention(.mp3) }
        if let keep = own.compactMap(\.keep).first { return .adding(queued: keep.phase == .queued) }
        let tagged = findTagId.map(artist.tags.contains) ?? false
        if tagged {
            return own.contains(where: { $0.collision && $0.state == .ready }) ? .collision : .find
        }
        if let root = findsRoot, let path = artist.path, PathGuard(findsRoot: root, otherRoots: [], caseInsensitive: false).isInside(path) {
            return mine.contains(where: \.isKeptOrKeeping) ? .keptInFinds : .find
        }
        guard let watch = own.compactMap(\.lossless).max(by: { $0.startedAt < $1.startedAt }) else {
            return .inLibrary(.waiting(removedOn: nil))
        }
        if watch.losslessAt != nil { return .inLibrary(.lossless) }
        if watch.removedAt != nil { return .inLibrary(.mp3Removed) }
        return .inLibrary(.waiting(removedOn: watch.autoDelete ? watch.deadline : nil))
    }
}
