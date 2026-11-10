import Foundation
import MagpieCore
import Testing
@testable import AurralKit

/// Round 24 (owner, 2026-11-08): "Aurral playlists/flows that share a name across two users both appear even with
/// only-mine selected; tie them to users by identity, not by name" (D202–D204). Pure: no server, no network.

private func item(_ id: String, _ name: String, owner: Int, _ username: String) -> AurralFlow {
    AurralFlow(id: id, name: name, ownerUserId: owner, ownerUsername: username)
}

private func playlist(_ id: String, _ name: String) -> Playlist {
    Playlist(id: id, name: name, songCount: 2, duration: 0, owner: "aurral")
}

private func song(_ id: String, _ title: String) -> Song {
    Song(id: id, title: title, artist: "Low", album: "A", duration: 200)
}

private func job(_ flowId: String, _ title: String) -> AurralJob {
    AurralJob(id: "job-\(flowId)-\(title)", flowId: flowId, artistName: "Low", trackName: title, durationMs: 200_000)
}

/// Jordan's and Sam's flows, both "Chill", as Aurral shows an admin.
private let jordans = item("f-j", "Chill", owner: 1, "jordan")
private let sams = item("f-s", "Chill", owner: 2, "sam")

@Suite struct DiscoverIdentityTests {
    /// Prefix off: two same-named Navidrome playlists, told apart by whose songs they hold (Aurral's jobs per flow).
    @Test func identity_twoUsersSameName_prefixOff_assignedByContent() {
        let playlists = [playlist("p1", "Chill"), playlist("p2", "Chill")]
        let entries = ["p1": [song("s1", "Halo"), song("s2", "Words")], "p2": [song("s3", "Lullaby"), song("s4", "Old")]]
        let jobs = [job("f-j", "Lullaby"), job("f-j", "Old"), job("f-s", "Halo"), job("f-s", "Words")]
        let claims = DiscoverIdentity.assign(aurralItems: [jordans, sams], playlists: playlists, jobs: jobs, saved: [:],
                                             entries: entries)
        #expect(claims == ["f-j": "p2", "f-s": "p1"])
    }

    /// Prefix on: "<owner> - <name>" names that owner's item, ahead of saved ids and songs.
    @Test func identity_prefixOn_exactOwnerPrefixWins() {
        let playlists = [playlist("p1", "jordan - Chill"), playlist("p2", "sam - Chill")]
        // The songs say the opposite (and a saved id too): the owner's name in the playlist's wins.
        let entries = ["p1": [song("s1", "Halo")], "p2": [song("s3", "Lullaby")]]
        let jobs = [job("f-j", "Lullaby"), job("f-s", "Halo")]
        let claims = DiscoverIdentity.assign(aurralItems: [jordans, sams], playlists: playlists, jobs: jobs,
                                             saved: ["f-j": "p2"], entries: entries)
        #expect(claims == ["f-j": "p1", "f-s": "p2"])
        // A file-named form and a copy number Aurral adds keep the owner's name: still that owner's.
        let other = DiscoverIdentity.assign(aurralItems: [jordans, sams],
                                            playlists: [playlist("p3", "sam - Chill (2)"), playlist("p4", "jordan - Chill")],
                                            jobs: [], saved: [:], entries: [:])
        #expect(other == ["f-j": "p4", "f-s": "p3"])
    }

    /// Q1 ruling: two near-identical same-named items and playlists that the songs can't tell apart: neither is
    /// claimed (both stay Aurral's, owner unknown), never a guess.
    @Test func identity_tie_assignsNeither() {
        let playlists = [playlist("p1", "Chill"), playlist("p2", "Chill")]
        let same = [song("s1", "Halo"), song("s2", "Words")]
        let entries = ["p1": same, "p2": same.map { song($0.id + "b", $0.title) }]
        let jobs = [job("f-j", "Halo"), job("f-j", "Words"), job("f-s", "Halo"), job("f-s", "Words")]
        let claims = DiscoverIdentity.assign(aurralItems: [jordans, sams], playlists: playlists, jobs: jobs, saved: [:],
                                             entries: entries)
        #expect(claims.isEmpty, "\(claims)")
        // One playlist only, both items' songs equally: still neither.
        let one = DiscoverIdentity.assign(aurralItems: [jordans, sams], playlists: [playlists[0]], jobs: jobs, saved: [:],
                                          entries: entries)
        #expect(one.isEmpty, "\(one)")
    }

