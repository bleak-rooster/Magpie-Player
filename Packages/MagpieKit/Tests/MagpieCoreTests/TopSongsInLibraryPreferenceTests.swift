import Foundation
import Testing
@testable import MagpieCore

/// Round 25 I (owner, 2026-11-10; D247): "In your library only, for artists in Lidarr" is on by default, and
/// preferences saved before it (no key) read as on; a stored off survives, and a bad value resets only itself.
@Suite struct TopSongsInLibraryPreferenceTests {
    @Test func onByDefault() {
        #expect(LayoutPreferences.defaultValue.topSongsInLibraryOnly == true)
        #expect(Preferences.standard.layout.topSongsInLibraryOnly == true)
    }

    @Test func olderPreferencesReadAsOn() {
        let old = Data(#"{"version":1,"showsRecentlyAdded":false,"artistTopSongs":"listenBrainz"}"#.utf8)
        let decoded = LayoutPreferences.decode(old)
        #expect(decoded.topSongsInLibraryOnly == true)
        #expect(decoded.showsRecentlyAdded == false && decoded.artistTopSongs == .listenBrainz, "nothing else resets")
    }

    @Test func offIsKeptAndABadValueResetsOnlyItself() {
        var p = LayoutPreferences.defaultValue
        p.topSongsInLibraryOnly = false
        p.artistTopSongs = .aurral
        let back = LayoutPreferences.decode(p.encoded())
        #expect(back.topSongsInLibraryOnly == false && back.artistTopSongs == .aurral)
        let odd = Data(#"{"version":1,"topSongsInLibraryOnly":"maybe","showsRecentlyAdded":false}"#.utf8)
        #expect(LayoutPreferences.decode(odd).topSongsInLibraryOnly == true)
        #expect(LayoutPreferences.decode(odd).showsRecentlyAdded == false)
    }
}
