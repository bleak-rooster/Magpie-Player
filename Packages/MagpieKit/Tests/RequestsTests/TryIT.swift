import Foundation
import Testing
import MagpieCore
import ListenBrainzKit
@testable import LidarrKit
@testable import Requests

/// Try against the dev stack's Lidarr (writes!). Run via `scripts/it.sh` (MAGPIE_IT=1).
/// G0: reads `dev/.env.local` (dev marker), refuses non-local hosts, and checks the Lidarr dev marker
/// (`instanceName == "magpie-dev-lidarr"`) and the bootstrap root folders before any write.
enum TryDevStack {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MAGPIE_IT"] == "1" }
    static let devInstanceName = "magpie-dev-lidarr"
    static let devRoots: Set<String> = ["/music/library", "/music/samples"]

    struct NotDevStack: Error, CustomStringConvertible { var description: String }

    static func client() async throws -> LidarrClient {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("dev/.env.local"), encoding: .utf8)
        guard text.contains("Magpie dev stack") else { throw NotDevStack(description: "dev/.env.local lacks the dev marker") }
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { env[parts[0]] = parts[1] }
        }
        guard let url = env["LIDARR_URL"].flatMap(URL.init(string:)), let key = env["LIDARR_API_KEY"],
              let host = url.host, ["127.0.0.1", "localhost"].contains(host) else {
            throw NotDevStack(description: "LIDARR_URL missing or not local")
        }
        let client = LidarrClient(base: url, apiKey: key, transport: URLSessionTransport())
        let status = try await client.status()
        let roots = Set(try await client.rootFolders().map(\.path))
        guard status.instanceName == devInstanceName, roots == devRoots else {
            throw NotDevStack(description: "not the dev stack's Lidarr (instance \(status.instanceName))")
        }
        return client
    }
}

@Suite(.enabled(if: TryDevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct TryIT {
    /// Judie Tzuke, "Harbour Lights": an artist the dev stack's Lidarr doesn't have (fixture-independent).
    static let recording = MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d")!
    static let artist = MBID("64db764c-2251-4f95-aa40-10fc91d509d8")!

    @Test func fallbackOnDevStack() async throws {
        let client = try await TryDevStack.client()
        let mb = MusicBrainzClient(transport: URLSessionTransport())

        // The external metadata (Lidarr's metadata server and MusicBrainz) must answer, else SKIP.
        let lookup: JSONValue?
        do {
            lookup = try await client.artistLookupJSON(mbid: Self.artist)
            _ = try await mb.recording(Self.recording)
        } catch {
            print("SKIP TryIT.fallbackOnDevStack: external metadata server unreachable (\(error))")
            return
        }
        guard lookup != nil else {
            print("SKIP TryIT.fallbackOnDevStack: Lidarr's metadata server doesn't know the test artist")
            return
        }
        try #require(try await client.artists().first { $0.foreignArtistId == Self.artist } == nil,
                     "the dev Lidarr already has the test artist; remove it (it was left by an earlier run)")

        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-tryit-\(UUID().uuidString)")
        let suite = "magpie-tryit-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite)
        await gate.setEnabled(true)
        let provisioned = try await Provisioner().ensure(gate: gate, client: client)
        let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: provisioned.fastStartProfileId,
                                        metadataProfileId: provisioned.findsMetadataProfileId,
                                        tagIds: [provisioned.magpieTagId])
        let ledger = Ledger(fileURL: dir.appending(path: "ledger.json"))
        let runner = RequestRunner(
            lidarr: client, gate: gate, ledger: ledger, mb: mb,
            library: LibraryAccess(startScan: {}, isScanning: { false }, refreshIndex: {}, songId: { _ in nil }),
            store: RequestStore(fileURL: dir.appending(path: "requests.json")), setup: { setup })

        let id = try await runner.tryRecording(
            ExternalRecording(recordingMBID: Self.recording, title: "Harbour Lights", artist: "Judie Tzuke", source: .listenBrainz),
            tier: .patient)
        await runner.settle()

        var createdArtistId: Int?
        do {
            var request = try #require(await runner.requests.first { $0.id == id })
            // Lidarr refreshes the new artist asynchronously; the album shows up shortly. A transient outage
            // (MusicBrainz or the metadata server busy) makes the request wait and retry after a minute.
            for _ in 0..<90 where request.albumId == nil {
                try await Task.sleep(for: .seconds(2))
                await runner.tick()
                request = try #require(await runner.requests.first { $0.id == id })
                if request.addSent { createdArtistId = request.lidarrArtistId }
            }
            if request.addSent { createdArtistId = request.lidarrArtistId }
            #expect(request.state == .searching, "state: \(request.state)")
            let artistId = try #require(request.lidarrArtistId)
            let albumId = try #require(request.albumId, "the album never appeared in Lidarr")
            let rg = try #require(request.plan?.releaseGroupMBID)
            // `albumsToMonitor` is applied when Lidarr's refresh of the new artist finishes.
            try await Self.waitForRefresh(client)

            let artist = try await client.json("artist/\(artistId)")
            #expect(artist["rootFolderPath"]?.stringValue?.hasPrefix("/music/library") == true)
            #expect(artist["qualityProfileId"]?.intValue == provisioned.fastStartProfileId)
            #expect(artist["metadataProfileId"]?.intValue == provisioned.findsMetadataProfileId)
            #expect(artist["tags"]?.arrayValue?.compactMap(\.intValue) == [provisioned.magpieTagId])
            #expect(artist["monitorNewItems"]?.stringValue == "none")
            #expect(artist["monitored"]?.boolValue == true, "an unmonitored artist would never be searched")
            let albums = try await client.albums(artistId: artistId)
            #expect(albums.first { $0.id == albumId }?.monitored == true)
            #expect(albums.first { $0.id == albumId }?.foreignAlbumId == rg)
            #expect(albums.filter(\.monitored).map(\.id) == [albumId], "only the one release group is monitored")
            let entry = try #require(try await ledger.entry(albumId: albumId))
            #expect(entry.createdArtist && !entry.wasMonitoredBefore && entry.mode == .fallback)

            // Cancel unmonitors what Magpie monitored (G6) and deletes nothing.
            await runner.cancel(id)
            await runner.tick()
            #expect(try await client.albums(artistId: artistId).first { $0.id == albumId }?.monitored == false)
            #expect(try await client.artists().contains { $0.id == artistId })
            #expect(await gate.changeLog().allSatisfy { $0.method != "DELETE" })
        } catch {
            Issue.record(error)
        }

        // Clean up: only the artist Magpie created, through the gate's one allowed delete shape. Not while
        // Lidarr is still refreshing it (a refresh in flight re-creates a deleted artist).
        if let createdArtistId {
            try await Self.waitForRefresh(client)
            _ = try await gate.send("DELETE", "artist/\(createdArtistId)?deleteFiles=false&addImportListExclusion=false",
                                    body: nil)
        }
    }

    /// Waits (up to 2 minutes) until Lidarr has no artist refresh queued or running.
    static func waitForRefresh(_ client: LidarrClient) async throws {
        for _ in 0..<60 {
            let busy = try await client.commands().contains { c in
                c.name.lowercased() == "refreshartist" && ["queued", "started"].contains(c.status.lowercased())
            }
            if !busy { return }
            try await Task.sleep(for: .seconds(2))
        }
        Issue.record("Lidarr kept refreshing the artist for 2 minutes")
    }
}
