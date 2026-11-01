import Foundation
import Testing
@testable import MagpieCore

/// Round 11 R11: "Album artists only" is a Library layout preference, on by default, kept apart from the rest.
@Suite struct AlbumArtistsOnlyTests {
    @Test func onByDefaultAndForSettingsSavedBeforeIt() {
        #expect(LayoutPreferences.defaultValue.albumArtistsOnly)
        #expect(LayoutPreferences.decode(Data(#"{"showsRecentlyAdded":false}"#.utf8)).albumArtistsOnly,
                "a layout saved before round 11 reads as on")
    }

    @Test func offIsKeptAndABadValueFallsBackAlone() throws {
        var layout = LayoutPreferences.defaultValue
        layout.albumArtistsOnly = false
        let decoded = LayoutPreferences.decode(try #require(layout.encoded()))
        #expect(!decoded.albumArtistsOnly)
        let bad = LayoutPreferences.decode(Data(#"{"albumArtistsOnly":"maybe","showsRecentlyAdded":false}"#.utf8))
        #expect(bad.albumArtistsOnly && !bad.showsRecentlyAdded)
    }
}
