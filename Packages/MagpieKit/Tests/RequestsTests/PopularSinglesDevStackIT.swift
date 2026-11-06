import Foundation
import Testing
import MagpieCore
import ListenBrainzKit
@testable import LidarrKit
@testable import Requests
@testable import Search

/// Round 19, end to end against the dev stack's real Lidarr and real MusicBrainz (`MAGPIE_IT=1 MAGPIE_LIVE=1`; writes to
/// the dev Lidarr only, G0 as TryIT): a song as an Aurral chart row gives it (names and length, no MusicBrainz ids) is
/// matched, tried as a find, and Lidarr's own metadata lists, monitors and searches the release Magpie picked. Each
/// artist Magpie added is removed afterwards. The dev stack has no indexer, so nothing downloads.
@Suite(.enabled(if: TryDevStack.enabled && ProcessInfo.processInfo.environment["MAGPIE_LIVE"] == "1"), .serialized)
struct PopularSinglesDevStackIT {
    struct Case: Sendable, CustomStringConvertible {
        var title: String, artist: String, duration: TimeInterval
        /// The release type Lidarr should end up monitoring, and whether "Magpie Finds Extras" is needed.
        var type: String, extras: Bool
        var description: String { "\(artist) – \(title)" }
    }

    static let cases = [
        Case(title: "Espresso", artist: "Sabrina Carpenter", duration: 175, type: "Single", extras: false),
        Case(title: "Good Luck, Babe!", artist: "Chappell Roan", duration: 218, type: "Single", extras: false),
        Case(title: "APT.", artist: "ROSÉ", duration: 170, type: "Single", extras: false),
        Case(title: "Golden", artist: "HUNTR/X", duration: 194, type: "Single", extras: true),
    ]

    @Test(arguments: cases)
    func aChartSongReachesLidarrsSearch(_ c: Case) async throws {
        try await TryDevStack.exclusive { try await run(c) }
    }

    private func run(_ c: Case) async throws {
        let client = try await TryDevStack.client()
        let mb = MusicBrainzClient(transport: URLSessionTransport(timeout: 20), userAgent: MusicBrainzClient.userAgent(version: "it"))
        let song = OutsideSong(title: c.title, artist: c.artist, duration: c.duration)
        let recording = try await OutsideSongMatch.resolve(
            song, links: { _, _, _ in throw OutsideSongMatch.Failure.unmatched }, release: { _ in nil },
            finder: .init(search: { try await mb.searchRecordings(title: $0, artist: $1) }))
        let artistMBID = try #require(recording.artistMBID)
        if try await client.artists().contains(where: { $0.foreignArtistId == artistMBID }) {
            print("SKIP \(c): the dev Lidarr already has the artist")
            return
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-popular-\(UUID().uuidString)")
        let suite = "magpie-popular-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let plainGate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite)
        await plainGate.setEnabled(true)
        let provisioned = try await Provisioner().ensure(gate: plainGate, client: client)
        let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: provisioned.fastStartProfileId,
                                        metadataProfileId: provisioned.findsMetadataProfileId, tagIds: [provisioned.magpieTagId],
                                        finds: .init(rootFolderPath: "/music/samples",
                                                     tagIds: [provisioned.magpieTagId, provisioned.findTagId]))
        let ledger = Ledger(fileURL: dir.appending(path: "ledger.json"), instance: client.instanceScope)
        let gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite,
                                   confinement: WriteConfinement(ledger: ledger, roots: {
                                       .init(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: provisioned.findTagId)
                                   }))
        let runner = RequestRunner(lidarr: client, gate: gate, ledger: ledger, mb: mb,
                                   library: LibraryAccess(startScan: {}, isScanning: { false }, refreshIndex: {}, songId: { _ in nil }),
                                   store: RequestStore(fileURL: dir.appending(path: "requests.json")), setup: { setup })
        let id = try await runner.tryRecording(recording, tier: .standard)
        await runner.settle()

        var createdArtistId: Int?
        do {
            var r = try #require(await runner.requests.first { $0.id == id })
            for _ in 0..<120 where r.albumId == nil || r.state != .searching {
                if case .failed = r.state { break }
                try await Task.sleep(for: .seconds(2))
                await runner.tick()
                r = try #require(await runner.requests.first { $0.id == id })
                if r.addSent { createdArtistId = r.lidarrArtistId }
            }
            if r.addSent { createdArtistId = r.lidarrArtistId }
            #expect(r.state == .searching, "\(c): \(r.state)")
            #expect((r.findsExtras == true) == c.extras, "\(c): Extras \(String(describing: r.findsExtras))")
            let artistId = try #require(r.lidarrArtistId), albumId = try #require(r.albumId, "\(c): never listed by Lidarr")
            try await Self.settled(client)
            let album = try #require(try await client.albums(artistId: artistId).first { $0.id == albumId })
            #expect(album.monitored && album.albumType == c.type, "\(c): \(album.title) \(album.albumType ?? "?")")
            print("OK \(c): \(album.albumType ?? "?") “\(album.title)” monitored and searched (\(r.recording.title))")
            await runner.cancel(id)
            await runner.tick()
        } catch {
            Issue.record(error)
        }
        if let createdArtistId {
            try await Self.settled(client)
            _ = try await FindsIT.devLidarr("DELETE", "artist/\(createdArtistId)",
                                            query: ["deleteFiles": "false", "addImportListExclusion": "false"])
        }
    }

    /// Lidarr's refresh of a big catalogue (Sabrina Carpenter's) outlasts TryIT's two minutes: up to six.
    static func settled(_ client: LidarrClient) async throws {
        for _ in 0..<180 {
            let busy = try await client.commands().contains { c in
                c.name.lowercased() == "refreshartist" && ["queued", "started"].contains(c.status.lowercased())
            }
            if !busy { return }
            try await Task.sleep(for: .seconds(2))
        }
        Issue.record("Lidarr kept refreshing for 6 minutes")
    }
}
