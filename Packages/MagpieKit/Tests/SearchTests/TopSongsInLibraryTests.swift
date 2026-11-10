import Testing
@testable import Search

/// Round 25 I (owner, 2026-11-10; D248): an artist page's Top songs from Aurral or ListenBrainz keep only the songs in
/// the library when the setting is on, Lidarr is set up and Lidarr says the artist is monitored; anything else (off, not
/// in Lidarr, not known yet, no Lidarr, the library's own list) shows every song, as before.
@Suite struct TopSongsInLibraryTests {
    private struct Row: Equatable { var id: Int; var inLibrary: Bool }
    private let rows = [Row(id: 0, inLibrary: false), Row(id: 1, inLibrary: true), Row(id: 2, inLibrary: false),
                        Row(id: 3, inLibrary: true), Row(id: 4, inLibrary: true)]

    @Test func onForAMonitoredArtistFromAnOutsideSource() {
        for provider in [TopSongsProvider.aurral, .listenBrainz] {
            #expect(TopSongsInLibrary.applies(setting: true, lidarrSetUp: true, provider: provider, artistMonitored: true))
        }
    }

    @Test func everythingElseShowsAll() {
        for provider in [TopSongsProvider.aurral, .listenBrainz] {
            #expect(!TopSongsInLibrary.applies(setting: false, lidarrSetUp: true, provider: provider, artistMonitored: true),
                    "the setting off")
            #expect(!TopSongsInLibrary.applies(setting: true, lidarrSetUp: true, provider: provider, artistMonitored: false),
                    "not in Lidarr, or not monitored")
            #expect(!TopSongsInLibrary.applies(setting: true, lidarrSetUp: true, provider: provider, artistMonitored: nil),
                    "Lidarr not known yet, or its read failed")
            #expect(!TopSongsInLibrary.applies(setting: true, lidarrSetUp: false, provider: provider, artistMonitored: true),
                    "no Lidarr")
        }
        #expect(!TopSongsInLibrary.applies(setting: true, lidarrSetUp: true, provider: .library, artistMonitored: true),
                "the library's own list is unchanged")
    }

    @Test func keepsOnlyTheLibrarysSongsInTheirOrder() {
        let kept = TopSongsInLibrary.shown(rows, applies: true) { $0.inLibrary }
        #expect(kept.map(\.id) == [1, 3, 4])
        #expect(TopSongsInLibrary.shown(rows, applies: false) { $0.inLibrary } == rows)
        #expect(TopSongsInLibrary.shown([Row(id: 0, inLibrary: false)], applies: true) { $0.inLibrary }.isEmpty)
    }
}
