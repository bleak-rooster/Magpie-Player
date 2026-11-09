import AurralKit
import Foundation
import MagpieCore
import NavidromeKit

/// Round 24 C: what a Discover page's Delete removes in Aurral: one of the user's flows or Aurral playlists.
enum AurralItemKind: Sendable, Equatable { case flow, playlist }

/// Round 24 C (D212): the user's own flow or Aurral playlist a Discover page may delete.
struct AurralItemToDelete: Sendable, Equatable {
    /// Aurral's id for it (the flow's or the shared playlist's).
    var id: String
    var name: String
    var kind: AurralItemKind
}

/// Round 24 C (D212): a delete Aurral queued: what was asked, the Discover playlists that are its, and when.
struct AurralRemoval: Sendable, Equatable {
    var item: AurralItemToDelete
    var playlistIds: Set<String>
    var startedAt: Date
}

/// Round 24 C (D212): where a delete is: Aurral hasn't run it yet; still hasn't after `aurralRemovalLimit`; done.
enum AurralRemovalState: Sendable, Equatable { case removing, stillRemoving, deleted }

/// Round 24 C (owner, 2026-11-08: "Delete Aurral playlists and flows", item 5; D212; ruling Q4).
///
/// - Offered in a Discover page's More menu, on the user's **own** flow ("Delete flow") or Aurral playlist ("Delete
///   playlist") only: never another user's, even for an Aurral admin (Aurral would let an admin, but D190 keeps everyone
///   else's read only), never a playlist kept without a known flow. Hidden without `AurralCapabilities.canManage`
///   (2.13's routes and the user's accessFlow) and offline.
/// - After the confirmation, B's `deleteFlow` / `deleteSharedPlaylist` (D207, D208): sent once, never again by itself.
///   Marked as removing before it is sent, so a second tap can't send it twice.
/// - Aurral queues the delete: "Aurral is removing it…" until a status read no longer lists it ("Aurral is still removing
///   it." after `aurralRemovalLimit`; the page then stops asking). A 404 is already gone: deleted at once.
/// - Then Discover's saved ids for its playlists are forgotten (Workstream A's per-item map hasn't landed: the
///   per-account sets in `AppModel+Discover`, `+DiscoverEveryone`). Aurral removes its own Navidrome copy; Magpie never
///   deletes or changes a Navidrome playlist. One still listed is kept as Discover's, with no flow (so no Refresh Flow,
///   Search again or Delete), and stays out of Playlists: when in doubt, leave out; the next read settles it (D75).
extension AppModel {
    /// How long a queued delete shows "Aurral is removing it…" before "Aurral is still removing it.".
    nonisolated static let aurralRemovalLimit: TimeInterval = 120

    /// The user may manage their own Aurral items here: this Aurral has the routes, the user accessFlow, and Magpie is
    /// online.
    var aurralMayManage: Bool {
        !isOffline && aurralCapabilities.canManage(as: discover.bootstrap?.user)
    }

    /// The user's own flow or Aurral playlist with Aurral's id `id`, as last read (nil: another user's, or unknown).
    func ownAurralItem(id: String) -> (item: AurralFlow, kind: AurralItemKind)? {
        guard !id.isEmpty, let user = discover.bootstrap?.user, let status = discover.status else { return nil }
        if let flow = status.flows.first(where: { $0.id == id }), flow.belongs(to: user) { return (flow, .flow) }
        if let playlist = status.sharedPlaylists.first(where: { $0.id == id }), playlist.belongs(to: user) {
            return (playlist, .playlist)
        }
        return nil
    }

    /// What a Discover page's Delete would remove, or nil when it isn't offered (D212).
    func deletableAurralItem(playlistId: String) -> AurralItemToDelete? {
        guard aurralMayManage,
              let flow = discover.playlists.first(where: { $0.playlist.id == playlistId })?.flow.nonEmpty,
              discover.removing[flow.id] == nil, let own = ownAurralItem(id: flow.id) else { return nil }
        return AurralItemToDelete(id: own.item.id, name: own.item.name, kind: own.kind)
    }

    /// The delete under way for a Discover playlist, if any.
    func aurralRemoval(playlistId: String) -> AurralRemoval? {
        discover.removing.values.first { $0.playlistIds.contains(playlistId) }
    }

