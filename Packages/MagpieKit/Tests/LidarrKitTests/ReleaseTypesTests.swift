import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// R18: release types for whole-artist downloads, their Magpie metadata profiles (provisioned on demand, never an
/// existing one changed), and the gate's one new artist-editor shape `{artistIds: [id], metadataProfileId}`, only for
/// an artist the ledger says Magpie added, and only to a Magpie profile.
@Suite struct ReleaseTypesTests {
    @Test func profileNames() {
        #expect(ReleaseTypes.standard.profileName == "Magpie Albums+EPs \u{00B7} Studio")
        #expect(ReleaseTypes(kinds: .albumsAndEPs, studio: true, live: true).profileName
                == "Magpie Albums+EPs \u{00B7} Studio+Live")
        #expect(ReleaseTypes(kinds: .albums, studio: false, soundtrack: true).profileName
                == "Magpie Albums \u{00B7} Soundtrack")
        #expect(ReleaseTypes(kinds: .albumsEPsAndSingles, studio: true, soundtrack: true, live: true).profileName
                == "Magpie Albums+EPs+Singles \u{00B7} Studio+Soundtrack+Live")
        // A profile must allow one secondary type: none on is Studio.
        #expect(ReleaseTypes(kinds: .albums, studio: false).secondaryNames == ["Studio"])
    }

    /// Round 22 (owner, D175): Albums, EPs and Singles are chosen independently (at least one). The three R18 ladder
    /// choices keep their profile names, so profiles Magpie already made are reused.
    @Test func kindsAreChosenIndependently() {
        let singlesOnly = ReleaseTypes(albums: false, eps: false, singles: true)
        #expect(singlesOnly.primaryNames == ["Single"])
        #expect(singlesOnly.profileName == "Magpie Singles \u{00B7} Studio")
        #expect(singlesOnly.includes(albumType: "Single", secondaryTypes: []))
        #expect(!singlesOnly.includes(albumType: "Album", secondaryTypes: []))
        let albumsAndSingles = ReleaseTypes(albums: true, eps: false, singles: true)
        #expect(albumsAndSingles.profileName == "Magpie Albums+Singles \u{00B7} Studio")
        #expect(!albumsAndSingles.includes(albumType: "EP", secondaryTypes: []))
        #expect(ReleaseTypes(albums: false, eps: true, singles: false).profileName == "Magpie EPs \u{00B7} Studio")
        // The R18 ladder spells the same as before.
        #expect(ReleaseTypes(kinds: .albumsEPsAndSingles) == ReleaseTypes(albums: true, eps: true, singles: true))
        #expect(ReleaseTypes(albums: true, eps: true, singles: false).kinds == .albumsAndEPs)
        #expect(ReleaseTypes(albums: false, eps: true, singles: true).kinds == nil)
        // Every combination is one of Magpie's profiles; nothing chosen isn't a choice.
        #expect(ReleaseTypes.all.count == 7 * 8)
        #expect(ReleaseTypes.isMagpieMetadataProfile("Magpie Singles \u{00B7} Studio"))
        #expect(!ReleaseTypes(albums: false, eps: false, singles: false).hasKind)
    }

    /// Saved choices from before round 22 (`kinds`) still read the same; new ones keep the three switches.
    @Test func decodesTheLadderAndTheSwitches() throws {
        let old = Data(#"{"kinds":"albumsEPsAndSingles","studio":true,"soundtrack":false,"live":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ReleaseTypes.self, from: old)
        #expect(decoded == ReleaseTypes(albums: true, eps: true, singles: true, live: true))
        let mixed = ReleaseTypes(albums: true, eps: false, singles: true)
        #expect(try JSONDecoder().decode(ReleaseTypes.self, from: JSONEncoder().encode(mixed)) == mixed)
        let none = Data(#"{"albums":false,"eps":false,"singles":false}"#.utf8)
        #expect(try JSONDecoder().decode(ReleaseTypes.self, from: none) == .standard, "nothing chosen reads as the default")
    }

    @Test func includesFiltersAsLidarrDoes() {
        let standard = ReleaseTypes.standard
        #expect(standard.includes(albumType: "Album", secondaryTypes: []))
        #expect(standard.includes(albumType: "ep", secondaryTypes: ["Studio"]))
        #expect(!standard.includes(albumType: "Single", secondaryTypes: []))
        #expect(!standard.includes(albumType: "Album", secondaryTypes: ["Live"]))
        #expect(!standard.includes(albumType: nil, secondaryTypes: []))
        let live = ReleaseTypes(kinds: .albumsEPsAndSingles, studio: false, live: true)
        #expect(live.includes(albumType: "Single", secondaryTypes: ["Live"]))
        #expect(!live.includes(albumType: "Album", secondaryTypes: []), "Studio is off")
        #expect(!live.includes(albumType: "Album", secondaryTypes: ["Live", "Compilation"]))
    }

    // MARK: - Provisioning

    @Test func createsTheProfileOnceThenReusesIt() async throws {
        let fake = FakeLidarr()
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: true)
        let types = ReleaseTypes(kinds: .albumsAndEPs, studio: true, live: true)

        let id = try await Provisioner().ensureReleaseTypes(types, gate: gate, client: client)
        #expect(fake.posts.count == 1)
        let created = try #require(fake.metadata.first { $0["name"]?.stringValue == types.profileName })
        #expect(created["id"]?.intValue == id)
        let allowed = { (field: String, key: String) in
            Set((created[field]?.arrayValue ?? []).filter { $0["allowed"]?.boolValue == true }
                .compactMap { $0[key]?["name"]?.stringValue })
        }
        #expect(allowed("primaryAlbumTypes", "albumType") == ["Album", "EP"])
        #expect(allowed("secondaryAlbumTypes", "albumType") == ["Studio", "Live"])
        #expect(allowed("releaseStatuses", "releaseStatus") == ["Official"])

        // Idempotent: the second run finds it by name and writes nothing.
        let again = try await Provisioner().ensureReleaseTypes(types, gate: gate, client: client)
        #expect(again == id)
        #expect(fake.posts.count == 1)
    }

    /// A same-named profile with other settings (the owner edited it) stops before any write.
    @Test func sameNameDifferentSettingsStops() async throws {
        let fake = FakeLidarr()
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: true)
        _ = try await Provisioner().ensureReleaseTypes(ReleaseTypes(kinds: .albums), gate: gate, client: client)
        // The owner's own profile happens to carry the name Magpie would use for Albums+EPs · Studio.
        var edited = try #require(fake.metadata.last?.objectValue)
        edited["name"] = .string(ReleaseTypes.standard.profileName)
        let fake2 = FakeLidarr(metadata: fake.metadata + [.object(edited)])
        let (client2, _) = makeClient(fake2.transport)
        let gate2 = await GateEnv().gate(client2, enabled: true)
        await #expect(throws: ProvisionError.conflict(ReleaseTypes.standard.profileName)) {
            _ = try await Provisioner().ensureReleaseTypes(.standard, gate: gate2, client: client2)
        }
        #expect(fake2.posts.isEmpty)
    }

    @Test func changesOffWritesNothing() async throws {
        let fake = FakeLidarr()
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: false)
        await #expect(throws: WriteGateError.disabled) {
            _ = try await Provisioner().ensureReleaseTypes(.standard, gate: gate, client: client)
        }
        #expect(fake.posts.isEmpty)
    }
}

