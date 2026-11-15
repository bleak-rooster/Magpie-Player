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

// Round 27 H (owner, 2026-11-14): "In carplay, there should be a switch in the settings to show aurral playlists/flows
// and playlists combined" (D300), and "if it includes other people's ones, then their username should be on it
// somewhere" (D299, D233's " · sam" in the car).

extension CarPlayRows {
    /// D300: the car's Playlists list with Settings › CarPlay › Flows with your playlists on: `playlists` (as All or
    /// Yours lists them) and `flows` (the Discover playlists Discover shows), each once, A to Z (ignoring case and
    /// accents; `playlistBands` files them in D230's letter sections or groups). A flow's row names whose it is the way
    /// a playlist's does (`playlistBands`' `signedInUser` rule): its owner becomes `captions[id]` (another user's, as
    /// the app decided, D205) or else `signedInUser`, so the user's own flows name nobody whoever the server says made
    /// the playlist. A playlist that isn't a flow keeps its owner.
    public static func playlistsWithFlows(_ playlists: [Playlist], flows: [Playlist], captions: [String: String],
                                          signedInUser: String?) -> [Playlist] {
        let flowIds = Set(flows.map(\.id))
        let named = flows.map { flow -> Playlist in
            var flow = flow
            flow.owner = captions[flow.id] ?? signedInUser
            return flow
        }
        let merged = unique(playlists.filter { !flowIds.contains($0.id) } + named, \.id)
        return merged.sorted { a, b in
            switch a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive]) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.id < b.id
            }
        }
    }

    /// D299: Library › Discover's rows (`discover(_:)`), another user's ending " · sam" (`captions`: the app's
    /// `discoverOwnerCaption`, by playlist id; never the user's own or an ownerless one).
    public static func discover(_ playlists: [Playlist], captions: [String: String]) -> [CPSectionModel] {
        discover(playlists).map { section in
            var section = section
            section.rows = section.rows.map { row in
                guard row.id.hasPrefix(discoverRowPrefix) else { return row }   // the empty state's row
                return captioned(row, captions[String(row.id.dropFirst(discoverRowPrefix.count))])
            }
            return section
        }
    }

    static let discoverRowPrefix = "discover."

    /// `row` with " · caption" after its detail; as it is without a caption.
    static func captioned(_ row: CPRowModel, _ caption: String?) -> CPRowModel {
        guard let caption, !caption.isEmpty else { return row }
        var row = row
        row.detail = (row.detail ?? "") + " \u{00B7} \(caption)"
        return row
    }
}