    /// Delete flow / Delete playlist, after the owner confirmed: sent once. `.removing` while Aurral's queued delete
    /// hasn't run; `.deleted` when Aurral says it is already gone. Throws (nothing marked, nothing changed) when Aurral
    /// refuses or can't be reached; `notPermitted` when it isn't offered.
    func deleteAurralItem(playlistId: String) async throws -> AurralRemovalState {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard let item = deletableAurralItem(playlistId: playlistId), let client = aurralClient else {
            throw AurralError.notPermitted
        }
        let ids = Set(discover.playlists.filter { $0.flow.id == item.id }.map(\.playlist.id))
        discover.removing[item.id] = AurralRemoval(item: item, playlistIds: ids, startedAt: discover.now())   // before sending
        let result: AurralDeleteResult
        do {
            result = item.kind == .flow ? try await client.deleteFlow(item.id) : try await client.deleteSharedPlaylist(item.id)
        } catch {
            discover.removing[item.id] = nil
            noteAurralError(error)
            throw error
        }
        guard result != .alreadyGone else {
            await forgetRemovedAurralItem(item.id)
            return .deleted
        }
        return .removing
    }

    /// One look at whether Aurral has run the delete (a fresh status read): `.deleted` (and forgotten here) once the
    /// status no longer lists it. A read that fails changes nothing. Nil: no delete under way for this playlist.
    func checkAurralRemoval(playlistId: String) async -> AurralRemovalState? {
        guard let removal = aurralRemoval(playlistId: playlistId) else { return nil }
        if !isOffline, let client = aurralClient {
            do {
                let status = try await client.status()
                noteStatus(status)
                let listed = (status.flows + status.sharedPlaylists + status.othersPlaylists).contains { $0.id == removal.item.id }
                if !listed, discover.removing[removal.item.id] == removal {
                    await forgetRemovedAurralItem(removal.item.id)
                    return .deleted
                }
            } catch {
                noteAurralError(error)
            }
        }
        return discover.now().timeIntervalSince(removal.startedAt) > Self.aurralRemovalLimit ? .stillRemoving : .removing
    }

    /// Aurral has removed it: Discover's saved ids for its playlists go, as do this session's Search again and Refresh
    /// Flow records for it. A playlist Navidrome still lists (or that couldn't be checked) stays Discover's, with no flow.
    private func forgetRemovedAurralItem(_ itemId: String) async {
        guard let removal = discover.removing[itemId] else { return }
        let listed = (try? await request { try await $0.playlists() }).map { Set($0.map(\.id)) }
        let lingering = listed.map { removal.playlistIds.intersection($0) } ?? removal.playlistIds
        let gone = removal.playlistIds.subtracting(lingering)
        discover.playlists = discover.playlists.compactMap { entry in
            guard removal.playlistIds.contains(entry.playlist.id) else { return entry }
            if gone.contains(entry.playlist.id) { return nil }
            return DiscoverPlaylist(flow: AurralFlow(id: "", name: entry.playlist.name), playlist: entry.playlist)
        }
        if let scope = navidromeScope {
            for key in [Self.discoverPlaylistsKey(scope), Self.ownPlaylistsKey(scope), Self.othersPlaylistsKeyPrefix + scope] {
                if let saved = appDefaults.stringArray(forKey: key) {
                    appDefaults.set(saved.filter { !gone.contains($0) }, forKey: key)
                }
            }
        }
        discover.othersPlaylistIds.subtract(gone)
        for id in removal.playlistIds { discover.searchAgain[id] = nil }
        discover.refreshing[itemId] = nil
        discover.removing[itemId] = nil
        libraryEdits.playlistsRevision += 1   // Library › Discover and Playlists read again
        homeFeedSlot?.sectionsChanged([.discover, .playlists])
    }
}

/// The words for D212, the plan's exactly (§6 C).
enum AurralDeleteCopy {
    static func menuItem(_ kind: AurralItemKind) -> String { kind == .flow ? "Delete flow" : "Delete playlist" }
    static func title(_ name: String) -> String { "Delete \u{201C}\(name)\u{201D}?" }
    static func message(_ kind: AurralItemKind) -> String {
        switch kind {
        case .flow: "Aurral stops making it and removes its songs from your Aurral library unless another playlist uses them. This can\u{2019}t be undone."
        case .playlist: "Aurral removes this playlist and the songs only it was keeping. This can\u{2019}t be undone."
        }
    }
    // G1 allowlist: copy (the confirmation button's word, never a request's verb)
    static let confirm = "Delete"
    static let keep = "Keep it"
    static func deleted(_ name: String) -> String { "Deleted \u{201C}\(name)\u{201D}." }
    static let failed = "Aurral couldn\u{2019}t delete it. Nothing was changed."
    static let removing = "Aurral is removing it\u{2026}"
    /// Plan §3 d: a delete Aurral queued but hasn't run.
    static let stillRemoving = "Aurral is still removing it."
}