/// The gate's metadata-profile shape (R18), on WriteConfinementTests' fake: artist 7 is the owner's, 42 a find Magpie
/// created. Profiles: 1 "Standard" (the owner's), 3 "Magpie Finds", 12 "Magpie Albums+EPs · Studio+Live", 14 "Magpie Owner
/// Picks" (the owner's, despite the name).
@Suite struct ReleaseTypesGateTests {
    typealias Call = WriteGateTests.Call
    typealias Fake = WriteConfinementTests.Fake

    static func fake(kept: Bool = false) async throws -> Fake {
        let fake = try await Fake(kept: kept)
        let profiles: [[String: Any]] = [["id": 1, "name": "Standard"], ["id": 3, "name": "Magpie Finds"],
                                         ["id": 12, "name": "Magpie Albums+EPs \u{00B7} Studio+Live"],
                                         ["id": 14, "name": "Magpie Owner Picks"]]
        fake.transport.stub(pathSuffix: "/api/v1/metadataprofile", body: try JSONSerialization.data(withJSONObject: profiles))
        return fake
    }

    @Test(arguments: [3, 12])
    func magpieArtistGetsAMagpieProfile(_ profile: Int) async throws {
        let fake = try await Self.fake()
        let gate = await fake.gate()
        let call = Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":\#(profile)}"#)
        _ = try await gate.send(call.method, call.path, body: WriteConfinementTests.body(call))
        #expect(fake.writes.count == 1)
    }

    /// Kept artists are still Magpie's (Add to your library applies the profile right after Keep).
    @Test func keptMagpieArtistToo() async throws {
        let fake = try await Self.fake(kept: true)
        let gate = await fake.gate()
        let call = Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":12}"#)
        _ = try await gate.send(call.method, call.path, body: WriteConfinementTests.body(call))
        #expect(fake.writes.count == 1)
    }

    static let refused: [Call] = [
        // The owner's artist, and one the ledger doesn't know: never changed.
        Call("PUT", "artist/editor", #"{"artistIds":[7],"metadataProfileId":12}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[99],"metadataProfileId":12}"#),
        // Only Magpie's own profiles.
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":1}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":55}"#),
        // Review M1: an owner's profile that merely starts with "Magpie ".
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":14}"#),
        // Exactly {artistIds: [one], metadataProfileId: positive id}.
        Call("PUT", "artist/editor", #"{"artistIds":[42,7],"metadataProfileId":12}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":12,"qualityProfileId":4}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":12,"monitorNewItems":"new"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":12,"rootFolderPath":"/music/library","moveFiles":true}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":"12"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":0}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":true}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[42],"metadataProfileId":12,"MetadataProfileId":1}"#),
        // Profiles are still only ever created.
        Call("PUT", "metadataprofile/12", #"{"id":12,"name":"Magpie Albums+EPs · Studio+Live"}"#),
        Call("DELETE", "metadataprofile/12"),
    ]

    @Test(arguments: refused)
    func refusedWritesNothing(_ call: Call) async throws {
        let fake = try await Self.fake()
        await WriteConfinementTests.expectRefused(call, await fake.gate(), fake)
    }

    /// Round 24 (D237): a Magpie profile name reads back as the switches it was made from; any other name is Custom.
    @Test func aMagpieProfileNameReadsBack() {
        for types in ReleaseTypes.all where types.studio || types.soundtrack || types.live {
            #expect(ReleaseTypes(magpieProfileName: types.profileName) == types, "\(types.profileName)")
        }
        #expect(ReleaseTypes(magpieProfileName: "Magpie Albums+EPs \u{00B7} Studio") == ReleaseTypes(albums: true, eps: true, singles: false))
        #expect(ReleaseTypes(magpieProfileName: "Owner Profile") == nil)
        #expect(ReleaseTypes(magpieProfileName: Provisioner.findsMetadataName) == nil)
        #expect(ReleaseTypes(magpieProfileName: "magpie albums \u{00B7} studio") == nil)
    }
}
