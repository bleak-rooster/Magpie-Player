import AurralKit
import Foundation
import MagpieCore

/// Round 24 (owner, 2026-11-08): "Aurral playlists/flows that share a name across two users both appear even with
/// only-mine selected; tie them to users by identity, not by name (fallback name matching must not cross users)", and
/// "when showing everyone's playlists/flows, show the owner's username subtly near the name" (D202–D205).
///
/// - Which Aurral item (a flow or a shared playlist, anyone's) each of Aurral's Navidrome playlists is comes from
///   `DiscoverIdentity.assign`: one to one, by the owner's prefix, a saved claim, the songs, then a name no other item
///   carries (D203). Whether a playlist is Aurral's at all is still D182's call (`keptDiscoverPlaylists`).
/// - "Only mine" (D189) then reads the claiming item's owner, never the playlist's name: the user's own item's
///   playlist is the user's; another user's, or one no item could claim (a tie, Q1), is listed only under everyone's
///   and never in Playlists. A playlist no item is named as now (D75's orphan) keeps what it was.
/// - The claims are saved per account by Aurral item id (`magpie.discoverClaims.<account hash>`, D204), forgotten with
///   the other Discover keys and when Aurral has deleted the item (R24C's `forgetRemovedAurralItem`). Fix round 1
///   (I2): only proven claims are saved (the owner's prefix, the songs, a saved claim the songs don't contradict); a
///   name-only claim lasts for its read.
extension AppModel {
    nonisolated static let discoverClaimsKeyPrefix = "magpie.discoverClaims."
    nonisolated static func discoverClaimsKey(_ scope: String) -> String { discoverClaimsKeyPrefix + scope }

    /// D204: the saved `[aurralItemId: playlistId]`, nil when none was ever saved for the account.
    func savedDiscoverClaims(scope: String) -> [String: String]? {
        appDefaults.dictionary(forKey: Self.discoverClaimsKey(scope)) as? [String: String]
    }

    /// Hook from each read of Aurral (`performDiscoverRead`), after D182 decided which playlists are Aurral's: each one
    /// named as an item gets the item that claims it (the user's own flow as it is; another user's with no flow id,
    /// D184; none claiming: no flow and no owner), and the set listed only under everyone's. `named`: the playlists
    /// named as an item on this read; `mine` and `others`: the user's items and other users' (`AurralStatus.scoped`).
    /// With no items listed at all (Z1's fail-closed status) nothing is reassigned or saved.
    /// Round 25 J (D251): `proof`: the songs read for each item left unproven, and the items asked for that gave none
    /// (`readDiscoverItemProof`; fix round 1, I1).
    func identifyDiscoverPlaylists(_ matched: [DiscoverPlaylist], mine: [AurralFlow], others: [AurralFlow],
                                   named: Set<String>, jobs: [AurralJob], entries: [String: [Song]],
                                   proof: DiscoverItemProof = DiscoverItemProof(),
                                   scope: String) -> (playlists: [DiscoverPlaylist], notMine: Set<String>) {
        let before = othersDiscoverPlaylistIds
        func keptAsItWas(_ m: DiscoverPlaylist) -> Bool {   // R23F's rule for a playlist kept without a known flow
            m.flow.id.isEmpty && (m.flow.ownerUserId != nil || m.flow.ownerUsername != nil || before.contains(m.playlist.id))
        }
        let items = mine + others
        guard !items.isEmpty else {
            noteDiscoverItemRows(nil)   // R26L (D271): no items listed, no rows of their own
            return (matched, Set(matched.filter(keptAsItWas).map(\.playlist.id)))
        }
        let saved = discoverClaimsToResolve(scope: scope, items: items, playlists: matched.map(\.playlist))
        // Fix round 1 (I2): a run under way isn't evidence against a saved claim (D75); only proof is saved, never a
        // name-only claim, so another user's same-named playlist never becomes the user's for good.
        let assignment = DiscoverIdentity.resolve(aurralItems: items,
                                                  playlists: matched.map(\.playlist).filter { named.contains($0.id) },
                                                  jobs: jobs, saved: saved, entries: entries,
                                                  running: Set(mine.map(\.id).filter(isFlowRunActive)),
                                                  itemJobs: proof.jobs, unread: proof.unread)
        let claims = assignment.claims
        appDefaults.set(assignment.proven, forKey: Self.discoverClaimsKey(scope))
        let claimedBy = Dictionary(claims.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let mineById = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let othersById = Dictionary(others.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var notMine = Set<String>()
        var owners: [String: String] = [:]
        defer { discover.playlistOwners = owners }   // M6: the captions' lookup
        let playlists = matched.map { m -> DiscoverPlaylist in
            let id = m.playlist.id
            guard named.contains(id) else {
                if keptAsItWas(m) { notMine.insert(id) }
                return m
            }
            if let item = claimedBy[id], let flow = mineById[item] { return DiscoverPlaylist(flow: flow, playlist: m.playlist) }
            notMine.insert(id)
            if let item = claimedBy[id], let other = othersById[item] {
                owners[id] = other.ownerUsername
                return DiscoverPlaylist(flow: AurralFlow(id: "", name: other.name, ownerUserId: other.ownerUserId,
                                                         ownerUsername: other.ownerUsername), playlist: m.playlist)
            }
            return DiscoverPlaylist(flow: AurralFlow(id: "", name: m.playlist.name), playlist: m.playlist)   // Q1
        }
        // R26L (D271, D272): the items no playlist is known to be are rows of their own, by Aurral id.
        noteDiscoverItemRows(DiscoverItemRead(mine: mine, others: others, claims: claims, playlists: playlists,
                                              named: named, entries: entries))
        return (playlists, notMine)
    }

    /// The saved claims a read starts from: D204's, else round 23's saved ids upgraded (`DiscoverIdentity.migrate`).
    func discoverClaimsToResolve(scope: String, items: [AurralFlow], playlists: [Playlist]) -> [String: String] {
        savedDiscoverClaims(scope: scope)
            ?? DiscoverIdentity.migrate(oldIds: Set(appDefaults.stringArray(forKey: Self.discoverPlaylistsKey(scope)) ?? []),
                                        aurralItems: items, playlists: playlists)
    }

    /// Hook from R24C's `forgetRemovedAurralItem`: Aurral has deleted the item, so its claim goes.
    func forgetDiscoverClaim(itemId: String) {
        guard let scope = navidromeScope, var claims = savedDiscoverClaims(scope: scope) else { return }
        claims[itemId] = nil
        appDefaults.set(claims, forKey: Self.discoverClaimsKey(scope))
    }

    /// D205: the owner shown under an Aurral row's name ("sam"): only while everyone's flows are shown, only for
    /// another user's item that claimed the playlist (never a guessed owner), never the signed-in user's own.
    func discoverOwnerCaption(playlistId: String) -> String? {
        guard showEveryonesFlows, let owner = discover.playlistOwners[playlistId] else { return nil }   // fix round 1 (M6)
        return OwnerCaption.text(owner: owner, signedInUser: discover.connection?.username)
    }
}
