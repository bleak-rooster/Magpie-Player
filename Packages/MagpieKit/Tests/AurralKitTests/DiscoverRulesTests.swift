import Foundation
import MagpieCore
import Testing
@testable import AurralKit

private func flow(_ id: String, _ name: String, owner: String? = "admin") -> AurralFlow {
    AurralFlow(id: id, name: name, enabled: true, ownerUsername: owner)
}

private func playlist(_ id: String, _ name: String, owner: String? = "admin") -> Playlist {
    Playlist(id: id, name: name, songCount: 10, duration: 0, owner: owner)
}

private let rec1 = MBID("0383dadf-2a4e-4d10-a46a-e9e041da8eb3")!
private let rec2 = MBID("1b0c5c1e-6f0a-4a37-9c8f-0c2f1e8b2f10")!

private func song(_ id: String, _ title: String, _ artist: String, _ duration: TimeInterval, mbid: MBID? = nil,
                  library: Int? = nil) -> Song {
    Song(id: id, title: title, artist: artist, album: "A", duration: duration, recordingMBID: mbid, libraryId: library)
}

@Suite struct FlowPlaylistMatchingTests {
    /// A Navidrome playlist is Discover's when its name is a flow's (trimmed, any case), or "<owner> - <flow>".
    @Test func matchesByFlowName() {
        let flows = [flow("f1", "Discover Weekly"), flow("f2", "Trending Mix")]
        let playlists = [playlist("p1", "Discover Weekly"), playlist("p2", "  trending mix "), playlist("p3", "Road trip"),
                         playlist("p4", "admin - Discover Weekly"), playlist("p5", "Discover Weekly 2"),
                         playlist("p6", "Discover")]
        let matched = DiscoverRules.flowPlaylists(flows: flows, playlists: playlists)
        #expect(matched.map(\.playlist.id) == ["p1", "p2", "p4"])
        #expect(matched.map(\.flow.id) == ["f1", "f2", "f1"])
    }

    @Test func noFlowsNoDiscover() {
        #expect(DiscoverRules.flowPlaylists(flows: [], playlists: [playlist("p1", "Discover Weekly")]).isEmpty)
        #expect(DiscoverRules.flowPlaylists(flows: [flow("f", "  ")], playlists: [playlist("p1", "")]).isEmpty,
                "a blank name matches nothing")
    }
}

@Suite struct DuplicateSwapTests {
    let entry = song("aurral-1", "Lullaby", "Low", 251, mbid: rec1, library: 2)

    /// By MusicBrainz recording id first: the main library's copy, whatever its title says.
    @Test func swapsByRecordingId() {
        let main = song("main-1", "Lullaby (Remastered)", "LOW", 400, mbid: rec1, library: 1)
        let other = song("main-9", "Other", "Low", 251, mbid: rec2, library: 1)
        #expect(DiscoverRules.mainCopy(for: entry, recording: rec1, mbidMatches: [other, main], textMatches: [],
                                       excluding: ["aurral-1"]) == main)
    }

    /// Else artist + title + duration within 3 s, exactly one such song.
    @Test func fallsBackToArtistTitleAndDuration() {
        let plain = song("aurral-2", "Words", "Low", 200)
        let main = song("main-2", "words", "Low ", 202.5, library: 1)
        #expect(DiscoverRules.mainCopy(for: plain, recording: nil, mbidMatches: [], textMatches: [main],
                                       excluding: ["aurral-2"]) == main)
        let tooLong = song("main-3", "Words", "Low", 204, library: 1)
        #expect(DiscoverRules.mainCopy(for: plain, recording: nil, mbidMatches: [], textMatches: [tooLong],
                                       excluding: []) == nil, "4 s apart")
        let twice = [main, song("main-4", "Words", "Low", 199, library: 1)]
        #expect(DiscoverRules.mainCopy(for: plain, recording: nil, mbidMatches: [], textMatches: twice,
                                       excluding: []) == nil, "two candidates: none taken")
    }

    /// Never by name alone: without a duration on either side nothing is swapped.
    @Test func neverByNameOnly() {
        let noDuration = song("aurral-3", "Words", "Low", 0)
        let main = song("main-2", "Words", "Low", 0, library: 1)
        #expect(DiscoverRules.mainCopy(for: noDuration, recording: nil, mbidMatches: [], textMatches: [main],
                                       excluding: []) == nil)
        let entry = song("aurral-4", "Words", "Low", 200)
        #expect(DiscoverRules.mainCopy(for: entry, recording: nil, mbidMatches: [],
                                       textMatches: [song("m", "Words", "Low", 0)], excluding: []) == nil)
        #expect(DiscoverRules.mainCopy(for: entry, recording: nil, mbidMatches: [],
                                       textMatches: [song("m", "Words", "Someone else", 200)], excluding: []) == nil)
    }

    /// The entry itself, and every other Discover copy, is never its own "library copy".
    @Test func neverItselfOrAnotherDiscoverCopy() {
        let same = song("aurral-1", "Lullaby", "Low", 251, mbid: rec1, library: 2)
        let otherFlow = song("aurral-7", "Lullaby", "Low", 251, mbid: rec1, library: 2)
        #expect(DiscoverRules.mainCopy(for: entry, recording: rec1, mbidMatches: [same, otherFlow], textMatches: [],
                                       excluding: ["aurral-1", "aurral-7"]) == nil)
    }

    /// The MBID's copy may only come from the libraries the owner lists (never Discover's, never Finds).
    @Test func onlyFromListedLibraries() {
        let finds = song("find-1", "Lullaby", "Low", 251, mbid: rec1, library: 3)
        let main = song("main-1", "Lullaby", "Low", 251, mbid: rec1, library: 1)
        #expect(DiscoverRules.mainCopy(for: entry, recording: rec1, mbidMatches: [finds, main], textMatches: [],
                                       excluding: [], libraries: [1]) == main)
        #expect(DiscoverRules.mainCopy(for: entry, recording: rec1, mbidMatches: [finds], textMatches: [],
                                       excluding: [], libraries: [1]) == nil)
        #expect(DiscoverRules.mainCopy(for: entry, recording: rec1, mbidMatches: [finds], textMatches: [],
                                       excluding: [], libraries: nil, notLibraries: [2, 3]) == nil)
    }

    /// Swapped in place: same position, "In your library"; every other entry untouched.
    @Test func swapKeepsPositions() {
        let a = song("a", "One", "X", 100), b = song("b", "Two", "Y", 100), c = song("c", "Three", "Z", 100)
        let mainB = song("main-b", "Two", "Y", 101, library: 1)
        let entries = DiscoverRules.swapped([a, b, c], copies: ["b": mainB])
        #expect(entries.map(\.song.id) == ["a", "main-b", "c"])
        #expect(entries.map(\.inYourLibrary) == [false, true, false])
        #expect(entries[1].original.id == "b")
    }
}

