import Foundation
import MagpieCore

/// Round 15 C3 (owner item 6, D135, D136): what happens after Try or Add to library, and what a row says.
///
/// Add to library on a find (an artist on trial) is kept on arrival through the existing Keep (D52: intent → PUT →
/// verify → commit, the gate's rules); a new artist goes straight into the main library, and a library artist's release
/// is monitored and searched there, so neither needs anything more.
public enum LibraryAdds {
    public enum Step: Equatable, Sendable {
        /// Nothing to do now (on its way, kept already, a Keep under way, or one that can't be asked again from here).
        case none
        /// Arrived as a find, for the library: keep it (the runner proves the Keep again on fresh state).
        case keep(RequestID)
    }

    /// A song's or album's row (D136): In your library / On trial / Coming (with progress) / Couldn't bring it in.
    public enum Status: Equatable, Sendable {
        case inLibrary
        case onTrial
        case coming(Double?)
        case couldntBringIn
    }

    public static func step(_ r: MagpieRequest) -> Step {
        guard r.addToLibrary, r.state == .ready, r.isFind, r.songId != nil else { return .none }
        // Never asked again from here once a Keep ran, refused or needs a look, or once Not for me started (D101's rule).
        if r.keep != nil || r.collision || r.keptInPlace || r.keepFailed || r.keepNeedsAttention { return .none }
        if r.notForMe != nil || r.notForMeNeedsAttention { return .none }
        return .keep(r.id)
    }

    /// Nil: nothing to say (cancelled or removed: the actions are offered again).
    public static func status(_ r: MagpieRequest) -> Status? {
        switch r.state {
        case .pending, .resolving, .adding, .searching, .waiting, .importing: return .coming(nil)
        case .downloading(let progress): return .coming(progress)
        case .kept: return .inLibrary
        case .failed: return .couldntBringIn
        case .dismissed, .cancelled: return nil
        case .ready:
            if r.isLibraryTrial { return .onTrial }
            guard r.isFind else { return .inLibrary }
            // A find for the library is still coming while it's kept; one that can't be kept stays on trial.
            if r.keep != nil { return .coming(nil) }
            if r.addToLibrary, step(r) != .none { return .coming(nil) }
            return .onTrial
        }
    }
}
