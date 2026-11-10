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
///    form and a copy number too) names that owner's item, unless another item carries the playlist's name more
///    plainly (an item literally called "jordan - Chill");
/// 2. a claim saved from an earlier read (`saved`), while the playlist still carries the item's name and its songs
///    don't contradict it;
/// 3. the songs (D62's rule: more than half of the playlist's songs are the item's, by Aurral's jobs for it), best
///    match first; a tie between two items (or two playlists of one name) claims nothing: Q1, never a wrong owner;
/// 4. the name alone, only when no other Aurral item (anyone's) carries that name and the songs don't contradict it.
/// At each step a pair counts only when it is the only one left for both its item and its playlist. A playlist none
/// claims is still Aurral's (D182 decides that, not this), with its owner unknown.
///
/// Fix round 1 (review I2): the songs **contradict** a pair when the playlist's songs were read (some), Aurral listed
/// jobs for the item, no run of the item is under way, and the songs fail D62's rule. A contradicted pair is never
/// claimed by a saved claim or by name. Only proof is kept for the next read (`Assignment.proven`): steps 1 and 3, and
/// a saved claim nothing contradicts (it was proven when first saved). A name-only claim lasts for its read only, so a
/// user who isn't an admin (who sees only their own items) never makes another user's same-named playlist theirs
/// for good.
public enum DiscoverIdentity {
    /// One read's claims, and the ones proven enough to save for the next read.
    public struct Assignment: Sendable, Equatable {
        /// `[aurralItemId: playlistId]`, every claim this read.
        public var claims: [String: String]
        /// The claims to save (D204): never a name-only one.
        public var proven: [String: String]
    }

    /// `[aurralItemId: playlistId]`: `resolve(...)`'s claims.
    public static func assign(aurralItems: [AurralFlow], playlists: [Playlist], jobs: [AurralJob], saved: [String: String],
                              entries: [String: [Song]], running: Set<String> = [],
                              itemJobs: [String: [AurralJob]] = [:]) -> [String: String] {
        resolve(aurralItems: aurralItems, playlists: playlists, jobs: jobs, saved: saved, entries: entries,
                running: running, itemJobs: itemJobs).claims
    }

    /// `playlists`: the Navidrome playlists that are Aurral's; `entries`: their songs by playlist id (a playlist not
    /// read has no songs to go by); `jobs`: every job Aurral listed (anyone's items' too, as an admin reads them);
    /// `running`: the items with a run under way (their jobs may not be the playlist's songs yet, D75).
    /// Round 25 J (D251): `itemJobs`: an item's own songs as Aurral lists them for it (`jobs/:id`), read for the items
    /// `unproven` names; where one has any, they are that item's songs in place of the general list's.
    public static func resolve(aurralItems: [AurralFlow], playlists: [Playlist], jobs: [AurralJob], saved: [String: String],
                               entries: [String: [Song]], running: Set<String> = [],
                               itemJobs: [String: [AurralJob]] = [:]) -> Assignment {
        let index = Index(items: aurralItems, playlists: playlists, jobs: jobs, entries: entries, itemJobs: itemJobs)
        var state = Claims()
        var proven: [String: String] = [:]
        func contradicted(_ pair: Pair) -> Bool {
            guard !running.contains(pair.item), let fit = index.fit(pair) else { return false }
            return !fit.passes
        }
        // 1. The owner's name in the playlist's, unless another item carries the name more plainly (M5).
        let prefixed = index.ranks.filter { pair, rank in
            rank.prefixed && !(index.byPlaylist[pair.playlist] ?? []).contains { other in
                other != pair.item && (index.ranks[Pair(item: other, playlist: pair.playlist)]?.value ?? .max) < rank.value
            }
        }.map(\.key)
        for pair in state.claimUnique(prefixed) { proven[pair.item] = pair.playlist }
        // 2. Saved claims, while still named as the item and not contradicted by its songs.
        let stillNamed = saved.map { Pair(item: $0.key, playlist: $0.value) }
            .filter { index.ranks[$0] != nil && !contradicted($0) }
        for pair in state.claimUnique(stillNamed) { proven[pair.item] = pair.playlist }
        // 3. The songs, best first; a tie claims nothing and holds both sides back from the name-only step.
        var scored: [(pair: Pair, score: Score)] = []
        for (pair, rank) in index.ranks where state.free(pair) {
            guard let fit = index.fit(pair), fit.passes else { continue }
            scored.append((pair, Score(matched: fit.matched, count: fit.count, rank: rank.value)))
        }
        for score in Set(scored.map(\.score)).sorted(by: >) {
            let level = scored.filter { $0.score == score && state.free($0.pair) }.map(\.pair)
            for pair in level where level.contains(where: { $0 != pair && ($0.item == pair.item || $0.playlist == pair.playlist) }) {
                state.blockedItems.insert(pair.item)
                state.blockedPlaylists.insert(pair.playlist)
            }
            for pair in level where state.free(pair) {
                state.claim(pair)
                proven[pair.item] = pair.playlist
            }
        }
        // 4. The name alone: the playlist's name is this item's only (no other item, anyone's, carries it), the songs
        //    don't say otherwise, and of the item's playlists left, the one plainest named. For this read only.
        var plainest: [Pair] = []
        let named = index.ranks.filter { (index.byPlaylist[$0.key.playlist]?.count ?? 0) == 1 && state.free($0.key) }
        for pairs in Dictionary(grouping: named, by: \.key.item).values {
            guard let best = pairs.map(\.value.value).min() else { continue }
            let top = pairs.filter { $0.value.value == best }
            if top.count == 1, let only = top.first, !contradicted(only.key) { plainest.append(only.key) }
        }
        state.claimUnique(plainest)
        return Assignment(claims: state.claims, proven: proven)
    }

