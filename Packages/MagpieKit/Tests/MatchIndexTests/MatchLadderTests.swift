import Foundation
import MagpieCore
import Testing
@testable import MatchIndex

private let rec1 = MBID("20a2961b-d8e8-481c-bd5b-abb38a2850ad")!
private let rec2 = MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d")!
private let artist1 = MBID("4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11")!

private func song(_ id: String, _ artist: String, _ title: String, _ d: TimeInterval = 200,
                  rec: MBID? = nil, artistMBID: MBID? = nil, isrcs: [String] = []) -> Song {
    Song(id: id, title: title, artist: artist, album: "Album", duration: d, recordingMBID: rec,
         artistMBID: artistMBID, isrcs: isrcs)
}

private func ext(_ artist: String, _ title: String, _ d: TimeInterval? = nil, rec: MBID? = nil,
                 artistMBID: MBID? = nil, isrcs: [String] = []) -> ExternalRecording {
    ExternalRecording(recordingMBID: rec, artistMBID: artistMBID, title: title, artist: artist,
                      duration: d, isrcs: isrcs, source: .listenBrainz)
}

@Suite struct MatchLadderTests {
    @Test func mbidWins() throws {
        // A name match exists for another song, but the recording MBID decides.
        let index = MatchIndex(songs: [song("byName", "Judie Tzuke", "Harbour Lights"),
                                       song("byMBID", "Someone Else", "Other Title", rec: rec2)])
        let m = try #require(index.match(ext("Judie Tzuke", "Harbour Lights", 200, rec: rec2)))
        #expect(m.songId == "byMBID")
        #expect(m.confidence == 1.0)
    }

    @Test func isrcSecond() throws {
        let index = MatchIndex(songs: [song("s1", "Aurora Field", "First Light", rec: rec1, isrcs: ["GBXYZ1900001"])])
        // Different recording MBID (another release's recording), shared ISRC (case-insensitive).
        let m = try #require(index.match(ext("Aurora Field", "Something Else", rec: rec2, isrcs: ["gbxyz1900001"])))
        #expect(m.songId == "s1")
        #expect(m.confidence == 0.95)
    }

    @Test func artistMBIDAndTitleWithinThreeSeconds() throws {
        let index = MatchIndex(songs: [song("s1", "Aurora Field", "First Light", 200, artistMBID: artist1)])
        // Credited differently, same artist MBID.
        let m = try #require(index.match(ext("A. Field", "First Light", 202, artistMBID: artist1)))
        #expect(m.confidence == 0.9)
    }

    @Test func unicodeAndNoMBID() throws {
        // "Beyoncé – Halo" in the library vs "Beyonce - Halo (Remastered)" from outside, 2 s apart.
        let index = MatchIndex(songs: [song("halo", "Beyoncé", "Halo", 261),
                                       song("cjk", "真梨邑ケイ", "ハーバー・ライト", 180)])
        let m = try #require(index.match(ext("Beyonce", "Halo (Remastered)", 263)))
        #expect(m.songId == "halo")
        #expect(m.confidence >= MatchIndex.acceptThreshold)

        // CJK: the key keeps the characters, so an exact name matches and a different one doesn't.
        let cjk = try #require(index.match(ext("真梨邑ケイ", "ハーバー・ライト", 181)))
        #expect(cjk.songId == "cjk")
        #expect(cjk.confidence >= MatchIndex.acceptThreshold)
        #expect(index.match(ext("真梨邑ケイ", "ハーバー", 180)) == nil)
    }

    @Test func durationGuard() {
        let index = MatchIndex(songs: [song("halo", "Beyoncé", "Halo", 261)])
        // Same name, 10 s apart: a different recording (live, edit), never merged.
        #expect(index.match(ext("Beyonce", "Halo", 271)) == nil)
        #expect(index.librarySong(for: ext("Beyonce", "Halo", 271)) == nil)
    }

    @Test func nameOnlyIsLowConfidenceAndMergesOnlyWhenUnambiguous() throws {
        let one = MatchIndex(songs: [song("halo", "Beyoncé", "Halo", 261)])
        let m = try #require(one.match(ext("Beyonce", "Halo")))   // LB search has no duration
        #expect(m.confidence == 0.6)
        #expect(one.librarySong(for: ext("Beyonce", "Halo")) == "halo")

        let two = MatchIndex(songs: [song("a", "Beyoncé", "Halo", 261), song("b", "Beyonce", "Halo", 300)])
        #expect(two.librarySong(for: ext("Beyonce", "Halo")) == nil, "two candidates: not sure which")
    }

    @Test func noMatch() {
        let index = MatchIndex(songs: [song("s", "Corin Hale", "Harbour Lights")])
        #expect(index.match(ext("Corin Hale", "Night Ferry", 200)) == nil)
        #expect(MatchIndex.empty.match(ext("Corin Hale", "Harbour Lights")) == nil)
    }

    @Test func artistsAndAlbums() {
        let index = MatchIndex(songs: [Song(id: "1", title: "T", artist: "Sigur Rós", album: "Takk...", duration: 1,
                                            artistMBID: artist1)])
        #expect(index.hasArtist(name: "sigur ros", mbid: nil))
        #expect(index.hasArtist(name: "Different Credit", mbid: artist1))
        #expect(!index.hasArtist(name: "Corin Hale", mbid: nil))
        #expect(index.hasAlbum(title: "takk", artist: "SIGUR RÓS"))
        #expect(!index.hasAlbum(title: "Kveikur", artist: "Sigur Rós"))
    }

    @Test func codableRoundTripKeepsLookups() throws {
        let index = MatchIndex(songs: [song("s1", "Aurora Field", "First Light", rec: rec1, isrcs: ["GBXYZ1900001"])])
        let back = try JSONDecoder().decode(MatchIndex.self, from: JSONEncoder().encode(index))
        #expect(back.count == 1)
        #expect(back.match(ext("x", "y", rec: rec1))?.songId == "s1")
        #expect(back.match(ext("Aurora Field", "First Light", 201))?.confidence == 0.8)
    }
}

@Suite struct NormalizeTests {
    @Test func foldsCaseAccentsPunctuationAndSpaces() {
        #expect(Normalize.name("  Beyoncé ") == "beyonce")
        #expect(Normalize.name("Don't   Stop—Me Now!") == "don t stop me now")
        #expect(Normalize.name("ＡＢＣ") == "abc", "full-width folds")
    }

    @Test func stripsAsidesAndFeat() {
        #expect(Normalize.name("Halo (Remastered 2011)") == "halo")
        #expect(Normalize.name("Halo [Live] (feat. X)") == "halo")
        #expect(Normalize.name("Halo - Remastered 2011") == "halo")
        #expect(Normalize.name("Halo - Live") == "halo live", "a live take is another recording")
        #expect(Normalize.name("Crazy in Love feat. Jay-Z") == "crazy in love")
        #expect(Normalize.name("Beyoncé ft. Jay-Z") == "beyonce")
        #expect(Normalize.name("Featuring Ghosts") == "featuring ghosts", "a name that starts with the word keeps it")
    }

    @Test func keepsCJKAndAsideOnlyNames() {
        #expect(Normalize.name("ハーバー・ライト") == "ハーバー ライト")
        #expect(Normalize.name("夜に駆ける") == "夜に駆ける")
        #expect(Normalize.name("(untitled)") == "untitled")
        #expect(Normalize.key(artist: "A", title: "B") != Normalize.key(artist: "A B", title: ""))
    }
}
