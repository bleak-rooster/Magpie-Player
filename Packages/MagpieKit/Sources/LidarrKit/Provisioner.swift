import Foundation
import MagpieCore

public enum ProvisionError: Error, Sendable, Equatable {
    /// A profile with this name already exists with different settings. Nothing was changed (G5).
    case conflict(String)
    /// Lidarr's schema lacks a quality, album type or release status Magpie needs.
    case schemaMissing(String)
    /// Lidarr answered a create without a usable id.
    case unexpectedResponse(String)
}

public struct ProvisionResult: Sendable, Equatable {
    public var fastStartProfileId: Int
    public var losslessProfileId: Int
    public var findsMetadataProfileId: Int
    public var albumsEPsMetadataProfileId: Int
    public var magpieTagId: Int
    public var findTagId: Int
    /// Names of what this run created (empty when everything already existed).
    public var created: [String]
}

/// Creates Magpie's Lidarr profiles and tags if they are absent (A1, A15, G5). Existing ones are looked up
/// by exact name and reused when their settings match; a same-named profile with different settings stops
/// provisioning before anything is written. Nothing existing is ever modified.
public struct Provisioner: Sendable {
    public static let fastStartName = "Magpie Fast Start"
    public static let losslessName = "Magpie Lossless"
    public static let findsMetadataName = "Magpie Finds"
    public static let albumsEPsMetadataName = "Magpie Albums+EPs"
    public static let magpieTag = "magpie"
    public static let findTag = "magpie-find"

    public static let qualityProfileNames = [fastStartName, losslessName]
    public static let metadataProfileNames = [findsMetadataName, albumsEPsMetadataName]

    struct QualitySpec {
        var name: String
        var allowed: Set<String>
        var cutoff: String
        var upgradeAllowed: Bool
    }

    struct MetadataSpec {
        var name: String
        var primary: Set<String>
        var secondary: Set<String>
        var statuses: Set<String>
    }

    static let qualitySpecs = [
        QualitySpec(name: fastStartName, allowed: ["MP3-320", "MP3-VBR-V0"], cutoff: "MP3-320", upgradeAllowed: false),
        QualitySpec(name: losslessName, allowed: ["FLAC"], cutoff: "FLAC", upgradeAllowed: true),
    ]

    // "No secondary types" is Lidarr's "Studio" secondary type (a profile must allow at least one).
    static let metadataSpecs = [
        MetadataSpec(name: findsMetadataName, primary: ["Album", "EP", "Single"], secondary: ["Studio"],
                     statuses: ["Official"]),
        MetadataSpec(name: albumsEPsMetadataName, primary: ["Album", "EP"], secondary: ["Studio"],
                     statuses: ["Official"]),
    ]

    public init() {}

    // MARK: - Round 15 C3 (D146): the singles switch's profile, a superset of the artist's own

    /// "<the artist's profile> + Singles (Magpie)".
    public static let singlesSuffix = " + Singles (Magpie)"

    /// Whether a metadata profile already lists singles.
    public static func includesSingle(_ profile: JSONValue) -> Bool {
        allowedNames(profile["primaryAlbumTypes"], "albumType").contains("Single")
    }

    /// The spec of `profile` with Single added: the same primary types plus Single, the same secondary types and the same
    /// release statuses. Never narrower than the artist's own (C1).
    static func singlesSpec(of profile: JSONValue, name: String) -> MetadataSpec {
        MetadataSpec(name: name, primary: allowedNames(profile["primaryAlbumTypes"], "albumType").union(["Single"]),
                     secondary: allowedNames(profile["secondaryAlbumTypes"], "albumType"),
                     statuses: allowedNames(profile["releaseStatuses"], "releaseStatus"))
    }