    /// One-to-one: an item claims at most one playlist and a playlist at most one item, whatever the evidence.
    @Test func identity_oneToOne_neverTwoItemsOnePlaylist() {
        let mix = item("f-m", "Mix", owner: 1, "jordan")
        let playlists = [playlist("p1", "Mix"), playlist("p2", "[A] Mix"), playlist("p3", "Chill")]
        let entries = ["p1": [song("s1", "Halo")], "p2": [song("s2", "Halo")], "p3": [song("s3", "Halo")]]
        let jobs = [job("f-m", "Halo"), job("f-j", "Halo"), job("f-s", "Halo")]
        // Saved ids that would put two items on one playlist are ignored for both.
        let claims = DiscoverIdentity.assign(aurralItems: [mix, jordans, sams], playlists: playlists, jobs: jobs,
                                             saved: ["f-j": "p3", "f-s": "p3"], entries: entries)
        #expect(Set(claims.values).count == claims.count, "a playlist claimed twice: \(claims)")
        #expect(claims["f-m"] == "p1", "of a flow's two names, its own name; the older one isn't claimed too")
        #expect(claims["f-j"] == nil && claims["f-s"] == nil, "\(claims)")
    }

    /// Name only, never across users: allowed only when no other Aurral item (anyone's) has the name.
    @Test func identity_nameOnlyNeverCrossesUsers() {
        let playlists = [playlist("p1", "Chill"), playlist("p2", "Focus")]
        let focus = item("f-f", "Focus", owner: 2, "sam")
        // No songs to go by (empty, or unread).
        let claims = DiscoverIdentity.assign(aurralItems: [jordans, sams, focus], playlists: playlists, jobs: [],
                                             saved: [:], entries: [:])
        #expect(claims == ["f-f": "p2"], "\(claims)")
        // Jordan alone (a user who isn't an admin sees only their own): two "Chill" playlists, songs unread: one item,
        // two playlists by name only, so neither.
        let alone = DiscoverIdentity.assign(aurralItems: [jordans], playlists: [playlist("p1", "Chill"), playlist("p2", "Chill")],
                                            jobs: [], saved: [:], entries: [:])
        #expect(alone.isEmpty, "\(alone)")
    }

    /// A saved claim holds while the playlist still carries the item's name and nothing stronger says otherwise.
    @Test func identity_savedClaimHoldsWhileNamed() {
        let playlists = [playlist("p1", "Chill"), playlist("p2", "Chill")]
        let claims = DiscoverIdentity.assign(aurralItems: [jordans, sams], playlists: playlists, jobs: [],
                                             saved: ["f-j": "p2", "f-s": "p1"], entries: [:])
        #expect(claims == ["f-j": "p2", "f-s": "p1"])
        let renamed = DiscoverIdentity.assign(aurralItems: [jordans, sams], playlists: [playlist("p2", "Evening")],
                                              jobs: [], saved: ["f-j": "p2"], entries: [:])
        #expect(renamed.isEmpty, "a playlist no longer named as the item isn't its")
    }

