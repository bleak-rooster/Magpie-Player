import Foundation
import MagpieCore
import Testing
@testable import AurralKit

/// Round 22 R22A (owner, 2026-11-06): "when I have aurral connected, all of the playlists (flows) that are within
/// Aurral are kept separate from Magpie Playlists and rather exist in Discover only" (D181–D185).

private func flow(_ id: String, _ name: String, owner: String? = "admin") -> AurralFlow {
    AurralFlow(id: id, name: name, enabled: true, ownerUsername: owner)
}

private func playlist(_ id: String, _ name: String) -> Playlist {
    Playlist(id: id, name: name, songCount: 1, duration: 0, owner: "admin")
}

private func song(_ id: String, _ title: String, _ artist: String = "Low", library: Int? = nil) -> Song {
    Song(id: id, title: title, artist: artist, album: "A", duration: 200, libraryId: library)
}

@Suite struct AurralPlaylistNameTests {
    /// D181: every name Aurral gives a flow's or playlist's Navidrome playlist. Aurral 2.13 (`getPlaylistNames`):
    /// the name, "<owner> - <name>", and the older forms it still finds and renames ("[A] <name>", "Aurral <name>";
    /// "[AS] <name>", "Aurral Shared <name>" for a shared playlist). A playlist file Navidrome imports is named after
    /// the file, which Aurral writes with `<>:"/\|?*` as "_" (2.13's pending playlist, and every playlist since
    /// Aurral's playlist files), and a name taken twice gets " (2)", " (3)"….
    @Test func everyNameAurralGivesIt() {
        let flows = [flow("f1", "Rock/Pop: Mix"), flow("f2", "Chill", owner: "jordan")]
        let playlists = [
            playlist("p1", "[A] Rock/Pop: Mix"), playlist("p2", "Aurral Rock/Pop: Mix"),
            playlist("p3", "[AS] Chill"), playlist("p4", "Aurral Shared chill"),
            playlist("p5", "Rock_Pop_ Mix"), playlist("p6", "admin - Rock_Pop_ Mix"),
            playlist("p7", "Chill (2)"), playlist("p8", "jordan - Chill (3)"),
            playlist("p9", "Chill 2"), playlist("p10", "Chilled"), playlist("p11", "My Aurral Chill"),
            playlist("p12", "Chill (0)"), playlist("p13", "Chill ()"),
        ]
        let matched = DiscoverRules.flowPlaylists(flows: flows, playlists: playlists)
        #expect(matched.map(\.playlist.id) == ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8"])
        #expect(matched.map(\.flow.id) == ["f1", "f1", "f2", "f2", "f1", "f1", "f2", "f2"])
    }

    /// The flows listed first win a name two of them share (the user's own before anyone else's).
    @Test func theFirstFlowWinsASharedName() {
        let matched = DiscoverRules.flowPlaylists(flows: [flow("mine", "Weekly"), flow("sam", "Weekly", owner: "sam")],
                                                  playlists: [playlist("p1", "Weekly"), playlist("p2", "sam - Weekly")])
        #expect(matched.map(\.flow.id) == ["mine", "sam"])
    }
}

@Suite struct OwnersOwnTests {
    let jobs = [AurralJob(id: "j1", flowId: "f1", artistName: "Low", trackName: "Lullaby")]

    /// D182: a playlist named as Aurral's is the owner's own only on proof: its songs were read and there are some,
    /// Aurral's songs list was read this time, no run is under way, and not one song is the flow's, one of Aurral's
    /// copies or in Aurral's library.
    @Test func onlyOnProof() {
        let mine = [song("m1", "X", "Q", library: 1), song("m2", "Y", "Q", library: 1)]
        #expect(DiscoverRules.isOwnersOwn(songs: mine, flowJobs: jobs, jobsRead: true, runActive: false,
                                          aurralSongIds: [], aurralLibraries: [2]))
        // No proof: it's Aurral's.
        #expect(!DiscoverRules.isOwnersOwn(songs: [], flowJobs: jobs, jobsRead: true, runActive: false,
                                           aurralSongIds: [], aurralLibraries: []), "empty: newly made, nothing in yet")
        #expect(!DiscoverRules.isOwnersOwn(songs: nil, flowJobs: jobs, jobsRead: true, runActive: false,
                                           aurralSongIds: [], aurralLibraries: []), "its songs didn't read")
        #expect(!DiscoverRules.isOwnersOwn(songs: mine, flowJobs: jobs, jobsRead: false, runActive: false,
                                           aurralSongIds: [], aurralLibraries: []), "Aurral's songs didn't read")
        #expect(!DiscoverRules.isOwnersOwn(songs: mine, flowJobs: jobs, jobsRead: true, runActive: true,
                                           aurralSongIds: [], aurralLibraries: []), "a run under way clears the jobs")
        // One of Aurral's songs is enough: downloads still coming in leave most of a flow unmatched.
        let partly = mine + [song("a1", "Lullaby")]
        #expect(!DiscoverRules.isOwnersOwn(songs: partly, flowJobs: jobs, jobsRead: true, runActive: false,
                                           aurralSongIds: [], aurralLibraries: []), "the flow's song")
        let copy = mine + [song("a9", "Old")]
        #expect(!DiscoverRules.isOwnersOwn(songs: copy, flowJobs: jobs, jobsRead: true, runActive: false,
                                           aurralSongIds: ["a9"], aurralLibraries: []), "one of Aurral's copies")
        let filed = mine + [song("a8", "New", library: 2)]
        #expect(!DiscoverRules.isOwnersOwn(songs: filed, flowJobs: jobs, jobsRead: true, runActive: false,
                                           aurralSongIds: [], aurralLibraries: [2]), "in Aurral's library")
    }
}

@Suite struct OthersPlaylistsTests {
    /// D184: Aurral shows an admin every user's flows and playlists. Discover's own stay the user's (D72), and the
    /// others' are kept apart so their Navidrome playlists stay out of Playlists too. No user: none at all.
    @Test func scopedKeepsTheOthersApart() {
        var status = AurralStatus(flows: [AurralFlow(id: "f1", name: "Mine", ownerUserId: 1),
                                          AurralFlow(id: "f2", name: "Sam's", ownerUserId: 2)])
        status.sharedPlaylists = [AurralFlow(id: "s1", name: "Mine too", ownerUserId: 1),
                                  AurralFlow(id: "s2", name: "Sam's too", ownerUserId: 2)]
        let user = AurralUser(id: 1, username: "admin", role: "admin")
        let scoped = status.scoped(to: user)
        #expect(scoped.flows.map(\.id) == ["f1"] && scoped.sharedPlaylists.map(\.id) == ["s1"])
        #expect(scoped.othersPlaylists.map(\.id) == ["f2", "s2"])
        #expect(status.scoped(to: nil).othersPlaylists.isEmpty)
    }
}
