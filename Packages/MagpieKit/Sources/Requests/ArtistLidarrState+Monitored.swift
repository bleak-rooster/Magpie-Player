/// Round 25 I (owner, 2026-11-10; D249, controller ruling): whether an artist page's Lidarr state counts as "monitored in
/// Lidarr" for Top songs (`TopSongsInLibrary`). Lidarr's monitored artist does, and so does a find the owner kept
/// (`.find(_, .inLibrary)`: moved into the main library and monitored there; the page shows it as "In your library").
/// A find still on trial (in your Finds, being added, the old kept-in-place, a collision, needing attention), an
/// unmonitored artist, one Lidarr doesn't have and a name-only match do not. nil: Lidarr's answer isn't known.
extension ArtistLidarrState {
    public var countsAsMonitoredForTopSongs: Bool {
        switch self {
        case .monitored: true
        case .find(_, .inLibrary): true
        case .find, .notMonitored, .notInLidarr, .unmatched: false
        }
    }
}
