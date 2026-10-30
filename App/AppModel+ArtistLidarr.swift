import Foundation
import LidarrKit
import MagpieCore
import Requests

/// An artist page's Lidarr line (priority round P3): where the artist stands in the connected Lidarr, and its two
/// writes, through the same gate and ledger as the requests (G1; Magpie never changes an artist it didn't add).
extension AppModel {
    /// Lidarr's view of the artist; nil without a connected Lidarr. Never asked offline (`ArtistLidarrModel` checks).
    func artistLidarrState(name: String, mbid: MBID?) async throws -> ArtistLidarrState? {
        guard let client = lidarrClient, let ledger else { return nil }
        return try await ArtistLidarr.read(name: name, mbid: mbid, lidarr: client, ledger: ledger)
    }

    /// Magpie's profiles, tag and main root are ready (Settings › Requests › Set up Magpie in Lidarr, and a root).
    var canAddArtists: Bool { lidarrSetup?.runnerSetup != nil }

    /// "Add to Lidarr and download". Returns the artist's Lidarr id.
    func addArtistToLidarr(mbid: MBID) async throws -> Int {
        try requireNotForcedOffline()
        guard let client = lidarrClient, let gate, let ledger else { throw ArtistLidarrError.failed }
        guard let setup = lidarrSetup?.runnerSetup else { throw ArtistLidarrError.failed }
        return try await ArtistLidarr.add(mbid: mbid, lidarr: client, gate: gate, ledger: ledger, setup: setup)
    }

    /// "Monitor", for an unmonitored artist Magpie added.
    func monitorArtistInLidarr(id: Int) async throws {
        try requireNotForcedOffline()
        guard let client = lidarrClient, let gate, let ledger else { throw ArtistLidarrError.failed }
        try await ArtistLidarr.monitor(lidarrId: id, lidarr: client, gate: gate, ledger: ledger)
    }
}