    /// The id of "<current> + Singles (Magpie)" with exactly that superset spec: reused when Lidarr has it, otherwise made
    /// through the gate from the current profile itself (only Single switched on). A same-named profile set up
    /// differently is never changed: `ProvisionError.conflict`. No existing profile is ever modified.
    public func ensureSinglesSuperset(of current: JSONValue, gate: LidarrWriteGate, client: LidarrClient) async throws -> Int {
        guard let currentName = current["name"]?.stringValue else { throw ProvisionError.schemaMissing("metadataprofile name") }
        let name = currentName.hasSuffix(Self.singlesSuffix) ? currentName : currentName + Self.singlesSuffix
        let spec = Self.singlesSpec(of: current, name: name)
        let existing = try await client.metadataProfilesJSON()
        if let found = try Self.existing(named: name, in: existing) {
            guard Self.matches(found, spec), let id = found["id"]?.intValue else { throw ProvisionError.conflict(name) }
            return id
        }
        guard var body = current.objectValue, let primaries = current["primaryAlbumTypes"]?.arrayValue else {
            throw ProvisionError.schemaMissing("primaryAlbumTypes")
        }
        guard primaries.contains(where: { $0["albumType"]?["name"]?.stringValue == "Single" }) else {
            throw ProvisionError.schemaMissing("Single")
        }
        body["id"] = nil
        body["name"] = .string(name)
        body["primaryAlbumTypes"] = .array(primaries.map { entry in
            guard entry["albumType"]?["name"]?.stringValue == "Single", var o = entry.objectValue else { return entry }
            o["allowed"] = .bool(true)
            return .object(o)
        })
        return try await Self.create(gate, "metadataprofile", .object(body), name)
    }

    // MARK: - Round 15 C3 (owner answer 4, D136): the main library's quality

    public static let losslessPreferredName = "Magpie Lossless Preferred"
    /// FLAC first, MP3-320 / V0 only as a fallback; upgrades on until FLAC.
    static let losslessPreferredSpec = QualitySpec(name: losslessPreferredName, allowed: ["FLAC", "MP3-320", "MP3-VBR-V0"],
                                                   cutoff: "FLAC", upgradeAllowed: true)

    /// "Magpie Lossless Preferred"'s id, made through the gate if missing (on the first Add to library of a new artist).
    /// A same-named profile set up differently is never changed: `ProvisionError.conflict`.
    public func ensureLosslessPreferred(gate: LidarrWriteGate, client: LidarrClient) async throws -> Int {
        let spec = Self.losslessPreferredSpec
        let existing = try await client.json("qualityprofile").arrayValue ?? []
        if let found = try Self.existing(named: spec.name, in: existing) {
            guard Self.matches(found, spec), let id = found["id"]?.intValue else { throw ProvisionError.conflict(spec.name) }
            return id
        }
        let body = try Self.qualityBody(spec, schema: try await client.json("qualityprofile/schema"))
        return try await Self.create(gate, "qualityprofile", body, spec.name)
    }

    // MARK: - Round 17 (owner, 2026-11-05): a find that can't be found as an MP3

    public static let anyFormatName = "Magpie Finds Any Format"
    /// The qualities a find may come in once no MP3 was found: MP3 from 192 kbps, AAC, Ogg Vorbis from Q6, and lossless
    /// that plays on the phone (never WMA, APE or WavPack, nor anything below 192 kbps). Only those Lidarr lists count.
    static let anyFormatQualities: Set<String> = [
        "MP3-192", "MP3-224", "MP3-256", "MP3-VBR-V2", "MP3-VBR-V0", "MP3-320",
        "AAC-192", "AAC-256", "AAC-VBR", "AAC-320",
        "OGG Vorbis Q6", "OGG Vorbis Q7", "OGG Vorbis Q8", "OGG Vorbis Q9", "OGG Vorbis Q10",
        "FLAC", "ALAC", "FLAC 24bit", "ALAC 24bit", "WAV",
    ]
    /// Fast Start's MP3s stay the first choice (Lidarr prefers the last items): V0, then MP3-320 on top.
    static let anyFormatFirstChoice = ["MP3-VBR-V0", "MP3-320"]

    static func anyFormatSpec(schema: JSONValue) -> QualitySpec {
        QualitySpec(name: anyFormatName, allowed: anyFormatQualities.intersection(qualityNames(schema)), cutoff: "MP3-320",
                    upgradeAllowed: false)
    }

    /// Every quality name the schema lists, inside groups too.
    static func qualityNames(_ schema: JSONValue) -> Set<String> {
        var names = Set<String>()
        for item in schema["items"]?.arrayValue ?? [] {
            if let n = item["quality"]?["name"]?.stringValue { names.insert(n) }
            for child in item["items"]?.arrayValue ?? [] {
                if let n = child["quality"]?["name"]?.stringValue { names.insert(n) }
            }
        }
        return names
    }