@Suite struct DiscoverLibraryTests {
    /// The library comes from Aurral's own files (a job whose path is in Aurral's flow folder), never from a name, and
    /// never a library the owner lists.
    @Test func libraryFromJobPaths() {
        let jobs = [AurralJob(id: "1", flowId: "f1", artistName: "Low", trackName: "Lullaby", trackMBID: rec1,
                              finalPath: "/data/downloads/aurral/_flows/f1/Low/Single/Lullaby.flac", status: "done"),
                    AurralJob(id: "2", flowId: "f1", artistName: "Low", trackName: "Words", trackMBID: rec2,
                              finalPath: "/music/Low/Album/Words.flac", status: "done")]
        let entries = [song("e1", "Lullaby", "Low", 251, mbid: rec1), song("e2", "Words", "Low", 200, mbid: rec2)]
        let rows: [String: [Song]] = [
            "e1": [song("e1", "Lullaby", "Low", 251, mbid: rec1, library: 2), song("m1", "Lullaby", "Low", 251, mbid: rec1, library: 1)],
            "e2": [song("e2", "Words", "Low", 200, mbid: rec2, library: 1)],
        ]
        #expect(DiscoverRules.discoverLibraries(entries: entries, rows: rows, jobs: jobs, listed: [1]) == [2])
        #expect(DiscoverRules.discoverLibraries(entries: entries, rows: rows, jobs: jobs, listed: [1, 2]) == [],
                "a library the owner lists is never Discover's")
        #expect(DiscoverRules.discoverLibraries(entries: entries, rows: rows, jobs: [], listed: [1]) == [],
                "no job paths: unknown")
    }
}

@Suite struct DiscoverArtistsTests {
    @Test func artistsInPlaylistFromJobs() {
        let jobs = [AurralJob(id: "1", flowId: "f1", artistName: "Low", trackName: "Lullaby",
                              artistMBID: MBID("4ad9b3a4-8a3a-4c7f-8b0f-6b7e6f2c0a11"), trackMBID: rec1, status: "done"),
                    AurralJob(id: "2", flowId: "f2", artistName: "Other", trackName: "X", status: "done")]
        let entries = [song("e1", "Lullaby", "Low", 251, mbid: rec1), song("e2", "Words", "Low", 200),
                       song("e3", "Song", "Nobody", 100)]
        let artists = DiscoverRules.artists(entries: entries, jobs: jobs, flowId: "f1")
        #expect(artists.map(\.name) == ["Low", "Nobody"])
        #expect(artists[0].mbid == MBID("4ad9b3a4-8a3a-4c7f-8b0f-6b7e6f2c0a11"))
        #expect(artists[1].mbid == nil)
        #expect(DiscoverRules.artistMBID(for: entries[1], jobs: jobs, flowId: "f1") == MBID("4ad9b3a4-8a3a-4c7f-8b0f-6b7e6f2c0a11"),
                "the artist's MBID by name within the flow")
    }
}
