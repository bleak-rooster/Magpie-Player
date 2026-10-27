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

    /// TryIT and FindsIT use the same test artist on the one dev Lidarr: never at the same time.
    static func exclusive(_ body: () async throws -> Void) async throws {
        await DevStackLock.shared.acquire()
        do { try await body() } catch {
            await DevStackLock.shared.release()
            throw error
        }
        await DevStackLock.shared.release()
    }

    /// `dev/.env.local`, refused without the dev marker.
    static func env() throws -> [String: String] {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("dev/.env.local"), encoding: .utf8)
        guard text.contains("Magpie dev stack") else { throw NotDevStack(description: "dev/.env.local lacks the dev marker") }
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { env[parts[0]] = parts[1] }
        }
        return env
    }

    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The dev Lidarr's address and key; refuses a non-local host (G0).
    static func lidarrAccess() throws -> (url: URL, key: String) {
        let env = try env()
        guard let url = env["LIDARR_URL"].flatMap(URL.init(string:)), let key = env["LIDARR_API_KEY"],
              let host = url.host, ["127.0.0.1", "localhost"].contains(host) else {
            throw NotDevStack(description: "LIDARR_URL missing or not local")
        }
        return (url, key)
    }

    /// MusicBrainz for the ITs (Task H1): the captured answer for the test recording, never musicbrainz.org (its
    /// 503s made the ITs flaky, and tests contact no outside service). The client and its limiter are the app's.
    static func musicBrainz() -> MusicBrainzClient { MusicBrainzClient(transport: FixtureMusicBrainz()) }

    static func client() async throws -> LidarrClient {
        let (url, key) = try lidarrAccess()
        let client = LidarrClient(base: url, apiKey: key, transport: URLSessionTransport())
        let status = try await client.status()
        let roots = Set(try await client.rootFolders().map(\.path))
        guard status.instanceName == devInstanceName, roots == devRoots else {
            throw NotDevStack(description: "not the dev stack's Lidarr (instance \(status.instanceName))")
        }
        return client
    }
}

/// Answers `GET ws/2/recording/<TryIT.recording>` from `Tests/Fixtures/musicbrainz`; refuses anything else. The
/// fixture was captured without `artist-credits`, so the credit (Judie Tzuke, `TryIT.artist`) is added here.
struct FixtureMusicBrainz: HTTPTransport {
    static let fixture = TryDevStack.repoRoot
        .appending(path: "Packages/MagpieKit/Tests/Fixtures/musicbrainz/recording-c2272a15.json")

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.host == MusicBrainzClient.base.host,
              url.path == "/ws/2/recording/\(TryIT.recording.rawValue)" else { throw URLError(.notConnectedToInternet) }
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? [String: Any])
        json["artist-credit"] = [["name": "Judie Tzuke", "artist": ["id": TryIT.artist.rawValue, "name": "Judie Tzuke"]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

actor DevStackLock {
    static let shared = DevStackLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

@Suite(.serialized, .enabled(if: TryDevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct TryIT {
    /// Judie Tzuke, "Harbour Lights": an artist the dev stack's Lidarr doesn't have (fixture-independent).
    static let recording = MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d")!
    static let artist = MBID("64db764c-2251-4f95-aa40-10fc91d509d8")!

    @Test func fallbackOnDevStack() async throws { try await tryOnDevStack(finds: false) }

    /// Task 6.2a: Finds mode adds the artist to the Finds root (`/music/samples`) with tags magpie + magpie-find.
    @Test func findsOnDevStack() async throws { try await tryOnDevStack(finds: true) }

    private func tryOnDevStack(finds: Bool) async throws {
        try await TryDevStack.exclusive { try await run(finds: finds) }
    }

    private func run(finds: Bool) async throws {
        let name = finds ? "findsOnDevStack" : "fallbackOnDevStack"
        let client = try await TryDevStack.client()
        let mb = TryDevStack.musicBrainz()

        // Lidarr's metadata server (asked by the dev Lidarr itself) must answer, else SKIP.
        let lookup: JSONValue?
        do {
            lookup = try await client.artistLookupJSON(mbid: Self.artist)
        } catch {
            print("SKIP TryIT.\(name): external metadata server unreachable (\(error))")
            return
        }
        guard lookup != nil else {
            print("SKIP TryIT.\(name): Lidarr's metadata server doesn't know the test artist")
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
                                        tagIds: [provisioned.magpieTagId],
                                        finds: finds ? .init(rootFolderPath: "/music/samples",
                                                             tagIds: [provisioned.magpieTagId, provisioned.findTagId]) : nil)
        let root = finds ? "/music/samples" : "/music/library"
        let tags = finds ? [provisioned.magpieTagId, provisioned.findTagId] : [provisioned.magpieTagId]
        let ledger = Ledger(fileURL: dir.appending(path: "ledger.json"), instance: client.instanceScope)
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
            #expect(artist["rootFolderPath"]?.stringValue?.hasPrefix(root) == true)
            #expect(artist["path"]?.stringValue?.hasPrefix(root + "/") == true)
            #expect(artist["qualityProfileId"]?.intValue == provisioned.fastStartProfileId)
            #expect(artist["metadataProfileId"]?.intValue == provisioned.findsMetadataProfileId)
            #expect(Set(artist["tags"]?.arrayValue?.compactMap(\.intValue) ?? []) == Set(tags))
            #expect(artist["monitorNewItems"]?.stringValue == "none")
            #expect(artist["monitored"]?.boolValue == true, "an unmonitored artist would never be searched")
            let albums = try await client.albums(artistId: artistId)
            #expect(albums.first { $0.id == albumId }?.monitored == true)
            #expect(albums.first { $0.id == albumId }?.foreignAlbumId == rg)
            #expect(albums.filter(\.monitored).map(\.id) == [albumId], "only the one release group is monitored")
            let entry = try #require(try await ledger.entry(albumId: albumId))
            #expect(entry.createdArtist && !entry.wasMonitoredBefore && entry.mode == (finds ? .finds : .fallback))
            #expect(request.isFind == finds)

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
