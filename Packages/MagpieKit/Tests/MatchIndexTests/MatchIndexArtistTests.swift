import Foundation
import MagpieCore
import Testing
@testable import MatchIndex

private let artist = MBID("4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11")!
private let other = MBID("9c9f1380-2516-4fc9-a3e6-f9f61941d090")!
private let rec = MBID("20a2961b-d8e8-481c-bd5b-abb38a2850ad")!

private func song(_ id: String, _ artistName: String, _ title: String, album: String = "First Light",
                  _ d: TimeInterval = 200, rec: MBID? = nil, artistMBID: MBID? = nil) -> Song {
    Song(id: id, title: title, artist: artistName, album: album, duration: d, recordingMBID: rec, artistMBID: artistMBID)
}

/// Round 26 K1 (owner, 2026-11-10): what the album step needs from the match index (D260): a recording's library song,
/// an artist's songs with their album, title and length, and whether a song id is still in the library (K2's saved list).
@Suite struct MatchIndexArtistTests {
    @Test func index_songIdByRecording() {
        let index = MatchIndex(songs: [song("a", "Aurora Field", "Song"), song("b", "Aurora Field", "Song", rec: rec)])
        #expect(index.songId(recording: rec) == "b")
        #expect(index.songId(recording: other) == nil)
        #expect(MatchIndex.empty.songId(recording: rec) == nil)
    }

    /// Fix round 1 (M5): the index doesn't keep a song's library, so the caller says which ids are Discover copies; a copy
    /// outside them wins, and a Discover copy is still the answer when it is the only one.
    @Test func index_songIdByRecordingPrefersOutsideDiscover() {
        let index = MatchIndex(songs: [song("flow", "Aurora Field", "Song", rec: rec), song("main", "Aurora Field", "Song", rec: rec)])
        #expect(index.songId(recording: rec) == "flow", "unchanged without a preference")
        #expect(index.songId(recording: rec, avoiding: { $0 == "flow" }) == "main")
        #expect(MatchIndex(songs: [song("flow", "Aurora Field", "Song", rec: rec)])
                    .songId(recording: rec, avoiding: { $0 == "flow" }) == "flow")
        #expect(index.songId(recording: other, avoiding: { _ in true }) == nil)
    }

    @Test func index_artistSongsByMBIDThenName() {
        let index = MatchIndex(songs: [
            song("tagged", "Aurora Field", "Tagged", 210, artistMBID: artist),
            song("credited", "A. Field", "Credited", album: "Second", 0, artistMBID: artist),
            song("untagged", "Aurora Field", "Untagged", 190),
            song("namesake", "Aurora Field", "Namesake", artistMBID: other),
            song("stranger", "Someone Else", "Stranger"),
        ])
        let byMBID = index.artistSongs(name: "Aurora Field", mbid: artist)
        #expect(Set(byMBID.map(\.id)) == ["tagged", "credited", "untagged"],
                "the MBID's songs, plus untagged songs by the same name; never a namesake tagged with another MBID")
        let tagged = byMBID.first { $0.id == "tagged" }
        #expect(tagged?.title == "tagged" && tagged?.album == "first light" && tagged?.duration == 210)
        #expect(byMBID.first { $0.id == "credited" }?.duration == nil, "an unknown length stays unknown")

        let byName = index.artistSongs(name: "aurora  FIELD", mbid: nil)
        #expect(Set(byName.map(\.id)) == ["tagged", "untagged", "namesake"], "no MBID: by the normalised name")
        #expect(index.artistSongs(name: "", mbid: nil).isEmpty)
        #expect(index.artistSongs(name: "Nobody", mbid: nil).isEmpty)
    }

    @Test func index_containsSongId() {
        let index = MatchIndex(songs: [song("a", "Aurora Field", "Song")])
        #expect(index.contains(songId: "a"))
        #expect(!index.contains(songId: "b"))
        #expect(!MatchIndex.empty.contains(songId: "a"))
    }
}
