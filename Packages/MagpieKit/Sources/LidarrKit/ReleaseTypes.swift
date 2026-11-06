import Foundation

/// R18: which of an artist's releases a whole-artist download brings in, with Studio, Soundtrack and Live as toggles.
/// Official releases only, always (not a choice). Round 22 (owner, 2026-11-06, D175): Albums, EPs and Singles are three
/// independent switches (at least one on), not R18's ladder (Albums; Albums + EPs; Albums + EPs + Singles), which
/// `Kinds` still names for choices saved and profiles made before.
///
/// Lidarr filters an artist's releases with a metadata profile, so each choice is a Magpie metadata profile named
/// `Magpie <Types> · <Secondary>` (`profileName`), provisioned on demand (`Provisioner.ensureReleaseTypes`).
/// Lidarr's "Studio" secondary type is a release with no secondary type; a profile must allow at least one, so
/// with every toggle off it is Studio.
public struct ReleaseTypes: Codable, Hashable, Sendable {
    /// R18's three choices (saved choices from before round 22 still use them).
    public enum Kinds: String, Codable, CaseIterable, Sendable {
        case albums
        case albumsAndEPs
        case albumsEPsAndSingles
    }

    public var albums: Bool
    public var eps: Bool
    public var singles: Bool
    public var studio: Bool
    public var soundtrack: Bool
    public var live: Bool

    public init(albums: Bool = true, eps: Bool = true, singles: Bool = false, studio: Bool = true,
                soundtrack: Bool = false, live: Bool = false) {
        self.albums = albums; self.eps = eps; self.singles = singles
        self.studio = studio; self.soundtrack = soundtrack; self.live = live
    }

    public init(kinds: Kinds, studio: Bool = true, soundtrack: Bool = false, live: Bool = false) {
        self.init(albums: true, eps: kinds != .albums, singles: kinds == .albumsEPsAndSingles,
                  studio: studio, soundtrack: soundtrack, live: live)
    }

    /// The owner default: Albums + EPs, Studio.
    public static let standard = ReleaseTypes()

    /// The R18 ladder choice these are, if they are one.
    public var kinds: Kinds? {
        switch (albums, eps, singles) {
        case (true, false, false): .albums
        case (true, true, false): .albumsAndEPs
        case (true, true, true): .albumsEPsAndSingles
        default: nil
        }
    }

    /// At least one of Albums, EPs and Singles is on (a profile with none would list nothing).
    public var hasKind: Bool { albums || eps || singles }

    private enum CodingKeys: String, CodingKey { case kinds, albums, eps, singles, studio, soundtrack, live }

    /// Missing fields read as the defaults; R18's `kinds` reads as its switches; nothing chosen reads as the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.standard
        func bool(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? fallback
        }
        studio = bool(.studio, d.studio); soundtrack = bool(.soundtrack, d.soundtrack); live = bool(.live, d.live)
        if let ladder = (try? c.decodeIfPresent(Kinds.self, forKey: .kinds)) ?? nil {
            let t = ReleaseTypes(kinds: ladder)
            albums = t.albums; eps = t.eps; singles = t.singles
        } else {
            albums = bool(.albums, d.albums); eps = bool(.eps, d.eps); singles = bool(.singles, d.singles)
        }
        if !hasKind { albums = d.albums; eps = d.eps; singles = d.singles }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(albums, forKey: .albums); try c.encode(eps, forKey: .eps); try c.encode(singles, forKey: .singles)
        try c.encode(studio, forKey: .studio); try c.encode(soundtrack, forKey: .soundtrack); try c.encode(live, forKey: .live)
    }

    /// Lidarr's primary album type names this allows.
    public var primaryNames: [String] {
        [("Album", albums), ("EP", eps), ("Single", singles)].filter(\.1).map(\.0)
    }

    /// Lidarr's secondary album type names this allows, in a fixed order; Studio when none is on.
    public var secondaryNames: [String] {
        let on = [("Studio", studio), ("Soundtrack", soundtrack), ("Live", live)].filter(\.1).map(\.0)
        return on.isEmpty ? ["Studio"] : on
    }

    /// Release statuses: Official only.
    public static let statuses: Set<String> = ["Official"]

    /// `Magpie Albums+EPs · Studio+Live` (R18's names for its three choices, so profiles made before are reused;
    /// `Magpie Singles · Studio`, `Magpie Albums+Singles · …` for the others, D175).
    public var profileName: String {
        let kinds = [("Albums", albums), ("EPs", eps), ("Singles", singles)].filter(\.1).map(\.0).joined(separator: "+")
        return "Magpie \(kinds) \u{00B7} \(secondaryNames.joined(separator: "+"))"
    }

    /// Every choice there is (the 7 sets of Albums / EPs / Singles × the Studio / Soundtrack / Live toggles).
    public static var all: [ReleaseTypes] {
        (1..<8).flatMap { k in
            (0..<8).map { bits in
                ReleaseTypes(albums: k & 1 != 0, eps: k & 2 != 0, singles: k & 4 != 0,
                             studio: bits & 1 != 0, soundtrack: bits & 2 != 0, live: bits & 4 != 0)
            }
        }
    }

    /// A metadata profile name only Magpie makes: "Magpie Finds" or one `profileName` produces (review M1: never
    /// any `Magpie …` the owner may have named).
    public static func isMagpieMetadataProfile(_ name: String) -> Bool {
        name == Provisioner.findsMetadataName || all.contains { $0.profileName == name }
    }

    /// Round 15 C3 (re-review R2): these types widened so a release of `albumType` and `secondaryTypes` is listed (EP or
    /// Single added to the kinds, Studio / Live / Soundtrack switched on). Nil when it can't be expressed (another primary
    /// or secondary type): the add is refused before anything is sent.
    public func widened(toInclude albumType: String?, secondaryTypes: [String]) -> ReleaseTypes? {
        var t = self
        switch albumType?.lowercased() {
        // Round 22 (D175): only the release's own kind is added; the others stay as the owner chose.
        case "album": t.albums = true
        case "ep": t.eps = true
        case "single": t.singles = true
        default: return nil
        }
        for secondary in secondaryTypes.isEmpty ? ["studio"] : secondaryTypes.map({ $0.lowercased() }) {
            switch secondary {
            case "studio": t.studio = true
            case "live": t.live = true
            case "soundtrack": t.soundtrack = true
            default: return nil
            }
        }
        return t.includes(albumType: albumType, secondaryTypes: secondaryTypes) ? t : nil
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
