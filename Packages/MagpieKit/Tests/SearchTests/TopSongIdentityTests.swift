import MagpieCore
import MatchIndex
import Testing
@testable import Search

/// Round 26 K1 (owner, 2026-11-10): "the same song" for the album step (D261). Housekeeping notes fold (featuring, a
/// remaster, explicit/clean, album/single/LP/mono/stereo version, radio edit/version, edit, single edit, radio mix,
/// original mix/version, 7"/12" version); any other note keeps the titles apart. `SongIdentity` (Try, D104a M6) is
/// unchanged.
@Suite struct TopSongIdentityTests {
    private func same(_ a: String, _ b: String = "Song") -> Bool {
        let key = TopSongIdentity.titleKey(a)
        return !key.isEmpty && key == TopSongIdentity.titleKey(b)
    }

    @Test func identity_radioEditIsTheSameSong() {
        for title in ["Song (Radio Edit)", "Song - Radio Edit", "Song [Radio Edit]", "Song (Edit)", "Song (Single Edit)",
                      "Song (Radio Mix)", "Song (Radio Version)", "Song - Edit Version", "SONG (radio edit)"] {
            #expect(same(title), "\(title)")
        }
    }

    @Test func identity_singleAndAlbumVersionAreTheSameSong() {
        for title in ["Song (Single Version)", "Song - Album Version", "Song (LP Version)", "Song (Mono Version)",
                      "Song (Stereo Version)", "Song (7\" Version)", "Song (12\" Version)", "Song (Original Mix)",
                      "Song (Original Version)", "Song (Explicit Version)", "Song (Clean Version)"] {
            #expect(same(title), "\(title)")
        }
    }

    @Test func identity_featuringAndRemasterAreNoise() {
        for title in ["Song (feat. Sam)", "Song [ft. Sam]", "Song (featuring Sam & Alex)", "Song (with Sam)",
                      "Song feat. Sam", "Song - Remastered 2011", "Song (2011 Remaster)", "Song [Remastered]",
                      "Song (Remastered Version)", "Song [Explicit]", "Song (Clean)", "Song (feat. Sam) [Radio Edit]",
                      "Söng", "song", "  Song  "] {
            #expect(same(title), "\(title)")
        }
    }

    @Test func identity_liveRemixAcousticDemoInstrumentalNeverMatch() {
        for title in ["Song (Live)", "Song - Live at the Arena", "Song (Remix)", "Song (Sam Remix)", "Song (Acoustic)",
                      "Song - Acoustic Version", "Song (Demo)", "Song (Instrumental)", "Song (Unplugged)",
                      "Song (Karaoke Version)", "Song (Live / Remastered 2011)", "Song (Remastered Live)",
                      "Song (Club Mix)", "Song (Dub)"] {
            #expect(!same(title), "\(title)")
        }
        #expect(same("Song (Live)", "Song - Live"), "the same note on both sides still matches")
    }

    @Test func identity_repriseInterludeIntroOutroNeverMatch() {
        for title in ["Song (Reprise)", "Song - Reprise", "Song (Interlude)", "Song (Intro)", "Song (Outro)"] {
            #expect(!same(title), "\(title)")
            #expect(Normalize.name(title) == Normalize.name("Song") || title.contains("-"),
                    "the match index's name rule would equate these, which is why the album step has its own")
        }
    }

    @Test func identity_taylorsVersionAndYearMixStayApart() {
        for title in ["Song (Taylor's Version)", "Song (Taylor\u{2019}s Version)", "Song (2019 Mix)", "Song (Extended Mix)",
                      "Song (Extended)", "Song (Remastered 2019 Mix)", "Song (Orchestral Version)"] {
            #expect(!same(title), "\(title)")
        }
        #expect(same("Song (Taylor's Version)", "Song (Taylor\u{2019}s Version)"))
    }

    @Test func identity_tryRuleUnchanged() {
        #expect(SongIdentity.titleKey("Song (Radio Edit)") != SongIdentity.titleKey("Song"))
        #expect(TopSongIdentity.titleKey("Song (Radio Edit)") == TopSongIdentity.titleKey("Song"))
    }

    @Test func identity_emptyAndAllBracketTitles() {
        #expect(TopSongIdentity.titleKey("").isEmpty)
        #expect(TopSongIdentity.titleKey("  ()  ").isEmpty)
        #expect(TopSongIdentity.titleKey("(Untitled)") == "untitled")
        #expect(TopSongIdentity.titleKey("Untitled (Radio Edit)") == "untitled")
    }
}