    /// The profile's body: `qualityBody`, with the MP3s moved to the top of Lidarr's order.
    static func anyFormatBody(schema: JSONValue) throws -> JSONValue {
        let built = try qualityBody(anyFormatSpec(schema: schema), schema: schema)
        guard var body = built.objectValue, let items = built["items"]?.arrayValue else {
            throw ProvisionError.schemaMissing("qualityprofile items")
        }
        let name = { (item: JSONValue) in item["quality"]?["name"]?.stringValue ?? "" }
        let first = anyFormatFirstChoice.compactMap { n in items.first { name($0) == n } }
        body["items"] = .array(items.filter { !anyFormatFirstChoice.contains(name($0)) } + first)
        return .object(body)
    }

    /// "Magpie Finds Any Format"'s id, made through the gate if missing (the first find whose MP3 couldn't be found). A
    /// same-named profile set up differently is never changed: `ProvisionError.conflict`.
    /// Round 19: "Magpie Finds Extras", for a find whose song is only on a soundtrack or remix release (HUNTR/X "Golden",
    /// a film's song, a remix single): the Finds types (Album, EP, Single; Official) with Soundtrack and Remix beside Studio.
    public static let findsExtrasMetadataName = "Magpie Finds Extras"
    static let findsExtrasSpec = MetadataSpec(name: findsExtrasMetadataName, primary: ["Album", "EP", "Single"],
                                              secondary: ["Studio", "Soundtrack", "Remix"], statuses: ["Official"])

    /// The id of "Magpie Finds Extras": reused when Lidarr has it with exactly that spec, else made through the gate once.
    /// A same-named profile set up differently is never changed (`ProvisionError.conflict`).
    public func ensureFindsExtras(gate: LidarrWriteGate, client: LidarrClient) async throws -> Int {
        let spec = Self.findsExtrasSpec
        let existing = try await client.metadataProfilesJSON()
        if let found = try Self.existing(named: spec.name, in: existing) {
            guard Self.matches(found, spec), let id = found["id"]?.intValue else { throw ProvisionError.conflict(spec.name) }
            return id
        }
        let schema = try await client.json("metadataprofile/schema")
        return try await Self.create(gate, "metadataprofile", try Self.metadataBody(spec, schema: schema), spec.name)
    }

    public func ensureAnyFormat(gate: LidarrWriteGate, client: LidarrClient) async throws -> Int {
        let schema = try await client.json("qualityprofile/schema")
        let spec = Self.anyFormatSpec(schema: schema)
        let existing = try await client.json("qualityprofile").arrayValue ?? []
        if let found = try Self.existing(named: spec.name, in: existing) {
            guard Self.matches(found, spec), let id = found["id"]?.intValue else { throw ProvisionError.conflict(spec.name) }
            return id
        }
        return try await Self.create(gate, "qualityprofile", try Self.anyFormatBody(schema: schema), spec.name)
    }

