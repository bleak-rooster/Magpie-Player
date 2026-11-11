import Foundation
import Testing
@testable import MagpieCore

/// Round 26 K1 (owner, 2026-11-10): round 25 I is reverted (D256). The Layout preferences have no "In your library only,
/// for artists in Lidarr" switch any more; a stored `topSongsInLibraryOnly` is ignored and dropped on the next save, with
/// nothing else reset (no migration).
@Suite struct LayoutPreferencesRevertTests {
    @Test func revert_settingsHasNoLibraryOnlySwitch() throws {
        let labels = Mirror(reflecting: LayoutPreferences.defaultValue).children.compactMap(\.label)
        #expect(!labels.contains("topSongsInLibraryOnly"), "the preference is gone")
        #expect(labels.contains("artistTopSongs"), "D104's picker stays")
        let data = try #require(LayoutPreferences.defaultValue.encoded())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["topSongsInLibraryOnly"] == nil)
    }

    @Test func storedLibraryOnlyKeyIsIgnored() throws {
        let stored = Data(#"{"version":1,"topSongsInLibraryOnly":false,"showsRecentlyAdded":false,"artistTopSongs":"listenBrainz"}"#.utf8)
        let decoded = LayoutPreferences.decode(stored)
        #expect(decoded.artistTopSongs == .listenBrainz && decoded.showsRecentlyAdded == false, "nothing else resets")
        let data = try #require(decoded.encoded())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["topSongsInLibraryOnly"] == nil, "dropped on the next save")
        #expect(object["artistTopSongs"] as? String == "listenBrainz")
    }
}
