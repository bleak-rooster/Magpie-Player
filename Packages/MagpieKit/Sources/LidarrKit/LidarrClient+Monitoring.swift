import Foundation
import MagpieCore

/// Round 24 (owner, 2026-11-08, D237, D242): the reads "Change what's monitored" and "Clean up unmatched songs" need.
/// Reads only; every write goes through `LidarrWriteGate` (`performOwned`, `performCleanup`).
extension LidarrClient {
    /// Every track of the artist (`GET /track?artistId=`): which recording each file holds and its title, so songs the
    /// owner favourited or saved are left out of a delete.
    public func tracks(artistId: Int) async throws -> [LidarrTrack] {
        let data = try await ok("track", [URLQueryItem(name: "artistId", value: String(artistId))])
        do { return try JSONDecoder().decode(LossyArray<LidarrTrack>.self, from: data).values } catch {
            throw LidarrError.decoding
        }
    }
}
