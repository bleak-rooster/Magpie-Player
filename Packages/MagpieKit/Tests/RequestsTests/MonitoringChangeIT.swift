import Foundation
import Testing
import MagpieCore
@testable import LidarrKit
@testable import Requests

/// Round 24 (owner, 2026-11-08, D237, D243, D244), end to end against the dev stack's real Lidarr (`MAGPIE_IT=1`; writes to
/// the dev Lidarr only, G0 as TryIT): an artist Magpie didn't add (put straight into the dev Lidarr's main root on its
/// own "Standard" profile, so no Magpie ledger knows it) moves onto Magpie's Albums profile through the gate's
/// `ownedChange` rule with Keep, then Revert puts the recorded profile back. The change log shows exactly the two-key
/// editor body and no delete. The artist is removed from the dev Lidarr afterwards. The dev stack has no indexer, so
/// nothing downloads.
@Suite(.enabled(if: TryDevStack.enabled), .serialized)
struct MonitoringChangeIT {
    @Test func aProfileChangeOnTheDevLidarrAndBack() async throws {
        try await TryDevStack.exclusive { try await run() }
    }

    private func run() async throws {
        let client = try await TryDevStack.client()
        if try await client.artists().contains(where: { $0.foreignArtistId == TryIT.artist }) {
            print("SKIP MonitoringChangeIT: the dev Lidarr already has the test artist")
            return
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-monitoring-\(UUID().uuidString)")
        let suite = "magpie-monitoring-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let plainGate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite)
        await plainGate.setEnabled(true)
        let provisioned = try await Provisioner().ensure(gate: plainGate, client: client)
        // The owner's own artist: added straight to the dev Lidarr, on a profile of his.
        let ownerProfile = try #require(try await client.metadataProfiles().first { !ReleaseTypes.isMagpieMetadataProfile($0.name)
                                                                                     && !Provisioner.metadataProfileNames.contains($0.name) })
        var body = try #require(try await client.artistLookupJSON(mbid: TryIT.artist)?.objectValue)
        body["id"] = nil
        body["rootFolderPath"] = .string("/music/library")
        body["qualityProfileId"] = .int(provisioned.fastStartProfileId)
        body["metadataProfileId"] = .int(ownerProfile.id)
        body["monitored"] = .bool(true)
        body["monitorNewItems"] = .string("none")
        body["tags"] = .array([])
        body["addOptions"] = .object(["monitor": .string("all"), "searchForMissingAlbums": .bool(false)])
        let raw = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(JSONValue.object(body))) as? [String: Any] ?? [:]
        let artistId = try #require(try await FindsIT.devLidarr("POST", "artist", body: raw)["id"] as? Int)
        do {
            try await check(artistId, ownerProfile: ownerProfile, client: client, dir: dir, suite: suite,
                            findTag: provisioned.findTagId)
        } catch {
            _ = try? await FindsIT.devLidarr("DELETE", "artist/\(artistId)", query: ["deleteFiles": "false", "addImportListExclusion": "false"])
            throw error
        }
        _ = try await FindsIT.devLidarr("DELETE", "artist/\(artistId)", query: ["deleteFiles": "false", "addImportListExclusion": "false"])
    }

    private func check(_ artistId: Int, ownerProfile: MetadataProfile, client: LidarrClient, dir: URL, suite: String,
                       findTag: Int) async throws {
        // Lidarr lists the artist's albums once its own refresh after the add is done.
        var albums: [LidarrAlbum] = []
        for _ in 0..<90 where albums.isEmpty {
            albums = try await client.albums(artistId: artistId)
            if albums.isEmpty { try await Task.sleep(for: .seconds(2)) }
        }
        try #require(!albums.isEmpty, "the dev Lidarr never listed the artist's albums")
        let ledger = Ledger(fileURL: dir.appending(path: "ledger.json"), instance: client.instanceScope)
        let roots = WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: findTag)
        let gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite,
                                   confinement: WriteConfinement(ledger: ledger, roots: { roots }))
        await gate.setMonitoringChangesEnabled(true)
        let changer = MonitoringChanger(lidarr: client, gate: gate, ledger: ledger, roots: { roots }, checks: 90, pause: .seconds(1))

        let before = try await changer.current(artistId: artistId)
        #expect(before.types == nil, "the owner's profile reads as Custom")
        let albumsOnly = ReleaseTypes(albums: true, eps: false, singles: false)
        let preview = try await changer.preview(artistId: artistId, types: albumsOnly, keep: MonitoringKeepList())
        #expect(try await changer.apply(preview, choice: .keep) == .finished)

        let profiles = try await client.metadataProfiles()
        let now = try await client.artist(id: artistId)
        #expect(profiles.first { $0.id == now.metadataProfileId }?.name == albumsOnly.profileName)
        #expect(now.rootFolderPath == "/music/library" && now.path?.hasPrefix("/music/library/") == true, "never moved")
        let monitored = try await client.albums(artistId: artistId).filter(\.monitored)
        #expect(monitored.allSatisfy { albumsOnly.includes(albumType: $0.albumType, secondaryTypes: $0.secondaryTypes) })
        let log = await gate.changeLog()
        let editors = log.filter { $0.method == "PUT" && $0.path == "/api/v1/artist/editor" }
        #expect(!editors.isEmpty && editors.allSatisfy { $0.bodySummary == #"{"artistIds":[\#(artistId)],"metadataProfileId":\#(now.metadataProfileId ?? -1)}"# })
        #expect(!log.contains { $0.method == "DELETE" }, "Keep deletes nothing")

        #expect(try await changer.current(artistId: artistId).canRevert)
        #expect(try await changer.revert(artistId: artistId) == .finished)
        #expect(try await client.artist(id: artistId).metadataProfileId == ownerProfile.id, "the recorded profile is back")
        #expect(!(await gate.changeLog()).contains { $0.method == "DELETE" })
    }
}
