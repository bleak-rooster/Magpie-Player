import MagpieCore
import Requests
import Search

/// Round 25 I (owner, 2026-11-10; D247–D250): the copy of "In your library only, for artists in Lidarr" (Settings ›
/// Home & Library › Artist top songs; the settings screen may name Lidarr) and of the artist page when it leaves none.
enum TopSongsInLibraryCopy {
    static let toggle = "In your library only, for artists in Lidarr"
    static let footer = "For an artist Lidarr looks after, show only the songs you already have. Off shows every top song, with previews for the ones you don\u{2019}t have."
    static let noneInLibrary = "None of their top songs are in your library yet."
    static let noneSymbol = "music.note.list"
}

extension AppModel {
    /// Round 25 I (D248): the Top songs an artist page shows. Read from Aurral or ListenBrainz, for an artist the page's
    /// Lidarr line says Lidarr monitors, with the setting on: only the rows the library has (the same matching that
    /// decides "in library" or "preview"), in order. Otherwise every row, as before. `lidarr` is the page's
    /// `ArtistLidarrModel.state`: nil while it isn't known (or its read failed), so the page shows everything first and
    /// keeps only the library's songs once Lidarr answers. A kept find counts as monitored; a find on trial, an
    /// unmonitored artist or one Lidarr doesn't have shows everything (D249, `countsAsMonitoredForTopSongs`). Nothing is
    /// read or written here.
    func shownTopSongs(_ result: TopSongsResult, lidarr state: ArtistLidarrState?) -> TopSongsResult {
        let monitored = state?.countsAsMonitoredForTopSongs
        let applies = TopSongsInLibrary.applies(setting: preferences.layout.topSongsInLibraryOnly, lidarrSetUp: lidarr != nil,
                                                provider: result.provider, artistMonitored: monitored)
        var shown = result
        shown.rows = TopSongsInLibrary.shown(result.rows, applies: applies) { $0.library != nil }
        return shown
    }
}