    /// D204's upgrade: the old per-account id set (no item) keeps an id only while exactly one Aurral item can claim
    /// it, and that item only one old id.
    @Test func savedIds_migrateKeepsOnlyUnambiguous() {
        let focus = item("f-f", "Focus", owner: 1, "jordan")
        let playlists = [playlist("p1", "Chill"), playlist("p2", "Chill"), playlist("p3", "Focus"),
                         playlist("p4", "jordan - Chill")]
        let migrated = DiscoverIdentity.migrate(oldIds: ["p1", "p2", "p3", "p4", "gone"], aurralItems: [jordans, sams, focus],
                                                playlists: playlists)
        #expect(migrated == ["f-f": "p3", "f-j": "p4"], "\(migrated)")
    }

    // MARK: - Fix round 1

    /// I2: a user who isn't an admin sees only their own items. Their "Chill" has jobs; the only "Chill" playlist holds
    /// another user's songs (read, and not the item's): no claim by name, and a claim saved for it isn't revived.
    @Test func nameOnly_contradictedBySongs_claimsNothing_andIsNotRevived() {
        let theirs = [playlist("p-sam", "Chill")]
        let entries = ["p-sam": [song("s1", "Halo"), song("s2", "Words")]]
        let jobs = [job("f-j", "Lullaby"), job("f-j", "Old")]
        let first = DiscoverIdentity.assign(aurralItems: [jordans], playlists: theirs, jobs: jobs, saved: [:], entries: entries)
        #expect(first.isEmpty, "\(first)")
        // The next read with a claim saved for it (as the first fix-less read saved, or a migrated round-23 id): still
        // nothing, as the songs contradict it.
        let revived = DiscoverIdentity.assign(aurralItems: [jordans], playlists: theirs, jobs: jobs,
                                              saved: ["f-j": "p-sam"], entries: entries)
        #expect(revived.isEmpty, "a saved claim the songs contradict isn't kept: \(revived)")
    }

    /// I2: with nothing to go by (songs unread), the name alone claims for this read only; while the item's run is
    /// under way its jobs aren't the playlist's songs yet (D75), so a saved claim holds and stays saved.
    @Test func nameOnly_lastsOneRead_savedHoldsDuringARun() {
        let theirs = [playlist("p-sam", "Chill")]
        let entries = ["p-sam": [song("s1", "Halo"), song("s2", "Words")]]
        let jobs = [job("f-j", "Lullaby"), job("f-j", "Old")]
        let unread = DiscoverIdentity.resolve(aurralItems: [jordans], playlists: theirs, jobs: jobs, saved: [:], entries: [:])
        #expect(unread.claims == ["f-j": "p-sam"] && unread.proven.isEmpty, "\(unread)")
        let running = DiscoverIdentity.resolve(aurralItems: [jordans], playlists: theirs, jobs: jobs,
                                               saved: ["f-j": "p-sam"], entries: entries, running: ["f-j"])
        #expect(running.claims == ["f-j": "p-sam"] && running.proven == ["f-j": "p-sam"], "\(running)")
    }

    /// I2: what is kept for the next read is proof only: the owner's prefix, the songs, a saved claim nothing
    /// contradicts; never the name alone.
    @Test func provenClaims_neverNameOnly() {
        let focus = item("f-f", "Focus", owner: 2, "sam")
        let playlists = [playlist("p1", "jordan - Chill"), playlist("p2", "Focus"), playlist("p3", "Chill")]
        let entries = ["p3": [song("s1", "Halo")]]
        let result = DiscoverIdentity.resolve(aurralItems: [jordans, sams, focus], playlists: playlists,
                                              jobs: [job("f-s", "Halo")], saved: [:], entries: entries)
        #expect(result.claims == ["f-j": "p1", "f-s": "p3", "f-f": "p2"], "\(result.claims)")
        #expect(result.proven == ["f-j": "p1", "f-s": "p3"], "\(result.proven)")
    }

    /// M5: the owner's prefix doesn't win over an item whose own plain name the playlist carries.
    @Test func prefix_yieldsToAPlainerName() {
        let literal = item("f-l", "jordan - Chill", owner: 2, "sam")
        let claims = DiscoverIdentity.assign(aurralItems: [jordans, literal], playlists: [playlist("p1", "jordan - Chill")],
                                             jobs: [], saved: [:], entries: [:])
        #expect(claims["f-j"] == nil, "\(claims)")
    }

