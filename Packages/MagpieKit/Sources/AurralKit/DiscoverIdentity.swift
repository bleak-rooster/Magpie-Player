import Foundation
import MagpieCore

/// Round 24 (owner, 2026-11-08): "Aurral playlists/flows that share a name across two users both appear even with
/// only-mine selected; tie them to users by identity, not by name (fallback name matching must not cross users)"
/// (D202, supersedes D57's name-only matching; D203 the claim order; D204 the saved claims).
///
/// Aurral keeps which Navidrome playlist is which flow's on the server only (`navidromePlaylistPointerStore`, in no
/// allow-listed route), and Navidrome names one service account as the owner of every Aurral playlist, so the link is
/// rebuilt here from the strongest evidence there is. Each Aurral item (a flow or a shared playlist, anyone's) claims
/// at most one Navidrome playlist and each playlist at most one item, in this order:
/// 1. the exact "<ownerUsername> - <name>" Aurral gives a playlist when its owner prefix is on (folded; its file-name
///    form and a copy number too) names that owner's item;
/// 2. a claim saved from an earlier read (`saved`), while the playlist still carries the item's name;
/// 3. the songs (D62's rule: more than half of the playlist's songs are the item's, by Aurral's jobs for it), best
///    match first; a tie between two items (or two playlists of one name) claims nothing: Q1, never a wrong owner;
/// 4. the name alone, only when no other Aurral item (anyone's) carries that name.
/// At each step a pair counts only when it is the only one left for both its item and its playlist. A playlist none
/// claims is still Aurral's (D182 decides that, not this), with its owner unknown.
public enum DiscoverIdentity {
    /// `[aurralItemId: playlistId]`. `playlists`: the Navidrome playlists that are Aurral's; `entries`: their songs by
    /// playlist id (a playlist not read has no songs to go by); `jobs`: every job Aurral listed (anyone's items' too,
    /// as an admin reads them).
    public static func assign(aurralItems: [AurralFlow], playlists: [Playlist], jobs: [AurralJob], saved: [String: String],
                              entries: [String: [Song]]) -> [String: String] {
        var items: [AurralFlow] = []
        var seenItems = Set<String>()
        for item in aurralItems where !item.id.isEmpty && seenItems.insert(item.id).inserted { items.append(item) }
        var seenPlaylists = Set<String>()
        let lists = playlists.filter { seenPlaylists.insert($0.id).inserted }
        // Every (item, playlist) whose name relates them, with how closely (a lower rank is the plainer name).
        var ranks: [Pair: Rank] = [:]
        for item in items {
            for list in lists {
                if let rank = rank(of: list.name, for: item) { ranks[Pair(item: item.id, playlist: list.id)] = rank }
            }
        }
        var state = Claims()
        // 1. The owner's name in the playlist's.
        state.claimUnique(ranks.filter { $0.value.prefixed }.map(\.key))
        // 2. Saved claims, while still named as the item.
        state.claimUnique(saved.map { Pair(item: $0.key, playlist: $0.value) }.filter { ranks[$0] != nil })
        // 3. The songs, best first; a tie claims nothing and holds both sides back from the name-only step.
        var scored: [(pair: Pair, score: Score)] = []
        for (pair, rank) in ranks where state.free(pair) {
            let songs = entries[pair.playlist] ?? []
            guard !songs.isEmpty else { continue }
            let itemJobs = jobs.filter { $0.flowId == pair.item }
            let matched = songs.filter { DiscoverRules.isFlowSong($0, jobs: itemJobs) }.count
            guard matched * 2 > songs.count else { continue }
            scored.append((pair, Score(matched: matched, count: songs.count, rank: rank.value)))
        }
        for score in Set(scored.map(\.score)).sorted(by: >) {
            let level = scored.filter { $0.score == score && state.free($0.pair) }.map(\.pair)
            for pair in level {
                let rivals = level.filter { $0 != pair && ($0.item == pair.item || $0.playlist == pair.playlist) }
                if rivals.isEmpty { continue }
                state.blockedItems.insert(pair.item)
                state.blockedPlaylists.insert(pair.playlist)
            }
            for pair in level where state.free(pair) { state.claims[pair.item] = pair.playlist }
        }
        // 4. The name alone: the playlist's name is this item's only (no other item, anyone's, carries it), and of the
        //    item's playlists left, the one plainest named.
        var byPlaylist: [String: Int] = [:]
        for pair in ranks.keys { byPlaylist[pair.playlist, default: 0] += 1 }
        let named = ranks.filter { byPlaylist[$0.key.playlist] == 1 && state.free($0.key) }
        var plainest: [Pair] = []
        for item in Set(named.keys.map(\.item)) {
            let mine = named.filter { $0.key.item == item }
            guard let best = mine.values.map(\.value).min() else { continue }
            let top = mine.filter { $0.value.value == best }.map(\.key)
            if top.count == 1 { plainest.append(top[0]) }
        }
        state.claimUnique(plainest)
        return state.claims
    }

