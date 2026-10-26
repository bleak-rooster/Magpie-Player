import Foundation
import Requests

/// What setting up Magpie in Lidarr produced, and where fallback-mode requests go. Not secret, so it lives in
/// UserDefaults; tied to one Lidarr address so a different server starts over.
struct LidarrSetup: Codable, Equatable, Sendable {
    var base: URL
    /// From `Provisioner.ensure` ("Set up Magpie in Lidarr"); nil until it has succeeded.
    var fastStartProfileId: Int?
    var findsMetadataProfileId: Int?
    var magpieTagId: Int?
    /// The main root folder new music goes into (fallback mode). Picked by the owner when Lidarr has several;
    /// never guessed.
    var rootFolderPath: String?

    var isProvisioned: Bool { fastStartProfileId != nil && findsMetadataProfileId != nil && magpieTagId != nil }

    /// What the runner adds with, once provisioned and a root is chosen.
    var runnerSetup: RequestRunner.Setup? {
        guard let fastStartProfileId, let findsMetadataProfileId, let magpieTagId, let rootFolderPath else { return nil }
        return RequestRunner.Setup(rootFolderPath: rootFolderPath, qualityProfileId: fastStartProfileId,
                                   metadataProfileId: findsMetadataProfileId, tagIds: [magpieTagId])
    }
}

struct LidarrSetupStore {
    let defaults: UserDefaults
    private let key = "magpie.lidarr.setup"

    func load(for base: URL) -> LidarrSetup {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(LidarrSetup.self, from: data), saved.base == base else {
            return LidarrSetup(base: base)
        }
        return saved
    }

    func save(_ setup: LidarrSetup) {
        defaults.set(try? JSONEncoder().encode(setup), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}
