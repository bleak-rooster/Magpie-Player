import Foundation
import MagpieCore

/// R19 "Try this album" and R20's dedupe by release group.
extension RequestRunner {
    /// Never a real release group: stands in for "no target" in a set lookup.
    var rgNone: MBID { MBID("00000000-0000-0000-0000-000000000000")! }

    /// The target, when the artist's catalogue allows it (the owner's artist: an album it has; a new artist: one the
    /// Finds metadata profile lists). A target that isn't allowed is never swapped for another release group.
    static func albumTarget(_ target: MBID?, allowed: Bool) -> MBID? {
        guard let target, allowed else { return nil }
        return target
    }

    /// A live (or Ready) request bringing in this release group: resolved to it, or a Try this album aimed at it.
    func liveRequest(releaseGroup: MBID?) -> MagpieRequest? {
        guard let releaseGroup else { return nil }
        return list.first { ($0.isActive || $0.state == .ready) && ($0.plan?.releaseGroupMBID ?? $0.albumTarget) == releaseGroup }
    }
}
