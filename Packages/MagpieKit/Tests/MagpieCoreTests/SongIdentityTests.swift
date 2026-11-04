import Foundation
import Testing
@testable import MagpieCore

/// Round 14 A3 (D100, D103, D104): the one rule for "the same song" outside the library (normalised title, artist and
/// duration within 3 s; never by name alone), and the Artist top songs setting.
@Suite struct SongIdentityTests {
    @Test func titlesFoldCaseAccentsPunctuationAndVersionNotes() {
        #expect(SongIdentity.titleKey("Harbour Lights") == SongIdentity.titleKey("harbour  lights"))
        #expect(SongIdentity.titleKey("Café") == SongIdentity.titleKey("CAFE"))
        #expect(SongIdentity.titleKey("Harbour Lights (feat. Someone)") == SongIdentity.titleKey("Harbour Lights"))
        #expect(SongIdentity.titleKey("Harbour Lights - Remastered 2011") == SongIdentity.titleKey("Harbour Lights"))
        #expect(SongIdentity.titleKey("Don't Stop") == SongIdentity.titleKey("Dont Stop"))
        #expect(SongIdentity.titleKey("Harbour Lights") != SongIdentity.titleKey("Harbour Light"))
        #expect(SongIdentity.titleKey("(Untitled)") == "untitled", "a title that is all brackets keeps its words")
    }

    @Test func durationsMustBothBeKnownAndWithinThreeSeconds() {
        #expect(SongIdentity.sameDuration(200, 203))
        #expect(SongIdentity.sameDuration(203, 200))
        #expect(!SongIdentity.sameDuration(200, 203.5))
        #expect(!SongIdentity.sameDuration(nil, 200), "never by name alone")
        #expect(!SongIdentity.sameDuration(200, nil))
        #expect(!SongIdentity.sameDuration(0, 0), "an unknown (zero) length is not a length")
        #expect(!SongIdentity.sameDuration(.nan, 200))
    }

    @Test func sameSongNeedsArtistTitleAndDuration() {
        #expect(SongIdentity.same(title: "Harbour Lights", artist: "The Tides", duration: 201,
                                  as: "harbour lights", artist: "the tides", duration: 199))
        #expect(!SongIdentity.same(title: "Harbour Lights", artist: "The Tides", duration: 201,
                                   as: "Harbour Lights", artist: "Other", duration: 201))
        #expect(!SongIdentity.same(title: "Harbour Lights", artist: "The Tides", duration: nil,
                                   as: "Harbour Lights", artist: "The Tides", duration: 201))
    }

    @Test func artistTopSongsDefaultsToAutomaticAndReadsOldPreferences() throws {
        #expect(LayoutPreferences.defaultValue.artistTopSongs == .automatic)
        // Saved before round 14 A3: no key, so Automatic.
        let old = Data(#"{"version":1,"showsRecentlyAdded":false}"#.utf8)
        let decoded = LayoutPreferences.decode(old)
        #expect(decoded.artistTopSongs == .automatic && decoded.showsRecentlyAdded == false)
        // A value from a later build reads as Automatic, and nothing else resets.
        let odd = Data(#"{"version":1,"artistTopSongs":"spotify","showsRecentlyAdded":false}"#.utf8)
        #expect(LayoutPreferences.decode(odd).artistTopSongs == .automatic)
        #expect(LayoutPreferences.decode(odd).showsRecentlyAdded == false)
        var p = LayoutPreferences.defaultValue
        p.artistTopSongs = .listenBrainz
        #expect(LayoutPreferences.decode(p.encoded()).artistTopSongs == .listenBrainz)
    }

    @Test func withoutAurralThePickerOffersThreeChoices() {
        #expect(ArtistTopSongsSource.choices(aurral: true) == [.automatic, .aurral, .listenBrainz, .library])
        #expect(ArtistTopSongsSource.choices(aurral: false) == [.automatic, .listenBrainz, .library])
    }
}
