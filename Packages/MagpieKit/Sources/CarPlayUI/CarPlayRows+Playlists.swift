import Foundation
import MagpieCore
import Search

// Round 24 item 8 (owner, 2026-11-08): the car's Playlists stopped at the head unit's ceiling ("half the playlists").
// Over the ceiling they now open on D64's five letter groups (A–E, F–J, K–O, P–T, U–Z & #), each with its count, like
// Artists; within it, letter sections as before (D230). Item 3: when everyone's playlists show (All, D179), a playlist
// someone else made says whose in its detail line, by E's rule (D223): never your own, never an unknown owner.

extension CarPlayRows {
    /// Playlists in letter sections within the car's limits, otherwise on the five letter groups (a group's list is
    /// paged with "More…" past the ceiling, D231). Playlists keep leading articles, as the phone's Playlists.
    /// - Parameter signedInUser: who is signed in when everyone's playlists show (All); nil for Yours, so no row names
    ///   an owner.
    public static func playlistBands(_ playlists: [Playlist], maxItems: Int = .max, maxSections: Int = .max,
                                     signedInUser: String? = nil) -> [CPSectionModel] {
        let entries = unique(playlists, \.id).map { playlist in
            let name = display(playlist.name, untitledPlaylist)
            let caption = ownerCaption(owner: playlist.owner, signedInUser: signedInUser)
            let row = CPRowModel(id: "playlist.\(playlist.id)", title: name,
                                 detail: songCount(playlist.songCount) + (caption.map { " \u{00B7} \($0)" } ?? ""),
                                 artworkKey: playlist.coverArtId, action: .open(.playlist(id: playlist.id, title: name)))
            return letterEntry(name: playlist.name, articles: [], row: row)
        }
        let letters = Set(entries.map(\.key)).count
        if entries.count <= maxItems, letters <= maxSections {
            return lettered(entries, kind: .playlists, maxItems: .max, maxSections: .max)
        }
        return bandScreen(entryColumns(entries, byName: true), kind: .playlists, maxItems: maxItems)
    }

    /// Round 24 (D223's rule, the car's text form): the owner's name when it is known and isn't the signed-in user's
    /// (compared ignoring case, as Navidrome signs in); nil otherwise, and always nil without a signed-in user.
    public static func ownerCaption(owner: String?, signedInUser: String?) -> String? {
        guard let user = signedInUser, !user.isEmpty, let owner,
              !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              owner.caseInsensitiveCompare(user) != .orderedSame else { return nil }
        return owner
    }
}
