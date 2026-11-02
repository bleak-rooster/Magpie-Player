import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
import ListenBrainzKit
import NavidromeKit
@testable import LidarrKit
@testable import Requests

/// Y5 end to end on the dev stack (writes, and deletes files!). Run via `scripts/it.sh` (MAGPIE_IT=1). G0 as in
/// `TryIT`/`FindsIT`; creates the test artist (Judie Tzuke) and removes it, and only the folders it made.
///
/// Releases: the dev stack has no Soulseek or indexer, so each "release" arrives through Lidarr's manual import from
/// `/downloads` (`FindsIT.devManualImport`): the MP3 the find brings, and later a FLAC of the same track (Lidarr's
/// upgrade replaces the MP3, as the step-0 spike showed). Chaos: the phone's clock 10 minutes off Lidarr's, and the
/// app killed (the runner dropped and a new one built from the same files) between the Add and the deadline.
@Suite(.serialized, .enabled(if: TryDevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct FindFlowIT {
    /// Try → Find → Ready → Add → FLAC upgrade → "Lossless"; the MP3 is never deleted by Magpie. Phone clock +10 min.
    @Test func addThenLosslessUpgrade() async throws {
        try await TryDevStack.exclusive { try await run(.upgrade) }
    }

    /// Try → Find → Add → (app killed) → deadline: the MP3 is removed through the gate, the album stays monitored,
    /// "Waiting for a lossless copy" → the FLAC arrives → "Lossless".
    @Test func mp3RemovedAtTheDeadlineThenFLAC() async throws {
        try await TryDevStack.exclusive { try await run(.deadline) }
    }

    /// C1: a folder of the artist's name already in the main root: refused, nothing written, the owner's file untouched.
    @Test func collisionRefusesOnDevStack() async throws {
        try await TryDevStack.exclusive { try await run(.collision) }
    }

    enum Scenario { case upgrade, deadline, collision }

    struct Done: Error {}

    private func run(_ scenario: Scenario) async throws {
        let client = try await TryDevStack.client()
        do {
            guard try await client.artistLookupJSON(mbid: TryIT.artist) != nil else { print("SKIP FindFlowIT: metadata"); return }
        } catch {
            print("SKIP FindFlowIT: external metadata server unreachable (\(error))")
            return
        }
        try #require(try await client.artists().first { $0.foreignArtistId == TryIT.artist } == nil,
                     "the dev Lidarr already has the test artist; remove it")
        let fixture = TryDevStack.repoRoot.appending(path: FindsIT.fixture)
        try #require(FileManager.default.fileExists(atPath: fixture.path), "run dev/bootstrap.sh (fixtures)")

        let env = try TryDevStack.env()
        guard let ndURL = env["NAVIDROME_URL"].flatMap(URL.init(string:)), let host = ndURL.host,
              ["127.0.0.1", "localhost"].contains(host),
              let user = env["NAVIDROME_ADMIN_USER"], let password = env["NAVIDROME_ADMIN_PASSWORD"] else {
            throw TryDevStack.NotDevStack(description: "NAVIDROME_URL missing or not local")
        }
        let navidrome = NavidromeClient(endpoint: ServerEndpoint(bases: [ndURL]),
                                        credentials: NavidromeCredentials(username: user, password: password),
                                        transport: SharedLoginTransport())
        _ = try await navidrome.connect()
        let libraries = try await navidrome.libraries()
        let main = try #require(libraries.first { $0.path == "/music/library" })
        let finds = try #require(libraries.first { $0.path == "/music/samples" })

        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-findflowit-\(UUID().uuidString)")
        let suite = "magpie-findflowit-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite)
        await gate.setEnabled(true)
        let provisioned = try await Provisioner().ensure(gate: gate, client: client)
        let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: provisioned.fastStartProfileId,
                                        metadataProfileId: provisioned.findsMetadataProfileId, tagIds: [provisioned.magpieTagId],
                                        finds: .init(rootFolderPath: "/music/samples",
                                                     tagIds: [provisioned.magpieTagId, provisioned.findTagId]))
        let keepSetup = RequestRunner.KeepSetup(findsRoot: "/music/samples", mainRoot: "/music/library",
                                                losslessProfileId: provisioned.losslessProfileId, findTagId: provisioned.findTagId)
        let ledger = Ledger(fileURL: dir.appending(path: "ledger.json"), instance: client.instanceScope)
        let runnerBox = RunnerBox()
        let confinedGate = LidarrWriteGate(
            client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite,
            confinement: WriteConfinement(ledger: ledger, roots: {
                .init(mainRoot: keepSetup.mainRoot, findsRoot: keepSetup.findsRoot, findTagId: keepSetup.findTagId)
            }, liveRequests: { await runnerBox.runner?.liveRequestIds }))
        let library = LibraryAccess(
            startScan: { try await navidrome.startScan(target: nil) },
            isScanning: { try await navidrome.scanStatus() },
            refreshIndex: {},
            songId: { r in
                guard let id = r.recordingMBID else { return nil }
                return (try? await navidrome.songs(recordingMBID: id, excludingLibrary: nil))?.first?.id
            },
            rescanMoved: { _, to in
                let folder = to.split(separator: "/").last.map(String.init) ?? ""
                try await navidrome.startScan(targets: ["\(finds.id):", "\(main.id):\(folder)"])
            },
            keptSong: { id, artistPath in
                let folder = artistPath.split(separator: "/").last.map(String.init) ?? ""
                let songs = try await navidrome.songs(recordingMBID: id, inLibrary: main.id, under: folder)
                return songs.first { $0.suffix?.lowercased() == "flac" } ?? songs.first
            },
            scanFolder: { artistFolder in
                // Fix I7: the artist folder only (same paths on both servers on the dev stack).
                guard artistFolder.hasPrefix("/music/library/"), let folder = artistFolder.split(separator: "/").last else { return false }
                return (try? await navidrome.startScan(targets: ["\(main.id):\(folder)"])) != nil
            })
        // Chaos: the phone's clock 10 minutes ahead of Lidarr's (Lidarr's `Date` header corrects it, item 9.7).
        let skew: TimeInterval = scenario == .upgrade ? 600 : 0
        func makeRunner() -> RequestRunner {
            RequestRunner(lidarr: client, gate: confinedGate, ledger: ledger, mb: TryDevStack.musicBrainz(), library: library,
                          store: RequestStore(fileURL: dir.appending(path: "requests.json")),
                          setup: { setup }, keepSetup: { keepSetup }, now: { Date().addingTimeInterval(skew) })
        }
        var runner = makeRunner()
        runnerBox.runner = runner
        await runner.setMP3Grace(scenario == .deadline ? 20 : nil)

        let musicRoot = TryDevStack.repoRoot.appending(path: "dev/data/music")
        func folders() -> [String: Set<String>] {
            Dictionary(uniqueKeysWithValues: ["library", "samples"].map { root in
                (root, Set((try? FileManager.default.contentsOfDirectory(atPath: musicRoot.appending(path: root).path)) ?? []))
            })
        }
        let before = folders()
        let ownerFolder = musicRoot.appending(path: "library/Judie Tzuke")
        if scenario == .collision {
            try FileManager.default.createDirectory(at: ownerFolder, withIntermediateDirectories: true)
            try Data("owner".utf8).write(to: ownerFolder.appending(path: "owner.txt"))
        }

        let downloads = TryDevStack.repoRoot.appending(path: "dev/data/downloads/magpie-findflowit-\(UUID().uuidString)")
        var createdArtistId: Int?
        do {
            let id = try await runner.tryRecording(
                ExternalRecording(recordingMBID: TryIT.recording, title: "Harbour Lights", artist: "Judie Tzuke",
                                  source: .listenBrainz), tier: .patient)
            await runner.settle()
            var request = try #require(await runner.requests.first { $0.id == id })
            for _ in 0..<90 where request.albumId == nil {
                try await Task.sleep(for: .seconds(2))
                await runner.tick()
                request = try #require(await runner.requests.first { $0.id == id })
                if request.addSent { createdArtistId = request.lidarrArtistId }
            }
            if request.addSent { createdArtistId = request.lidarrArtistId }
            let artistId = try #require(request.lidarrArtistId)
            let albumId = try #require(request.albumId, "the album never appeared in Lidarr")
            try await TryIT.waitForRefresh(client)

            // The MP3 "release".
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture, to: downloads.appending(path: "01 - Harbour Lights.mp3"))
            try await FindsIT.devManualImport(folder: "/downloads/\(downloads.lastPathComponent)", artistId: artistId,
                                              albumId: albumId, recording: TryIT.recording)
            try await navidrome.startScan(targets: ["\(finds.id):"])
            for _ in 0..<45 where request.state != .ready {
                try await Task.sleep(for: .seconds(2))
                await runner.tick()
                request = try #require(await runner.requests.first { $0.id == id })
            }
            try #require(request.state == .ready, "the find never showed up (state \(request.state))")

            if scenario == .collision {
                let writes = await confinedGate.changeLog().count
                await #expect(throws: RequestRunner.KeepError.collision) { _ = try await runner.keep(id) }
                #expect(await confinedGate.changeLog().count == writes, "nothing written")
                #expect(try await client.artist(id: artistId).path?.hasPrefix("/music/samples/") == true)
                #expect(try String(contentsOf: ownerFolder.appending(path: "owner.txt"), encoding: .utf8) == "owner")
                #expect(try await ledger.entries.filter { $0.lidarrArtistId == artistId }.allSatisfy { !$0.isKeptOrKeeping })
                throw Done()
            }

            // Add to your library.
            var outcome = try await runner.keep(id)
            for _ in 0..<60 where outcome == .stillMoving || outcome == .queued {
                try await Task.sleep(for: .seconds(2))
                outcome = try await runner.keep(id)
            }
            #expect(outcome == .moved)
            request = try #require(await runner.requests.first { $0.id == id })
            #expect(request.state == .kept && request.lossless?.autoDelete == true)
            #expect(try await ledger.entries.filter { $0.lidarrArtistId == artistId }.allSatisfy(\.isConfirmedKept))
            let recorded = try await ledger.entries.first { $0.lidarrArtistId == artistId }?.findFiles ?? []
            #expect(recorded.count == 1 && recorded.first?.quality?.hasPrefix("MP3") == true)
            let log = await confinedGate.changeLog().map { "\($0.method) \($0.path)" }
            #expect(log.contains("POST /api/v1/command"), "the lossless search: \(log)")
            if scenario == .upgrade {
                // Lidarr's clock corrected the phone's (+10 min): the deadline is 7 days in Lidarr's time.
                let deadline = try #require(request.lossless?.deadline)
                #expect(abs(deadline.timeIntervalSince(Date().addingTimeInterval(RequestRunner.mp3Grace))) < 120)
            }

            if scenario == .deadline {
                // Chaos: the app is killed and relaunched before the deadline.
                await runner.stop()
                runner = makeRunner()
                runnerBox.runner = runner
                await runner.setMP3Grace(20)
                #expect(await runner.load())
                try await Task.sleep(for: .seconds(25))
                for _ in 0..<12 {
                    request = try #require(await runner.requests.first { $0.id == id })
                    if request.lossless?.removedAt != nil || request.mp3NeedsAttention { break }
                    // Throttled to every 5 minutes: let the next pass check now.
                    await runner.forceLosslessCheck(id)
                    await runner.tick()
                    try await Task.sleep(for: .seconds(2))
                }
                request = try #require(await runner.requests.first { $0.id == id })
                #expect(request.lossless?.removedAt != nil && !request.mp3NeedsAttention, "removed: \(String(describing: request.lossless))")
                #expect(try await client.trackFiles(albumId: albumId).isEmpty, "the MP3 is gone")
                #expect(try await client.albums(artistId: artistId).first { $0.id == albumId }?.monitored == true)
                let deletes = await confinedGate.changeLog().filter { $0.method == "DELETE" }
                #expect(deletes.count == 1 && deletes.first?.path.contains("trackfile") == true)
            }

            // The FLAC "release": Lidarr's upgrade.
            let flacFolder = downloads.appending(path: "flac")
            try FileManager.default.createDirectory(at: flacFolder, withIntermediateDirectories: true)
            try Self.ffmpegFLAC(from: fixture, to: flacFolder.appending(path: "01 - Harbour Lights.flac"))
            try await FindsIT.devManualImport(folder: "/downloads/\(downloads.lastPathComponent)/flac", artistId: artistId,
                                              albumId: albumId, recording: TryIT.recording)
            for _ in 0..<90 {   // Navidrome's scan of the new file can take a while
                await runner.forceLosslessCheck(id)
                await runner.tick()
                request = try #require(await runner.requests.first { $0.id == id })
                if request.lossless?.losslessAt != nil, request.relinkPending == false { break }
                try await Task.sleep(for: .seconds(3))
            }
            #expect(request.lossless?.losslessAt != nil, "lossless: \(String(describing: request.lossless))")
            let listed = try await navidrome.songs(recordingMBID: TryIT.recording, excludingLibrary: nil).map { "\($0.id) \($0.suffix ?? "?") lib \($0.libraryId ?? -1)" }
            #expect(request.songSuffix?.lowercased() == "flac",
                    "suffix \(request.songSuffix ?? "nil") relink \(String(describing: request.relinkPending)) to \(request.movedTo ?? "nil") listed \(listed)")
            let files = try await client.trackFiles(albumId: albumId)
            #expect(files.count == 1 && files.allSatisfy { $0.quality?.hasPrefix("FLAC") == true }, "\(files)")
            if scenario == .upgrade {
                #expect(await confinedGate.changeLog().allSatisfy { $0.method != "DELETE" }, "Magpie deleted nothing")
            }
        } catch is Done {
        } catch {
            Issue.record(error)
        }

        await runner.stop()
        try? FileManager.default.removeItem(at: downloads)
        if let createdArtistId {
            try await TryIT.waitForRefresh(client)
            _ = try await FindsIT.devLidarr("DELETE", "artist/\(createdArtistId)",
                                            query: ["deleteFiles": "false", "addImportListExclusion": "false"])
        }
        var removed = false
        for (root, now) in folders() {
            for created in now.subtracting(before[root] ?? []) where !created.isEmpty && created != ".." && created != "." {
                try? FileManager.default.removeItem(at: musicRoot.appending(path: root).appending(path: created))
                removed = true
            }
        }
        if scenario == .collision { try? FileManager.default.removeItem(at: ownerFolder); removed = true }
        if removed { try? await navidrome.startScan(target: nil) }
    }

    static func ffmpegFLAC(from: URL, to: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ffmpeg", "-loglevel", "error", "-y", "-i", from.path, "-c:a", "flac", to.path]
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0, "ffmpeg failed")
    }
}

final class RunnerBox: @unchecked Sendable {
    var runner: RequestRunner?
}
