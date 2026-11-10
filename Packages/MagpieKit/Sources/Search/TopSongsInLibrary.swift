/// Round 25 I (owner, 2026-11-10; D248): "if an artist is monitored in Lidarr, then the top songs should ONLY include
/// songs that are currently in the library." An artist page's Top songs read from Aurral or ListenBrainz keep only the
/// rows the library has (the same matching that decides "in library" or "preview"), in their order, when the setting is
/// on, Lidarr is set up and Lidarr says the artist is monitored (a kept find counts too:
/// `ArtistLidarrState.countsAsMonitoredForTopSongs`, D249). Anything else shows every row, as before: the setting off,
/// an artist not in Lidarr (or not monitored, or a find on trial), Lidarr's answer not known yet or failed, no Lidarr,
/// and the library's own list (all of it is in the library anyway).
public enum TopSongsInLibrary {
    /// Whether the page keeps only the library's songs. `artistMonitored`: nil while Lidarr's answer isn't known (or
    /// its read failed), which shows everything.
    public static func applies(setting: Bool, lidarrSetUp: Bool, provider: TopSongsProvider, artistMonitored: Bool?) -> Bool {
        setting && lidarrSetUp && provider != .library && artistMonitored == true
    }

    /// The rows to show: the library's ones, in order, when `applies`; otherwise all of them.
    public static func shown<Row>(_ rows: [Row], applies: Bool, inLibrary: (Row) -> Bool) -> [Row] {
        applies ? rows.filter(inLibrary) : rows
    }
}