    /// Round 25 (owner, 2026-11-10): "There is one playlist with the same name in two separate users, and when I set
    /// it so that only playlists/flows specific to me are meant to show, this playlist does not show at all" (D251).
    /// The items, in the order given, that this read leaves unproven although a name they carry is shared: another
    /// item carries the name of one of their playlists, or more than one playlist carries theirs. A shared name is
    /// never claimed by name (step 4), so these need their own songs (`jobs/:id`): Aurral's general jobs list doesn't
    /// always hold them (it may not be readable, and 2.13 lists a playlist's songs taken from the Library as the
    /// Library's). An item whose name nothing else shares is settled by name as before, and needs no read.
    public static func unproven(aurralItems: [AurralFlow], playlists: [Playlist], jobs: [AurralJob], saved: [String: String],
                                entries: [String: [Song]], running: Set<String> = []) -> [String] {
        let proven = resolve(aurralItems: aurralItems, playlists: playlists, jobs: jobs, saved: saved, entries: entries,
                             running: running).proven
        let index = Index(items: aurralItems, playlists: playlists, jobs: [], entries: [:])
        let byItem = Dictionary(grouping: index.ranks.keys, by: \.item)
        var seen = Set<String>()
        return aurralItems.map(\.id).filter { id in
            guard proven[id] == nil, seen.insert(id).inserted, let pairs = byItem[id] else { return false }
            return pairs.count > 1 || pairs.contains { (index.byPlaylist[$0.playlist]?.count ?? 0) > 1 }
        }
    }

