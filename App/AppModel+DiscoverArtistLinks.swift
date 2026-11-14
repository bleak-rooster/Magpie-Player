import AurralKit
import Foundation
import MagpieCore
import NavidromeKit
import Search

/// Round 27 D2 (owner item 4, 2026-11-14): "Artists in this playlist" open the artist's page, whether or not Lidarr has
/// them (D315).
///
/// Resolved on the tap: `search3` for the artist's name (artists only, ten at most) in the listed libraries (the
/// client's scope, Y3: never Discover's, so an artist only in Aurral's library isn't a library artist). The library
/// artist with the same MusicBrainz id, else exactly one artist whose name is the same (folded, `DiscoverRules.normalised`)
/// and whose id, if it has one, isn't another's → the library page; otherwise the outside page (R19: MusicBrainz
/// releases and, with Lidarr, its line). Past `discoverArtistLinkDeadline` the outside page opens. Offline the rows
/// don't open at all (no dead link). Nothing is written anywhere.
extension AppModel {
    /// How long a tap waits for the library's answer before the outside page opens.
    nonisolated static let discoverArtistLinkDeadline: Duration = .seconds(5)

    /// The rows open their pages: signed in and online.
    var discoverArtistLinksAvailable: Bool { session != nil && !isOffline }

    /// Where an artist of a Discover playlist opens: their library page, else the outside page. Nil when the rows don't
    /// open (offline, signed out). `sleep`: the deadline's clock (tests pass their own).
    func discoverArtistRoute(_ artist: DiscoverArtist,
                             sleep: @escaping Deadline.Sleep = { try await Task.sleep(for: $0) }) async -> Route? {
        guard discoverArtistLinksAvailable else { return nil }
        let outside = Route.outsideArtist(NotYetArtist(name: artist.name, mbid: artist.mbid))
        let name = artist.name
        let answer = await Deadline.run(Self.discoverArtistLinkDeadline, sleep: sleep) { [weak self] () async throws -> [Artist] in
            guard let self else { return [] }
            return try await self.request { try await $0.search(name, songCount: 0, albumCount: 0, artistCount: 10) }.artists
        }
        guard case .success(let rows) = answer, let id = Self.libraryArtistId(for: artist, in: rows) else { return outside }
        return .artist(id: id)
    }

    /// The library artist that is `artist`: the same MusicBrainz id, else the one same-named artist (none whose own id
    /// says it is someone else).
    nonisolated static func libraryArtistId(for artist: DiscoverArtist, in rows: [Artist]) -> String? {
        if let mbid = artist.mbid, let same = rows.first(where: { $0.mbid == mbid }) { return same.id }
        let name = DiscoverRules.normalised(artist.name)
        guard !name.isEmpty else { return nil }
        var seen = Set<String>()
        let named = rows.filter { row in
            DiscoverRules.normalised(row.name) == name && (artist.mbid == nil || row.mbid == nil || row.mbid == artist.mbid)
                && seen.insert(row.id).inserted
        }
        return named.count == 1 ? named[0].id : nil
    }
}

/// Round 27 D2 (owner item 5): the artists sheet's words (D315; plan §8).
enum DiscoverArtistLinkCopy {
    /// The row's Add: one short word that never wraps.
    static let add = "Add"

    /// VoiceOver's label for Add, unchanged from before: "Add <artist> to your library".
    static func addLabel(_ name: String) -> String { DiscoverCopy.addArtist(name) }

    /// Fix round 1 (design M6): the link's VoiceOver value while its page is looked up, and what's said on the tap.
    static let opening = "Opening"
    static func openingAnnouncement(_ name: String) -> String { "Opening \(name)" }

    /// The link's VoiceOver label: "<artist>, <status>".
    static func linkLabel(name: String, status: String?) -> String {
        guard let status, !status.isEmpty else { return name }
        return "\(name), \(status)"
    }
}
