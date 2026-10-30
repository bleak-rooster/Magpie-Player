import Foundation
import os
import Testing
import LidarrKit
import MagpieCore
import MagpieTestSupport
@testable import Requests

/// R18: Bring in more (and so Add to your library) with the download choices: the whole artist with release types (a
/// Magpie metadata profile, provisioned on demand and applied to the artist), the quality (Lossless or Smaller files),
/// and Follow new releases. Only for an artist Magpie added; every write through the gate.
@Suite struct DownloadChoicesTests {
    static let live = mbid(24), soundtrack = mbid(25), compilation = mbid(26)

    /// `BringInMoreTests.keptFind`, plus a live album (56), a soundtrack (57) and a compilation (58), and Lidarr's
    /// metadata profiles in memory (3 "Magpie Finds"; POSTs append with ids from 20).
    static func keptFind(_ h: Harness, profiles: [[String: Any]] = [["id": 3, "name": "Magpie Finds"]]) async throws
        -> RequestID {
        let id = try await BringInMoreTests.keptFind(h)
        h.server.with { s in
            s.albums += [
                .init(id: 56, artistId: 42, rg: live, title: "Live at Dusk", monitored: false, type: "Album",
                      duration: 3_600_000, releaseDate: "2022-01-01T00:00:00Z", secondary: ["Live"]),
                .init(id: 57, artistId: 42, rg: soundtrack, title: "Film", monitored: false, type: "Album",
                      duration: 1_800_000, releaseDate: "2023-01-01T00:00:00Z", secondary: ["Soundtrack"]),
                .init(id: 58, artistId: 42, rg: compilation, title: "Best Of", monitored: false, type: "Album",
                      duration: 1_800_000, releaseDate: "2024-01-01T00:00:00Z", secondary: ["Compilation"]),
            ]
        }
        Self.stubProfiles(h.server, existing: profiles)
        return id
    }

    final class Profiles: Sendable {
        let list = OSAllocatedUnfairLock<[[String: Any]]>(uncheckedState: [])
    }

    nonisolated(unsafe) static let schema: [String: Any] = [
        "name": "",
        "primaryAlbumTypes": ["Album", "EP", "Single", "Broadcast", "Other"].enumerated().map {
            ["albumType": ["id": $0.offset, "name": $0.element], "allowed": false]
        },
        "secondaryAlbumTypes": ["Studio", "Compilation", "Soundtrack", "Live", "Remix"].enumerated().map {
            ["albumType": ["id": $0.offset, "name": $0.element], "allowed": false]
        },
        "releaseStatuses": ["Official", "Promotion", "Bootleg"].enumerated().map {
            ["releaseStatus": ["id": $0.offset, "name": $0.element], "allowed": false]
        },
    ]

    static func stubProfiles(_ server: FakeLidarr, existing: [[String: Any]]) {
        let profiles = Profiles()
        profiles.list.withLockUnchecked { $0 = existing }
        server.transport.stub(pathSuffix: "/api/v1/metadataprofile/schema") { _ in FakeLidarr.reply(schema) }
        server.transport.stub(pathSuffix: "/api/v1/metadataprofile") { _ in
            FakeLidarr.reply(profiles.list.withLockUnchecked { $0 })
        }
        server.transport.stub(method: "POST", pathSuffix: "/api/v1/metadataprofile") { req in
            var body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let id = profiles.list.withLockUnchecked { $0.count + 20 }
            body["id"] = id
            profiles.list.withLockUnchecked { $0.append(body) }
            return FakeLidarr.reply(body, status: 201)
        }
    }

    /// The whole artist with the default types (Albums + EPs, Studio), Lossless: the profile is created, the artist
    /// set to it, and only studio albums and EPs come in. Keep set Lossless already, so no quality write.
    @Test func wholeArtistWithDefaultTypes() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let before = h.server.writes.count

        let result = try await h.runner.bringIn(id, choice: .everything, follow: false, types: .standard,
                                                qualityProfileId: 9)

