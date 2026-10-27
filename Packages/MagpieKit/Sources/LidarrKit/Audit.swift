import Foundation

/// Read-only snapshot of how the owner's Lidarr is set up. `run` never throws: a section that fails to read
/// simply stays at its empty value, and `reachable` says whether `/system/status` answered.
public struct LidarrAudit: Sendable, Equatable {
    public var reachable: Bool
    /// `/system/status` answered 401/403: the saved API key no longer works (regenerated in Lidarr).
    public var keyRejected: Bool
    public var version: String
    public var authEnabled: Bool
    public var roots: [RootFolder]
    /// All four profiles `Provisioner` creates exist, by exact name.
    public var hasMagpieProfiles: Bool
    /// Tubifarry (or any Lidarr plugin) is installed (A15).
    public var tubifarry: Bool
    /// False means deleting from Lidarr is permanent (G3).
    public var recycleBinSet: Bool
    public var healthIssues: [HealthIssue]
    /// The `magpie-find` tag's id, found by name (read-only). A setup made before Finds mode lacks it.
    public var findTagId: Int?

    public init(reachable: Bool = false, keyRejected: Bool = false, version: String = "", authEnabled: Bool = false, roots: [RootFolder] = [],
                hasMagpieProfiles: Bool = false, tubifarry: Bool = false, recycleBinSet: Bool = false,
                healthIssues: [HealthIssue] = []) {
        self.reachable = reachable; self.keyRejected = keyRejected; self.version = version; self.authEnabled = authEnabled; self.roots = roots
        self.hasMagpieProfiles = hasMagpieProfiles; self.tubifarry = tubifarry; self.recycleBinSet = recycleBinSet
        self.healthIssues = healthIssues
    }

    public static func run(_ c: LidarrClient) async -> LidarrAudit {
        var audit = LidarrAudit()
        do {
            let status = try await c.status()
            audit.reachable = true
            audit.version = status.version
            audit.authEnabled = status.authenticationMethod.lowercased() != "none"
        } catch LidarrError.unauthorized {
            audit.keyRejected = true
        } catch {}
        audit.roots = (try? await c.rootFolders()) ?? []
        let quality = Set(((try? await c.qualityProfiles()) ?? []).map(\.name))
        let metadata = Set(((try? await c.metadataProfiles()) ?? []).map(\.name))
        audit.hasMagpieProfiles = quality.isSuperset(of: Provisioner.qualityProfileNames)
            && metadata.isSuperset(of: Provisioner.metadataProfileNames)
        let plugins = (try? await c.pluginTexts()) ?? nil
        audit.tubifarry = plugins?.contains { $0.contains("tubifarry") } ?? false
        audit.recycleBinSet = ((try? await c.recycleBin()) ?? nil) != nil
        audit.healthIssues = (try? await c.health()) ?? []
        // Lidarr stores tag labels lower-cased; the same label is the same tag (as in `Provisioner`).
        audit.findTagId = ((try? await c.tags()) ?? []).first { $0.label.lowercased() == Provisioner.findTag }?.id
        return audit
    }
}