    /// D204's upgrade of the saved Discover ids (a set of playlist ids, no item): an id is kept only while exactly one
    /// Aurral item can claim it (by name), and that item only one of the ids.
    public static func migrate(oldIds: Set<String>, aurralItems: [AurralFlow], playlists: [Playlist]) -> [String: String] {
        var byPlaylist: [String: Set<String>] = [:]
        for list in playlists where oldIds.contains(list.id) {
            for item in aurralItems where !item.id.isEmpty && rank(of: list.name, for: item) != nil {
                byPlaylist[list.id, default: []].insert(item.id)
            }
        }
        var byItem: [String: Set<String>] = [:]
        for (playlist, items) in byPlaylist where items.count == 1 {
            if let item = items.first { byItem[item, default: []].insert(playlist) }
        }
        return byItem.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    // MARK: - Pieces

    struct Pair: Hashable { var item: String; var playlist: String }

    struct Rank {
        /// Named "<owner> - <name>" (the owner prefix is an identity, not a name).
        var prefixed: Bool
        /// Where the name sits among the item's names (`aurralNames(of:)`), after them with a copy number.
        var value: Int
    }

    /// Content first (the larger share, then more songs), then the plainer name. Equal only when all three are.
    struct Score: Hashable, Comparable {
        var matched: Int
        var count: Int
        var rank: Int
        static func < (a: Score, b: Score) -> Bool {
            let left = a.matched * b.count, right = b.matched * a.count
            if left != right { return left < right }
            if a.matched != b.matched { return a.matched < b.matched }
            return a.rank > b.rank
        }
    }

    /// How `name` relates to the item: one of its names (D181), else one of them with Aurral's copy number; nil if not.
    static func rank(of name: String, for item: AurralFlow) -> Rank? {
        let folded = DiscoverRules.normalised(name)
        guard !folded.isEmpty else { return nil }
        let names = DiscoverRules.aurralNames(of: item)
        let prefixes = prefixNames(of: item)
        if let index = names.firstIndex(of: folded) { return Rank(prefixed: prefixes.contains(folded), value: index) }
        if let base = DiscoverRules.withoutCopyNumber(folded), let index = names.firstIndex(of: base) {
            return Rank(prefixed: prefixes.contains(base), value: names.count + index)
        }
        return nil
    }

    /// "<owner> - <name>" and its file-name form, folded; none without an owner's name.
    static func prefixNames(of item: AurralFlow) -> Set<String> {
        let name = DiscoverRules.normalised(item.name)
        guard !name.isEmpty, let owner = item.ownerUsername.map(DiscoverRules.normalised), !owner.isEmpty else { return [] }
        let prefixed = owner + " - " + name
        return [prefixed, DiscoverRules.fileName(prefixed)]
    }

    /// What is claimed so far, and what a tie holds back.
    struct Claims {
        var claims: [String: String] = [:]
        var blockedItems = Set<String>()
        var blockedPlaylists = Set<String>()

        func free(_ pair: Pair) -> Bool {
            claims[pair.item] == nil && !claims.values.contains(pair.playlist)
                && !blockedItems.contains(pair.item) && !blockedPlaylists.contains(pair.playlist)
        }

        /// Claims each pair that is, among the free ones given, the only one for its item and for its playlist; again
        /// until nothing changes (a claim can leave another pair the only one).
        mutating func claimUnique(_ pairs: [Pair]) {
            var changed = true
            while changed {
                changed = false
                let open = pairs.filter(free)
                for pair in open.sorted(by: { ($0.item, $0.playlist) < ($1.item, $1.playlist) }) where free(pair) {
                    let rivals = open.filter { $0 != pair && ($0.item == pair.item || $0.playlist == pair.playlist) }
                    guard rivals.isEmpty else { continue }
                    claims[pair.item] = pair.playlist
                    changed = true
                }
            }
        }
    }
}