    public func ensure(gate: LidarrWriteGate, client: LidarrClient) async throws -> ProvisionResult {
        // 1. Read everything and decide, so a conflict stops the run before any write.
        let existingQuality = try await client.json("qualityprofile").arrayValue ?? []
        let existingMetadata = try await client.json("metadataprofile").arrayValue ?? []
        let tags = try await client.tags()

        var qualityIds: [String: Int] = [:], metadataIds: [String: Int] = [:], tagIds: [String: Int] = [:]
        var qualityToCreate: [QualitySpec] = [], metadataToCreate: [MetadataSpec] = [], tagsToCreate: [String] = []

        for spec in Self.qualitySpecs {
            if let found = try Self.existing(named: spec.name, in: existingQuality) {
                guard Self.matches(found, spec) else { throw ProvisionError.conflict(spec.name) }
                qualityIds[spec.name] = found["id"]?.intValue
            } else {
                qualityToCreate.append(spec)
            }
        }
        for spec in Self.metadataSpecs {
            if let found = try Self.existing(named: spec.name, in: existingMetadata) {
                guard Self.matches(found, spec) else { throw ProvisionError.conflict(spec.name) }
                metadataIds[spec.name] = found["id"]?.intValue
            } else {
                metadataToCreate.append(spec)
            }
        }
        for label in [Self.magpieTag, Self.findTag] {
            // Lidarr stores tag labels lower-cased; the same label is the same tag.
            if let tag = tags.first(where: { $0.label.lowercased() == label }) { tagIds[label] = tag.id } else { tagsToCreate.append(label) }
        }

        // 2. Build every body from the schemas before the first write.
        var qualityBodies: [(String, JSONValue)] = []
        if !qualityToCreate.isEmpty {
            let schema = try await client.json("qualityprofile/schema")
            qualityBodies = try qualityToCreate.map { ($0.name, try Self.qualityBody($0, schema: schema)) }
        }
        var metadataBodies: [(String, JSONValue)] = []
        if !metadataToCreate.isEmpty {
            let schema = try await client.json("metadataprofile/schema")
            metadataBodies = try metadataToCreate.map { ($0.name, try Self.metadataBody($0, schema: schema)) }
        }

        // 3. Create what is missing, through the gate (throws `.disabled` before the first write when off).
        var created: [String] = []
        for (name, body) in qualityBodies {
            qualityIds[name] = try await Self.create(gate, "qualityprofile", body, name)
            created.append(name)
        }
        for (name, body) in metadataBodies {
            metadataIds[name] = try await Self.create(gate, "metadataprofile", body, name)
            created.append(name)
        }
        for label in tagsToCreate {
            tagIds[label] = try await Self.create(gate, "tag", .object(["label": .string(label)]), label)
            created.append(label)
        }

        func id(_ table: [String: Int], _ name: String) throws -> Int {
            guard let id = table[name] else { throw ProvisionError.unexpectedResponse(name) }
            return id
        }
        return ProvisionResult(
            fastStartProfileId: try id(qualityIds, Self.fastStartName),
            losslessProfileId: try id(qualityIds, Self.losslessName),
            findsMetadataProfileId: try id(metadataIds, Self.findsMetadataName),
            albumsEPsMetadataProfileId: try id(metadataIds, Self.albumsEPsMetadataName),
            magpieTagId: try id(tagIds, Self.magpieTag),
            findTagId: try id(tagIds, Self.findTag),
            created: created)
    }

    static func create(_ gate: LidarrWriteGate, _ path: String, _ body: JSONValue, _ name: String) async throws -> Int {
        let data = try await gate.send("POST", path, body: body)
        guard let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue else {
            throw ProvisionError.unexpectedResponse(name)
        }
        return id
    }

    // MARK: - Lookup and comparison

    /// The profile with exactly this name. A name that differs only in case or surrounding spaces is a
    /// conflict: Lidarr would refuse the duplicate, and it is not ours to reuse.
    static func existing(named name: String, in profiles: [JSONValue]) throws -> JSONValue? {
        let fold = { (s: String) in s.trimmingCharacters(in: .whitespaces).lowercased() }
        let similar = profiles.filter { fold($0["name"]?.stringValue ?? "") == fold(name) }
        if let exact = similar.first(where: { $0["name"]?.stringValue == name }), similar.count == 1 { return exact }
        if similar.isEmpty { return nil }
        throw ProvisionError.conflict(name)
    }

    static func matches(_ profile: JSONValue, _ spec: QualitySpec) -> Bool {
        guard profile["id"]?.intValue != nil, let items = profile["items"]?.arrayValue else { return false }
        var allowed = Set<String>()
        var cutoffNames: Set<String>?
        let cutoff = profile["cutoff"]?.intValue
        for item in items {
            let children = item["items"]?.arrayValue ?? []
            let names: Set<String>
            if children.isEmpty {
                guard let n = item["quality"]?["name"]?.stringValue else { continue }
                names = [n]
                if cutoffNames == nil, item["quality"]?["id"]?.intValue == cutoff { cutoffNames = names }
            } else {
                names = Set(children.compactMap { $0["quality"]?["name"]?.stringValue })
                if item["id"]?.intValue == cutoff { cutoffNames = names }
            }
            if item["allowed"]?.boolValue == true { allowed.formUnion(names) }
        }
        return allowed == spec.allowed && cutoffNames == [spec.cutoff]
            && profile["upgradeAllowed"]?.boolValue == spec.upgradeAllowed
    }

    static func matches(_ profile: JSONValue, _ spec: MetadataSpec) -> Bool {
        guard profile["id"]?.intValue != nil else { return false }
        return allowedNames(profile["primaryAlbumTypes"], "albumType") == spec.primary
            && allowedNames(profile["secondaryAlbumTypes"], "albumType") == spec.secondary
            && allowedNames(profile["releaseStatuses"], "releaseStatus") == spec.statuses
    }

