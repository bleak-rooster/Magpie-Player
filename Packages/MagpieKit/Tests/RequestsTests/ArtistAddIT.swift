import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Requests

/// P3 on the dev stack: "Add to Lidarr and download" adds the test artist (Judie Tzuke, which the dev Lidarr doesn't
/// have) through the confined gate, everything monitored, Lidarr searches, and the ledger has it as Magpie's. Removes
/// only that artist afterwards (the dev helper; the gate refuses deleting an artist outside the Finds root, by design).
@Suite(.serialized, .enabled(if: TryDevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct ArtistAddIT {
    @Test func addAndSearchOnDevStack() async throws {
        try await TryDevStack.exclusive { try await run() }
    }

    private func run() async throws {
        let client = try await TryDevStack.client()
        let artist = TryIT.artist
        do {
            guard try await client.artistLookupJSON(mbid: artist) != nil else {
                print("SKIP ArtistAddIT: Lidarr's metadata server doesn't know the test artist")
                return
            }
        } catch {
            print("SKIP ArtistAddIT: external metadata server unreachable (\(error))")
            return
        }
        try #require(try await client.artists().first { $0.foreignArtistId == artist } == nil,
                     "the dev Lidarr already has the test artist; remove it (it was left by an earlier run)")

        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-artistadd-\(UUID().uuidString)")
        let suite = "magpie-artistadd-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        let ledger = Ledger(fileURL: dir.appending(path: "ledger.json"), instance: client.instanceScope)
        let gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite,
                                   confinement: WriteConfinement(ledger: ledger, roots: {
                                       .init(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: nil)
                                   }))
        await gate.setEnabled(true)
        let provisioned = try await Provisioner().ensure(gate: gate, client: client)
        let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: provisioned.fastStartProfileId,
                                        metadataProfileId: provisioned.findsMetadataProfileId,
                                        tagIds: [provisioned.magpieTagId])

        #expect(try await ArtistLidarr.read(name: "Judie Tzuke", mbid: artist, lidarr: client, ledger: ledger)
                == .notInLidarr(mbid: artist))
        var createdId: Int?
        do {
            let id = try await ArtistLidarr.add(mbid: artist, lidarr: client, gate: gate, ledger: ledger, setup: setup)
            createdId = id
            let added = try await client.artist(id: id)
            #expect(added.monitored && added.rootFolderPath?.hasPrefix("/music/library") == true)
            #expect(added.qualityProfileId == provisioned.fastStartProfileId)
            #expect(added.tags == [provisioned.magpieTagId])
            #expect(try await ledger.createdArtist(added), "ledgered as Magpie's, MBID-checked")
            // Lidarr refreshes the artist, then searches for its missing albums.
            var searched = false
            for _ in 0..<60 where !searched {
                searched = try await client.commands().contains {
                    ArtistLidarr.searchCommands.contains($0.name.lowercased()) && $0.artistIds.contains(id)
                }
                if !searched { try await Task.sleep(for: .seconds(2)) }
            }
            #expect(searched, "Lidarr searched for the artist's albums")
            let state = try await ArtistLidarr.read(name: "Judie Tzuke", mbid: artist, lidarr: client, ledger: ledger)
            guard case .monitored(id, _) = state else { Issue.record("state: \(state)"); return }
            // A second add writes nothing: the artist is there now.
            await #expect(throws: ArtistLidarrError.alreadyInLidarr) {
                try await ArtistLidarr.add(mbid: artist, lidarr: client, gate: gate, ledger: ledger, setup: setup)
            }
            #expect(await gate.changeLog().filter { $0.method == "POST" && $0.path.hasSuffix("artist") }.count == 1)
        } catch {
            Issue.record(error)
        }

        // Clean up only the artist this test created.
        if let createdId {
            try await TryIT.waitForRefresh(client)
            _ = try await FindsIT.devLidarr("DELETE", "artist/\(createdId)",
                                            query: ["deleteFiles": "false", "addImportListExclusion": "false"])
            #expect(try await client.artists().first { $0.foreignArtistId == artist } == nil)
        }
    }
}