    /// D204's upgrade of the saved Discover ids (a set of playlist ids, no item): an id is kept only while exactly one
    /// Aurral item can claim it (by name), and that item only one of the ids. What comes out is a saved claim like any
    /// other, so `resolve` claims it only where nothing contradicts it and keeps it only where it isn't contradicted
    /// (fix round 1, I2).
    public static func migrate(oldIds: Set<String>, aurralItems: [AurralFlow], playlists: [Playlist]) -> [String: String] {
        let index = Index(items: aurralItems, playlists: playlists.filter { oldIds.contains($0.id) }, jobs: [], entries: [:])
        var byItem: [String: Set<String>] = [:]
        for (playlist, items) in index.byPlaylist where items.count == 1 {
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

    /// How a playlist's songs fit an item's jobs.
    struct Fit { var matched: Int; var count: Int; var passes: Bool { matched * 2 > count } }

    /// Fix round 1 (M1): every name folded once, the jobs grouped by item once, each song folded once.
    struct Index {
        /// Every (item, playlist) whose name relates them, with how closely.
        var ranks: [Pair: Rank] = [:]
        /// Each playlist's related items.
        var byPlaylist: [String: Set<String>] = [:]
        private var jobsByItem: [String: ItemJobs] = [:]
        private var songsByPlaylist: [String: [SongKey]] = [:]

        init(items: [AurralFlow], playlists: [Playlist], jobs: [AurralJob], entries: [String: [Song]],
             itemJobs: [String: [AurralJob]] = [:]) {
            // [folded name: [(item, rank)]], the first listed of a duplicated item id only.
            var names: [String: [(item: String, rank: Rank)]] = [:]
            var seen = Set<String>()
            for item in items where !item.id.isEmpty && seen.insert(item.id).inserted {
                let prefixes = DiscoverIdentity.prefixNames(of: item)
                for (position, name) in DiscoverRules.aurralNames(of: item).enumerated() {
                    names[name, default: []].append((item.id, Rank(prefixed: prefixes.contains(name), value: position)))
                }
            }
            var listed = Set<String>()
            for list in playlists where listed.insert(list.id).inserted {
                let folded = DiscoverRules.normalised(list.name)
                guard !folded.isEmpty else { continue }
                var found: [String: Rank] = [:]
                for hit in names[folded] ?? [] where found[hit.item].map({ hit.rank.value < $0.value }) ?? true {
                    found[hit.item] = hit.rank
                }
                if let base = DiscoverRules.withoutCopyNumber(folded) {
                    for hit in names[base] ?? [] where found[hit.item] == nil {   // with Aurral's copy number: after the names
                        found[hit.item] = Rank(prefixed: hit.rank.prefixed, value: 1000 + hit.rank.value)
                    }
                }
                for (item, rank) in found { ranks[Pair(item: item, playlist: list.id)] = rank }
                if !found.isEmpty {
                    byPlaylist[list.id] = Set(found.keys)
                    songsByPlaylist[list.id] = (entries[list.id] ?? []).map(SongKey.init)
                }
            }
            for job in jobs {
                guard let item = job.flowId else { continue }
                jobsByItem[item, default: ItemJobs()].add(job)
            }
            // Round 25 J (D251): an item's own list, read for it, is its songs (whatever item Aurral filed each under:
            // a Library reference is listed as the Library's in the general list). None read: the general list's stand.
            for (item, list) in itemJobs where !list.isEmpty {
                var own = ItemJobs()
                for job in list { own.add(job) }
                jobsByItem[item] = own
            }
        }

        /// The playlist's songs against the item's jobs; nil when there's nothing to go by (no songs read, or no jobs
        /// listed for the item).
        func fit(_ pair: Pair) -> Fit? {
            guard let songs = songsByPlaylist[pair.playlist], !songs.isEmpty, let jobs = jobsByItem[pair.item] else { return nil }
            return Fit(matched: songs.filter(jobs.matches).count, count: songs.count)
        }
    }

    /// A song folded once: `DiscoverRules.isFlowSong`'s rule without folding again per job.
    struct SongKey {
        var recording: MBID?
        var text: String
        var duration: TimeInterval
        init(_ song: Song) {
            recording = song.recordingMBID
            text = DiscoverRules.normalised(song.artist) + "\u{1F}" + DiscoverRules.normalised(song.title)
            duration = song.duration
        }
    }

    /// One item's jobs, by recording id and by folded artist + title.
    struct ItemJobs {
        var recordings = Set<MBID>()
        var byText: [String: [(hasRecording: Bool, duration: TimeInterval?)]] = [:]

        mutating func add(_ job: AurralJob) {
            if let track = job.trackMBID { recordings.insert(track) }
            let key = DiscoverRules.normalised(job.artistName) + "\u{1F}" + DiscoverRules.normalised(job.trackName)
            byText[key, default: []].append((job.trackMBID != nil, job.duration))
        }

        /// Same recording id; else, against a job the ids don't decide, same artist and title with the durations within
        /// 3 s when both are known.
        func matches(_ song: SongKey) -> Bool {
            if let recording = song.recording, recordings.contains(recording) { return true }
            return (byText[song.text] ?? []).contains { job in
                if song.recording != nil, job.hasRecording { return false }
                if let duration = job.duration, duration > 0, song.duration > 0 {
                    return abs(duration - song.duration) <= DiscoverRules.durationTolerance
                }
                return true
            }
        }
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
        private(set) var claims: [String: String] = [:]
        private var claimedPlaylists = Set<String>()
        var blockedItems = Set<String>()
        var blockedPlaylists = Set<String>()

        func free(_ pair: Pair) -> Bool {
            claims[pair.item] == nil && !claimedPlaylists.contains(pair.playlist)
                && !blockedItems.contains(pair.item) && !blockedPlaylists.contains(pair.playlist)
        }

        mutating func claim(_ pair: Pair) {
            claims[pair.item] = pair.playlist
            claimedPlaylists.insert(pair.playlist)
        }

        /// Claims each pair that is, among the free ones given, the only one for its item and for its playlist; returns
        /// the pairs claimed. One pass is enough (fix round 1, M4): a pair claimed had no rival, so claiming it changes
        /// no other pair's rivals.
        @discardableResult
        mutating func claimUnique(_ pairs: [Pair]) -> [Pair] {
            let open = pairs.filter(free)
            var items: [String: Int] = [:], playlists: [String: Int] = [:]
            for pair in Set(open) { items[pair.item, default: 0] += 1; playlists[pair.playlist, default: 0] += 1 }
            let unique = Set(open).filter { items[$0.item] == 1 && playlists[$0.playlist] == 1 }
            for pair in unique { claim(pair) }
            return Array(unique)
        }
    }
}