        #expect(result == .init(albums: 3, searching: true, following: false))
        let writes = Array(h.server.writeBodies().dropFirst(before))
        #expect(writes.map(\.0) == ["POST metadataprofile", "PUT artist/editor", "PUT album/monitor", "POST command"])
        #expect(writes[0].1["name"] as? String == "Magpie Albums+EPs \u{00B7} Studio")
        #expect(Set(writes[1].1.keys) == ["artistIds", "metadataProfileId"])
        #expect(writes[1].1["artistIds"] as? [Int] == [42] && writes[1].1["metadataProfileId"] as? Int == 21)
        #expect(writes[2].1["albumIds"] as? [Int] == [53, 52, 51])
        #expect(h.server.with { $0.artists.first?.metadata } == 21)
        #expect(h.server.with { $0.artists.first?.quality } == 9)
    }

    /// Albums + EPs + Singles with Live, Smaller files: the singles and the live album come in, never the soundtrack
    /// or the compilation, and the artist moves to the smaller-files profile.
    @Test func wholeArtistWithSinglesAndLiveSmallerFiles() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let types = ReleaseTypes(kinds: .albumsEPsAndSingles, studio: true, live: true)

        let offer = try await h.runner.bringInOffer(id, types: types)
        #expect(offer.options[.everything]?.albumIds == [56, 54, 53, 52, 51])
        let before = h.server.writes.count
        let result = try await h.runner.bringIn(id, choice: .everything, offered: offer.options[.everything]?.albumIds,
                                                follow: true, types: types, qualityProfileId: 4)

        #expect(result.albums == 5 && result.following)
        let writes = Array(h.server.writeBodies().dropFirst(before))
        #expect(writes.map(\.0) == ["POST metadataprofile", "PUT artist/editor", "PUT artist/editor",
                                    "PUT album/monitor", "POST command", "PUT artist/editor"])
        #expect(Set(writes[2].1.keys) == ["artistIds", "qualityProfileId"] && writes[2].1["qualityProfileId"] as? Int == 4)
        #expect(Set(Self.monitored(h)).isDisjoint(with: [57, 58]))
        #expect(h.server.with { $0.artists.first?.quality } == 4)
    }

    /// Idempotent: a profile Magpie made before (same name, same settings) is reused; the artist already on it gets
    /// no editor write.
    @Test func existingProfileIsReused() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h, profiles: [Self.profile(id: 12, ReleaseTypes.standard)])
        h.server.with { $0.artists[0].metadata = 12 }
        let before = h.server.writes.count

        _ = try await h.runner.bringIn(id, choice: .everything, follow: false, types: .standard, qualityProfileId: 9)

        #expect(Array(h.server.writeBodies().dropFirst(before)).map(\.0) == ["PUT album/monitor", "POST command"])
    }

    /// A profile with Magpie's name but other settings (not Magpie's to change): nothing is written at all.
    @Test func conflictingProfileWritesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        var other = Self.profile(id: 12, ReleaseTypes(kinds: .albums))
        other["name"] = ReleaseTypes.standard.profileName
        let id = try await Self.keptFind(h, profiles: [other])
        let before = h.server.writes.count

        await #expect(throws: RequestRunner.BringInError.profileConflict(ReleaseTypes.standard.profileName)) {
            _ = try await h.runner.bringIn(id, choice: .everything, follow: true, types: .standard, qualityProfileId: 9)
        }
        #expect(h.server.writes.count == before)
    }

    /// This album only ignores release types: no profile is made or changed.
    @Test func thisAlbumLeavesTheProfileAlone() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let before = h.server.writes.count

        _ = try await h.runner.bringIn(id, choice: .thisAlbum, follow: false, types: .standard, qualityProfileId: 9)

        #expect(Array(h.server.writeBodies().dropFirst(before)).map(\.0) == ["PUT album/monitor", "POST command"])
    }

    /// With changes off nothing is read for writing and nothing is sent.
    @Test func changesOffWritesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        await h.gate.setEnabled(false)
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.BringInError.changesOff) {
            _ = try await h.runner.bringIn(id, choice: .everything, follow: true, types: .standard, qualityProfileId: 4)
        }
        #expect(h.server.writes.count == before)
    }

    @Test func defaultsAreTheOwners() {
        let d = DownloadChoices.defaults
        #expect(d.what == .wholeArtist && d.types == .standard && d.quality == .lossless && !d.follow)
        // Saved choices from a later build with unknown or missing fields still read as the defaults.
        let partial = try? JSONDecoder().decode(DownloadChoices.self, from: Data(#"{"quality":"smaller"}"#.utf8))
        #expect(partial == DownloadChoices(quality: .smaller))
    }

    static func monitored(_ h: Harness) -> [Int] {
        h.server.with { s in s.albums.filter(\.monitored).map(\.id) }
    }

    static func profile(id: Int, _ types: ReleaseTypes) -> [String: Any] {
        let allow = { (field: String, key: String, wanted: [String]) -> [[String: Any]] in
            (schema[field] as! [[String: Any]]).map { entry in
                var e = entry
                e["allowed"] = wanted.contains((entry[key] as! [String: Any])["name"] as! String)
                return e
            }
        }
        return ["id": id, "name": types.profileName,
                "primaryAlbumTypes": allow("primaryAlbumTypes", "albumType", types.primaryNames),
                "secondaryAlbumTypes": allow("secondaryAlbumTypes", "albumType", types.secondaryNames),
                "releaseStatuses": allow("releaseStatuses", "releaseStatus", ["Official"])]
    }
}

/// R18 on the artist page's "Add to Lidarr and download" (W3): the chosen profiles go into the one add, and Follow
/// new releases off means Lidarr monitors nothing new (`monitorNewItems: none`).
@Suite struct ArtistAddChoicesTests {
    @Test func addCarriesTheChoices() async throws {
        let fake = try await ArtistLidarrTests.Fake()
        var setup = ArtistLidarrTests.setup
        setup.metadataProfileId = 21
        setup.qualityProfileId = 9
        _ = try await ArtistLidarr.add(mbid: ArtistLidarrTests.newMBID, lidarr: fake.client, gate: fake.gate,
                                       ledger: fake.ledger, setup: setup, follow: false)
        let post = try #require(fake.writes.first)
        let body = try #require(post.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["metadataProfileId"] as? Int == 21 && body["qualityProfileId"] as? Int == 9)
        #expect(body["monitorNewItems"] as? String == "none")
        #expect((body["addOptions"] as? [String: Any])?["monitor"] as? String == "all")

        let followed = try await ArtistLidarrTests.Fake()
        _ = try await ArtistLidarr.add(mbid: ArtistLidarrTests.newMBID, lidarr: followed.client, gate: followed.gate,
                                       ledger: followed.ledger, setup: setup, follow: true)
        let again = try #require(followed.writes.first?.httpBody.flatMap {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(again["monitorNewItems"] as? String == "all")
    }

    /// Release types on an add: the profile is made only after Lidarr's lookup knows the artist, and goes into the add.
    @Test func addWithTypesProvisionsAfterTheLookup() async throws {
        let fake = try await ArtistLidarrTests.Fake()
        Self.stubProfiles(fake.transport, existing: [])
        _ = try await ArtistLidarr.add(mbid: ArtistLidarrTests.newMBID, lidarr: fake.client, gate: fake.gate,
                                       ledger: fake.ledger, setup: ArtistLidarrTests.setup, follow: false, types: .standard)
        #expect(fake.writes.map { "\($0.httpMethod!) \($0.url!.path)" } == ["POST /api/v1/metadataprofile", "POST /api/v1/artist"])
        let body = try #require(fake.writes.last?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["metadataProfileId"] as? Int == 20)

        // Lidarr's lookup doesn't know it: nothing at all is written, not even the profile.
        let unknown = try await ArtistLidarrTests.Fake(lookup: Data("[]".utf8))
        Self.stubProfiles(unknown.transport, existing: [])
        await #expect(throws: ArtistLidarrError.notFound) {
            _ = try await ArtistLidarr.add(mbid: ArtistLidarrTests.newMBID, lidarr: unknown.client, gate: unknown.gate,
                                           ledger: unknown.ledger, setup: ArtistLidarrTests.setup, follow: false,
                                           types: .standard)
        }
        #expect(unknown.writes.isEmpty)
    }

    /// "Add more to your library" for an artist Magpie added: its release types, quality, following, and monitoring,
    /// each only when it differs, then a search.
    @Test func addMoreForAMagpieArtist() async throws {
        let fake = try await ArtistLidarrTests.Fake()
        Self.stubProfiles(fake.transport, existing: [DownloadChoicesTests.profile(id: 12, .standard)])
        try await ArtistLidarr.addMore(lidarrId: 30, lidarr: fake.client, gate: fake.gate, ledger: fake.ledger,
                                       types: .standard, qualityProfileId: 9, follow: true)
        let writes = fake.writes.map { req in
            (req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:])
        }
        #expect(fake.writes.map { "\($0.httpMethod!) \($0.url!.path)" }
                == ["PUT /api/v1/artist/editor", "PUT /api/v1/artist/editor", "PUT /api/v1/artist/editor",
                    "PUT /api/v1/artist/editor", "POST /api/v1/command"])
        #expect(writes[0]["metadataProfileId"] as? Int == 12 && writes[0].count == 2)
        #expect(writes[1]["qualityProfileId"] as? Int == 9 && writes[1].count == 2)
        #expect(writes[2]["monitorNewItems"] as? String == "new" && writes[2].count == 2)
        #expect(writes[3]["monitored"] as? Bool == true && writes[3].count == 2)
        #expect(writes[4]["name"] as? String == "ArtistSearch")
    }

    /// The owner's artist: refused before anything is written, the profile included.
    @Test func addMoreRefusesTheOwnersArtist() async throws {
        let fake = try await ArtistLidarrTests.Fake()
        Self.stubProfiles(fake.transport, existing: [])
        await #expect(throws: ArtistLidarrError.notMagpies) {
            try await ArtistLidarr.addMore(lidarrId: 20, lidarr: fake.client, gate: fake.gate, ledger: fake.ledger,
                                           types: .standard, qualityProfileId: 9, follow: true)
        }
        #expect(fake.writes.isEmpty)
    }

    static func stubProfiles(_ transport: MockTransport, existing: [[String: Any]]) {
        let profiles = DownloadChoicesTests.Profiles()
        profiles.list.withLockUnchecked { $0 = existing }
        transport.stub(pathSuffix: "/api/v1/metadataprofile/schema") { _ in FakeLidarr.reply(DownloadChoicesTests.schema) }
        transport.stub(pathSuffix: "/api/v1/metadataprofile") { _ in FakeLidarr.reply(profiles.list.withLockUnchecked { $0 }) }
        transport.stub(method: "POST", pathSuffix: "/api/v1/metadataprofile") { req in
            var body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let id = profiles.list.withLockUnchecked { $0.count + 20 }
            body["id"] = id
            profiles.list.withLockUnchecked { $0.append(body) }
            return FakeLidarr.reply(body, status: 201)
        }
    }
}
