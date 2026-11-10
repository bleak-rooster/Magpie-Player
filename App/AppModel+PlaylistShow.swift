import Foundation
import MagpieCore

/// Round 22 R22P (owner, 2026-11-06): Library › Playlists shows every playlist, or only the ones you made (D179).
enum PlaylistShow: String, CaseIterable, Sendable {
    case all, yours

    var title: String {
        switch self {
        case .all: "All"
        case .yours: "Yours"
        }
    }

    /// What an empty list says.
    var emptyTitle: String {
        switch self {
        case .all: "No playlists yet"
        case .yours: "You haven\u{2019}t made any playlists yet."
        }
    }

    /// Round 24 (owner, 2026-11-08): under All's list, what it covers (plan item c, D223). Navidrome lists every
    /// playlist the account may see (its own and everyone's shared ones; an admin's, everyone's), so All already is
    /// "all"; this says so. Nothing under Yours.
    var footer: String? {
        switch self {
        case .all: "You see your own and everyone\u{2019}s shared playlists."
        case .yours: nil
        }
    }
}

extension AppModel {
    nonisolated static let playlistShowKeyPrefix = "magpie.playlistShow."
    nonisolated static func playlistShowKey(_ navidromeScope: String) -> String { playlistShowKeyPrefix + navidromeScope }

    /// All or Yours, remembered per account (D180): All by default, and when signed out or the saved value doesn't read.
    var playlistShow: PlaylistShow {
        get {
            guard let navidromeScope else { return .all }
            return appDefaults.string(forKey: Self.playlistShowKey(navidromeScope)).flatMap(PlaylistShow.init) ?? .all
        }
        set {
            guard let navidromeScope else { return }
            appDefaults.set(newValue.rawValue, forKey: Self.playlistShowKey(navidromeScope))
        }
    }

    /// `playlists` as `show` lists them: Yours is Save to playlist's rule (`isOwn`, D101), nothing new; never one of
    /// Discover's (round 22 R22A, D188: they're Aurral's, shown in All only when the owner asks).
    nonisolated static func shown(_ playlists: [Playlist], _ show: PlaylistShow, user: String,
                                  isDiscover: (Playlist) -> Bool = { _ in false }) -> [Playlist] {
        switch show {
        case .all: playlists
        case .yours: playlists.filter { isOwn($0, by: user) && !isDiscover($0) }
        }
    }

    /// `playlists` as the saved choice lists them (the car's Playlists list).
    func shownPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        Self.shown(playlists, playlistShow, user: session?.username ?? "", isDiscover: isDiscoverPlaylist)
    }

    /// Library › Playlists: every playlist but Discover's (Y6; with "Show Discover playlists in Playlists" on, D188,
    /// Discover's too), A–Z for the letter index (P2). Filtered on the phone, so switching All and Yours reads nothing
    /// again.
    func libraryPlaylists() async throws -> [Playlist] {
        try await request { try await $0.playlists() }
            .filter { !leavesOutOfPlaylists($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
