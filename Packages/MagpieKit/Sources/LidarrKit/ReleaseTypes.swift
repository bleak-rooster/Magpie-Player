import Foundation

/// R18: which of an artist's releases a whole-artist download brings in. Albums, Albums + EPs, or Albums + EPs +
/// Singles, each with Studio, Soundtrack and Live as toggles. Official releases only, always (not a choice).
///
/// Lidarr filters an artist's releases with a metadata profile, so each choice is a Magpie metadata profile named
/// `Magpie <Types> · <Secondary>` (`profileName`), provisioned on demand (`Provisioner.ensureReleaseTypes`).
/// Lidarr's "Studio" secondary type is a release with no secondary type; a profile must allow at least one, so
/// with every toggle off it is Studio.
public struct ReleaseTypes: Codable, Hashable, Sendable {
    public enum Kinds: String, Codable, CaseIterable, Sendable {
        case albums
        case albumsAndEPs
        case albumsEPsAndSingles
    }

    public var kinds: Kinds
    public var studio: Bool
    public var soundtrack: Bool
    public var live: Bool

    public init(kinds: Kinds = .albumsAndEPs, studio: Bool = true, soundtrack: Bool = false, live: Bool = false) {
        self.kinds = kinds; self.studio = studio; self.soundtrack = soundtrack; self.live = live
    }

    /// The owner default: Albums + EPs, Studio.
    public static let standard = ReleaseTypes()

    /// Lidarr's primary album type names this allows.
    public var primaryNames: [String] {
        switch kinds {
        case .albums: ["Album"]
        case .albumsAndEPs: ["Album", "EP"]
        case .albumsEPsAndSingles: ["Album", "EP", "Single"]
        }
    }

    /// Lidarr's secondary album type names this allows, in a fixed order; Studio when none is on.
    public var secondaryNames: [String] {
        let on = [("Studio", studio), ("Soundtrack", soundtrack), ("Live", live)].filter(\.1).map(\.0)
        return on.isEmpty ? ["Studio"] : on
    }

    /// Release statuses: Official only.
    public static let statuses: Set<String> = ["Official"]

    /// `Magpie Albums+EPs · Studio+Live`.
    public var profileName: String {
        let kinds = switch kinds {
        case .albums: "Albums"
        case .albumsAndEPs: "Albums+EPs"
        case .albumsEPsAndSingles: "Albums+EPs+Singles"
        }
        return "Magpie \(kinds) \u{00B7} \(secondaryNames.joined(separator: "+"))"
    }

    /// Whether a release of this primary type and these secondary types is brought in (as Lidarr's metadata profile
    /// filters: the primary type allowed, and every secondary type allowed; none counts as Studio). Unknown primary
    /// type: not brought in.
    public func includes(albumType: String?, secondaryTypes: [String]) -> Bool {
        guard let type = albumType?.lowercased(), primaryNames.contains(where: { $0.lowercased() == type }) else {
            return false
        }
        let allowed = Set(secondaryNames.map { $0.lowercased() })
        let types = secondaryTypes.isEmpty ? ["studio"] : secondaryTypes.map { $0.lowercased() }
        return types.allSatisfy(allowed.contains)
    }
}

extension Provisioner {
    /// R18: the metadata profile for `types` (Official only), created through the gate only if no profile has its
    /// name. An existing one with that name is reused when its settings match; otherwise this stops with
    /// `ProvisionError.conflict` before anything is written (G5: nothing existing is ever modified).
    public func ensureReleaseTypes(_ types: ReleaseTypes, gate: LidarrWriteGate, client: LidarrClient) async throws -> Int {
        let spec = MetadataSpec(name: types.profileName, primary: Set(types.primaryNames),
                                secondary: Set(types.secondaryNames), statuses: ReleaseTypes.statuses)
        let existing = try await client.json("metadataprofile").arrayValue ?? []
        if let found = try Self.existing(named: spec.name, in: existing) {
            guard Self.matches(found, spec), let id = found["id"]?.intValue else { throw ProvisionError.conflict(spec.name) }
            return id
        }
        let schema = try await client.json("metadataprofile/schema")
        return try await Self.create(gate, "metadataprofile", try Self.metadataBody(spec, schema: schema), spec.name)
    }
}
