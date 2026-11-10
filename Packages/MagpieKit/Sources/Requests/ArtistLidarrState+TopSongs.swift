/// Round 26 K1 (owner, 2026-11-10; Q1 answered 2026-11-11): whether an artist page's Lidarr state makes the artist one
/// "in Lidarr" for Top songs, and so gets the list of their top songs the library has (D257). Any artist Lidarr has,
/// monitored or not, qualifies, and so does a find the owner kept (`.inLibrary`: moved into the main library;
/// `.keptInFinds`: the old kept-in-place). A find still on trial (in your Finds, being added, a collision, needing
/// attention), an artist Lidarr doesn't have and a name-only match don't: their Top songs stay as D104 has them.
extension ArtistLidarrState {
    /// The Lidarr artist id whose albums and tracks the album step reads; nil when the artist doesn't qualify.
    public var topSongsLidarrArtistId: Int? {
        switch self {
        case .monitored(let id, _), .notMonitored(let id, _): id
        case .find(let id, .inLibrary), .find(let id, .keptInFinds): id
        case .find(_, .find), .find(_, .adding), .find(_, .collision), .find(_, .needsAttention): nil
        case .notInLidarr, .unmatched: nil
        }
    }
}