    /// Re-review m1: whether `profile` allows everything `original` does, plus Single (all three allowed sets).
    public static func isSinglesSuperset(_ profile: JSONValue, of original: JSONValue) -> Bool {
        let pairs = [("primaryAlbumTypes", "albumType"), ("secondaryAlbumTypes", "albumType"), ("releaseStatuses", "releaseStatus")]
        return pairs.allSatisfy { field, key in
            allowedNames(original[field], key).isSubset(of: allowedNames(profile[field], key))
        } && includesSingle(profile)
    }

    private static func allowedNames(_ list: JSONValue?, _ key: String) -> Set<String> {
        Set((list?.arrayValue ?? []).filter { $0["allowed"]?.boolValue == true }
            .compactMap { $0[key]?["name"]?.stringValue })
    }

    // MARK: - Bodies from the schemas (A15)

    /// The schema with the wanted qualities allowed. Groups holding a wanted quality are split into their
    /// qualities (a group is allowed or not as a whole); every other group stays as Lidarr defines it.
    static func qualityBody(_ spec: QualitySpec, schema: JSONValue) throws -> JSONValue {
        guard var root = schema.objectValue, let items = schema["items"]?.arrayValue else {
            throw ProvisionError.schemaMissing("qualityprofile items")
        }
        func single(_ item: JSONValue) -> JSONValue {
            var o = item.objectValue ?? [:]
            let name = item["quality"]?["name"]?.stringValue ?? ""
            o["allowed"] = .bool(spec.allowed.contains(name))
            o["items"] = .array([])
            return .object(o)
        }
        var out: [JSONValue] = []
        for item in items {
            let children = item["items"]?.arrayValue ?? []
            if children.isEmpty {
                out.append(single(item))
            } else if children.contains(where: { spec.allowed.contains($0["quality"]?["name"]?.stringValue ?? "") }) {
                out.append(contentsOf: children.map(single))
            } else {
                var group = item.objectValue ?? [:]
                group["allowed"] = .bool(false)
                group["items"] = .array(children.map { child in
                    var c = child.objectValue ?? [:]
                    c["allowed"] = .bool(false)
                    return .object(c)
                })
                out.append(.object(group))
            }
        }
        let present = Set(out.compactMap { $0["quality"]?["name"]?.stringValue })
        for name in spec.allowed.union([spec.cutoff]).sorted() where !present.contains(name) {
            throw ProvisionError.schemaMissing(name)
        }
        guard let cutoffId = out.first(where: { $0["quality"]?["name"]?.stringValue == spec.cutoff })?["quality"]?["id"]?.intValue else {
            throw ProvisionError.schemaMissing(spec.cutoff)
        }
        root["id"] = nil
        root["name"] = .string(spec.name)
        root["upgradeAllowed"] = .bool(spec.upgradeAllowed)
        root["cutoff"] = .int(cutoffId)
        root["items"] = .array(out)
        return .object(root)
    }

    /// The schema with exactly the wanted album types and release statuses allowed.
    static func metadataBody(_ spec: MetadataSpec, schema: JSONValue) throws -> JSONValue {
        guard var root = schema.objectValue else { throw ProvisionError.schemaMissing("metadataprofile") }
        func allow(_ field: String, _ key: String, _ wanted: Set<String>) throws {
            guard let list = root[field]?.arrayValue else { throw ProvisionError.schemaMissing(field) }
            let names = Set(list.compactMap { $0[key]?["name"]?.stringValue })
            for name in wanted.sorted() where !names.contains(name) { throw ProvisionError.schemaMissing(name) }
            root[field] = .array(list.map { entry in
                var o = entry.objectValue ?? [:]
                o["allowed"] = .bool(wanted.contains(entry[key]?["name"]?.stringValue ?? ""))
                return .object(o)
            })
        }
        try allow("primaryAlbumTypes", "albumType", spec.primary)
        try allow("secondaryAlbumTypes", "albumType", spec.secondary)
        try allow("releaseStatuses", "releaseStatus", spec.statuses)
        root["id"] = nil
        root["name"] = .string(spec.name)
        return .object(root)
    }
}
