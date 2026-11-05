import Foundation
import Requests

/// What setting up Magpie in Lidarr produced, and where fallback-mode requests go. Not secret, so it lives in
/// UserDefaults; tied to one Lidarr instance (address + API key, `LidarrClient.instanceScope`) so a different
/// server, or a new key at the same address, starts over (security M3).
struct LidarrSetup: Codable, Equatable, Sendable {
    var base: URL
    var scope: String
    /// From `Provisioner.ensure` ("Set up Magpie in Lidarr"); nil until it has succeeded.
    var fastStartProfileId: Int?
    var findsMetadataProfileId: Int?
    var magpieTagId: Int?
    /// The `magpie-find` tag (Finds mode, Task 6.2a). Nil for a setup made before it: Try stays in fallback
    /// mode until "Set up Magpie in Lidarr" runs again (it looks the tag up by name, A15).
    var findTagId: Int?
    /// "Magpie Lossless" (Task 6.2b): what Keep moves a find to. Nil for a setup made before Keep: saved by
    /// "Set up Magpie in Lidarr", or adopted when the audit finds the profile by name.
    var losslessProfileId: Int?
    /// The main root folder new music goes into (fallback mode). Picked by the owner when Lidarr has several;
    /// never guessed.
    var rootFolderPath: String?
    /// Round 15 C3 (D136): "Magpie Lossless Preferred", made on the first Add to library of a new artist. Nil until then.
    var losslessPreferredProfileId: Int?

    var isProvisioned: Bool { fastStartProfileId != nil && findsMetadataProfileId != nil && magpieTagId != nil }

    /// What the runner adds with in fallback mode, once provisioned and a root is chosen
    /// (`AppModel.runnerSetup` adds Finds mode).
    var runnerSetup: RequestRunner.Setup? {
        guard let fastStartProfileId, let findsMetadataProfileId, let magpieTagId, let rootFolderPath else { return nil }
        return RequestRunner.Setup(rootFolderPath: rootFolderPath, qualityProfileId: fastStartProfileId,
                                   metadataProfileId: findsMetadataProfileId, tagIds: [magpieTagId],
                                   libraryQualityProfileId: losslessPreferredProfileId)
    }
}

/// One saved setup per Lidarr instance (`magpie.lidarr.setup.<scope>`).
struct LidarrSetupStore {
    let defaults: UserDefaults
    /// Before security M3 the setup was keyed by address only; it is ignored and removed.
    private static let legacyKey = "magpie.lidarr.setup"

    private static func key(_ scope: String) -> String { "\(legacyKey).\(scope)" }

    func load(base: URL, scope: String) -> LidarrSetup {
        guard let data = defaults.data(forKey: Self.key(scope)),
              let saved = try? JSONDecoder().decode(LidarrSetup.self, from: data), saved.scope == scope else {
            return LidarrSetup(base: base, scope: scope)
        }
        return saved
    }

    func save(_ setup: LidarrSetup) {
        defaults.set(try? JSONEncoder().encode(setup), forKey: Self.key(setup.scope))
    }

    /// Forgets the setup of one Lidarr (disconnect, sign-out), and the unscoped one of older builds.
    func clear(scope: String) {
        defaults.removeObject(forKey: Self.key(scope))
        defaults.removeObject(forKey: Self.legacyKey)
    }
}