    /// M3: the same answer whatever order Aurral and the server list things in.
    @Test func identity_isDeterministic() {
        let focus = item("f-f", "Focus", owner: 1, "jordan")
        let items = [jordans, sams, focus]
        let playlists = [playlist("p1", "Chill"), playlist("p2", "Chill"), playlist("p3", "Focus"),
                         playlist("p4", "[A] Focus"), playlist("p5", "sam - Chill")]
        let entries = ["p1": [song("s1", "Halo")], "p2": [song("s2", "Lullaby")]]
        let jobs = [job("f-j", "Halo"), job("f-s", "Lullaby"), job("f-f", "Words")]
        let expected = DiscoverIdentity.assign(aurralItems: items, playlists: playlists, jobs: jobs, saved: [:], entries: entries)
        #expect(!expected.isEmpty)
        var generator = SeededGenerator(seed: 24)
        for _ in 0..<20 {
            let again = DiscoverIdentity.assign(aurralItems: items.shuffled(using: &generator),
                                                playlists: playlists.shuffled(using: &generator),
                                                jobs: jobs.shuffled(using: &generator), saved: [:], entries: entries)
            #expect(again == expected)
        }
        #expect(DiscoverIdentity.assign(aurralItems: items.reversed(), playlists: playlists.reversed(), jobs: jobs.reversed(),
                                        saved: [:], entries: entries) == expected)
    }

    /// M3: migration's "that item only one of the ids": an item two old ids fit by name alone keeps neither.
    @Test func migrate_itemWithTwoOldIds_keepsNeither() {
        let migrated = DiscoverIdentity.migrate(oldIds: ["p1", "p2"], aurralItems: [jordans],
                                                playlists: [playlist("p1", "Chill"), playlist("p2", "[A] Chill")])
        #expect(migrated.isEmpty, "\(migrated)")
    }

    /// M1: 300 items, 300 playlists (20 songs each) and 5,000 jobs well inside a second.
    @Test func identity_scales() {
        let items = (0..<300).map { item("f-\($0)", "Mix \($0 % 100)", owner: $0 % 3, "user\($0 % 3)") }
        let playlists = (0..<300).map { playlist("p-\($0)", "Mix \($0 % 100)") }
        let jobs = (0..<5000).map { job("f-\($0 % 300)", "Song \($0)") }
        var entries: [String: [Song]] = [:]
        for p in 0..<300 { entries["p-\(p)"] = (0..<20).map { song("s-\(p)-\($0)", "Song \(p + 300 * $0)") } }
        let start = ContinuousClock.now
        _ = DiscoverIdentity.assign(aurralItems: items, playlists: playlists, jobs: jobs, saved: [:], entries: entries)
        let took = ContinuousClock.now - start
        #expect(took < .seconds(1), "\(took)")
    }

    // MARK: - Round 25 J (D251–D253)

    /// The owner's case: the general jobs list holds neither item's songs (unreadable, or Library references), so a
    /// shared name claims nothing (step 4 needs a name no other item carries); each item's own songs (`jobs/:id`)
    /// prove both, and the proof is saved.
    @Test func sameName_itemJobsProveBoth() {
        let playlists = [playlist("p1", "Chill"), playlist("p2", "Chill")]
        let entries = ["p1": [song("s1", "Halo"), song("s2", "Words")], "p2": [song("s3", "Lullaby"), song("s4", "Old")]]
        let none = DiscoverIdentity.resolve(aurralItems: [jordans, sams], playlists: playlists, jobs: [], saved: [:],
                                            entries: entries)
        #expect(none.claims.isEmpty, "\(none.claims)")
        let itemJobs = ["f-j": [job("library", "Lullaby"), job("library", "Old")], "f-s": [job("f-s", "Halo"), job("f-s", "Words")]]
        let proven = DiscoverIdentity.resolve(aurralItems: [jordans, sams], playlists: playlists, jobs: [], saved: [:],
                                              entries: entries, itemJobs: itemJobs)
        #expect(proven.claims == ["f-j": "p2", "f-s": "p1"])
        #expect(proven.proven == proven.claims)
    }

    /// Only the items a shared name leaves unproven need their own songs read: not one whose name no other item or
    /// playlist shares (step 4 settles it), and none once the general list proved them.
    @Test func unproven_onlySharedNamesNotYetProven() {
        let mix = item("f-m", "Mix", owner: 1, "jordan")
        let playlists = [playlist("p1", "Chill"), playlist("p2", "Chill"), playlist("p3", "Mix")]
        let entries = ["p1": [song("s1", "Halo")], "p2": [song("s3", "Lullaby")], "p3": [song("s5", "Words")]]
        #expect(DiscoverIdentity.unproven(aurralItems: [jordans, mix, sams], playlists: playlists, jobs: [], saved: [:],
                                          entries: entries) == ["f-j", "f-s"])
        let jobs = [job("f-j", "Lullaby"), job("f-s", "Halo")]
        #expect(DiscoverIdentity.unproven(aurralItems: [jordans, mix, sams], playlists: playlists, jobs: jobs, saved: [:],
                                          entries: entries).isEmpty)
        // A saved claim the songs don't contradict is proof already.
        #expect(DiscoverIdentity.unproven(aurralItems: [jordans, sams], playlists: playlists, jobs: [],
                                          saved: ["f-j": "p2", "f-s": "p1"], entries: entries).isEmpty)
    }

    /// Not an admin: Aurral lists only the user's item, but the server holds Sam's same-named playlist too. The user's
    /// item needs its songs; with them it claims its own playlist and Sam's stays unclaimed (no owner known).
    @Test func notAdmin_sameNamePlaylistOfAnUnlistedUser() {
        let playlists = [playlist("p1", "Chill"), playlist("p2", "Chill")]
        let entries = ["p1": [song("s1", "Halo")], "p2": [song("s3", "Lullaby")]]
        #expect(DiscoverIdentity.unproven(aurralItems: [jordans], playlists: playlists, jobs: [], saved: [:],
                                          entries: entries) == ["f-j"])
        let claims = DiscoverIdentity.assign(aurralItems: [jordans], playlists: playlists, jobs: [], saved: [:],
                                             entries: entries, itemJobs: ["f-j": [job("f-j", "Lullaby")]])
        #expect(claims == ["f-j": "p2"])
    }

    /// Never a wrong owner: an item's own songs that fit both playlists (a tie) claim neither, and its own songs that
    /// fit neither playlist keep even a name no other item carries from being claimed.
    @Test func itemJobs_tieOrContradiction_claimsNothing() {
        let playlists = [playlist("p1", "Chill"), playlist("p2", "Chill")]
        let same = [song("s1", "Halo")]
        let tie = DiscoverIdentity.assign(aurralItems: [jordans, sams], playlists: playlists, jobs: [], saved: [:],
                                          entries: ["p1": same, "p2": same],
                                          itemJobs: ["f-j": [job("f-j", "Halo")], "f-s": [job("f-s", "Halo")]])
        #expect(tie.isEmpty, "\(tie)")
        let mix = item("f-m", "Mix", owner: 1, "jordan")
        let wrong = DiscoverIdentity.assign(aurralItems: [mix], playlists: [playlist("p3", "Mix")], jobs: [], saved: [:],
                                            entries: ["p3": [song("s5", "Words")]], itemJobs: ["f-m": [job("f-m", "Halo")]])
        #expect(wrong.isEmpty, "\(wrong)")
    }
}

/// A small seeded generator, so a shuffle is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
