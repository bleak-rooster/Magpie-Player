import Foundation
import Testing
import MagpieCore
import ListenBrainzKit
import NavidromeKit
@testable import LidarrKit
@testable import Requests

/// Keep and Not for me against the dev stack (writes, and Not for me deletes files!). Run via `scripts/it.sh` (MAGPIE_IT=1). G0 as in `TryIT`: the dev
/// marker, local hosts only, the Lidarr dev instance name and the bootstrap root folders before any write.
///
/// A Finds-mode Try adds the test artist into `/music/samples`; a fixture single is manual-imported as the
/// song's track (fixture set-up, see `devManualImport`); the find becomes ready in the Finds library. Keep moves
/// it, and the song must show up under `/music/library` in Navidrome's main library. Not for me deletes it: the
/// file leaves the disk, the album is unmonitored and the (now empty) artist is removed without deleting files.
@Suite(.serialized, .enabled(if: TryDevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct FindsIT {
    @Test func keepMovesOnDevStack() async throws {
        try await TryDevStack.exclusive { try await run(letGo: false) }
    }

    @Test func notForMeDeletesOnDevStack() async throws {
        try await TryDevStack.exclusive { try await run(letGo: true) }
    }

    /// The fixture single (Samples, "Kites Over Lagos – Paper Planes"), copied into the downloads folder.
    static let fixture = "dev/data/music/samples/Kites Over Lagos/Paper Planes (2024)/01 - Paper Planes.mp3"

    private func run(letGo: Bool) async throws {
        let client = try await TryDevStack.client()
        let mb = MusicBrainzClient(transport: URLSessionTransport())
        do {
            guard try await client.artistLookupJSON(mbid: TryIT.artist) != nil else {
                print("SKIP FindsIT: Lidarr's metadata server doesn't know the test artist")
                return
            }
            _ = try await mb.recording(TryIT.recording)
        } catch {
            print("SKIP FindsIT: external metadata server unreachable (\(error))")
            return
        }
        try #require(try await client.artists().first { $0.foreignArtistId == TryIT.artist } == nil,
                     "the dev Lidarr already has the test artist; remove it (it was left by an earlier run)")
        let fixture = TryDevStack.repoRoot.appending(path: Self.fixture)
        try #require(FileManager.default.fileExists(atPath: fixture.path), "run dev/bootstrap.sh (fixtures)")

        // Navidrome: one login for the whole test (it rate-limits /auth/login).
        let env = try TryDevStack.env()
        guard let ndURL = env["NAVIDROME_URL"].flatMap(URL.init(string:)), let host = ndURL.host,
              ["127.0.0.1", "localhost"].contains(host),
              let user = env["NAVIDROME_ADMIN_USER"], let password = env["NAVIDROME_ADMIN_PASSWORD"] else {
            throw TryDevStack.NotDevStack(description: "NAVIDROME_URL missing or not local")
        }
        let navidrome = NavidromeClient(endpoint: ServerEndpoint(bases: [ndURL]),
                                        credentials: NavidromeCredentials(username: user, password: password),
                                        transport: URLSessionTransport())
        _ = try await navidrome.connect()
        let libraries = try await navidrome.libraries()
        let main = try #require(libraries.first { $0.path == "/music/library" })
        let finds = try #require(libraries.first { $0.path == "/music/samples" })

        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-findsit-\(UUID().uuidString)")
        let suite = "magpie-findsit-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite)
        await gate.setEnabled(true)
        let provisioned = try await Provisioner().ensure(gate: gate, client: client)
        let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: provisioned.fastStartProfileId,
                                        metadataProfileId: provisioned.findsMetadataProfileId,
                                        tagIds: [provisioned.magpieTagId],
                                        finds: .init(rootFolderPath: "/music/samples",
                                                     tagIds: [provisioned.magpieTagId, provisioned.findTagId]))
        let keepSetup = RequestRunner.KeepSetup(findsRoot: "/music/samples", mainRoot: "/music/library",
                                                losslessProfileId: provisioned.losslessProfileId,
                                                findTagId: provisioned.findTagId)
        let ledger = Ledger(fileURL: dir.appending(path: "ledger.json"), instance: client.instanceScope)
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
                // Same paths for Lidarr and Navidrome on the dev stack: the artist folder inside the main library.
                let folder = artistPath.split(separator: "/").last.map(String.init) ?? ""
                return try await navidrome.songs(recordingMBID: id, inLibrary: main.id, under: folder).first
            })
        let runner = RequestRunner(lidarr: client, gate: gate, ledger: ledger, mb: mb, library: library,
                                   store: RequestStore(fileURL: dir.appending(path: "requests.json")),
                                   setup: { setup }, keepSetup: { keepSetup })

        // Cleanup removes only the folders this test created (G0: never an owner-ish folder of the dev library).
        let musicRoot = TryDevStack.repoRoot.appending(path: "dev/data/music")
        func folders() -> [String: Set<String>] {
            Dictionary(uniqueKeysWithValues: ["library", "samples"].map { root in
                (root, Set((try? FileManager.default.contentsOfDirectory(atPath: musicRoot.appending(path: root).path)) ?? []))
            })
        }
        let before = folders()

        let id = try await runner.tryRecording(
            ExternalRecording(recordingMBID: TryIT.recording, title: "Harbour Lights", artist: "Judie Tzuke",
                              source: .listenBrainz),
            tier: .patient)
        await runner.settle()

        var createdArtistId: Int?
        var artistFolder: String?
        let downloads = TryDevStack.repoRoot.appending(path: "dev/data/downloads/magpie-findsit-\(UUID().uuidString)")
        do {
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
            artistFolder = try await client.artist(id: artistId).path
            #expect(artistFolder?.hasPrefix("/music/samples/") == true)

            // Fixture set-up: the single lands in the Finds folder as the song's track.
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture, to: downloads.appending(path: "01 - Harbour Lights.mp3"))
            try await Self.devManualImport(folder: "/downloads/\(downloads.lastPathComponent)", artistId: artistId,
                                           albumId: albumId, recording: TryIT.recording)
            let imported = try await client.trackFiles(albumId: albumId)
            #expect(!imported.isEmpty && imported.allSatisfy { $0.path.hasPrefix("/music/samples/") })

            // Navidrome lists it in the Finds library; the request becomes a ready find.
            try await navidrome.startScan(targets: ["\(finds.id):"])
            for _ in 0..<45 where request.state != .ready {
                try await Task.sleep(for: .seconds(2))
                await runner.tick()
                request = try #require(await runner.requests.first { $0.id == id })
            }
            try #require(request.state == .ready, "the find never showed up in Navidrome (state \(request.state))")
            let findSong = try #require(try await navidrome.songs(recordingMBID: TryIT.recording, excludingLibrary: nil).first)
            #expect(findSong.libraryId == finds.id)

            if letGo {
                try await notForMe(runner, id, client: client, gate: gate, ledger: ledger, artistId: artistId,
                                   albumId: albumId, navidrome: navidrome, findsLibrary: finds.id)
                if (try? await client.artist(id: artistId)) == nil { createdArtistId = nil }   // removed by Not for me
                throw Done()
            }

            // Keep.
            var outcome = try await runner.keep(id)
            for _ in 0..<60 where outcome == .stillMoving {
                try await Task.sleep(for: .seconds(2))
                outcome = try await runner.keep(id)
            }
            #expect(outcome == .moved)
            let kept = try await client.artist(id: artistId)
            artistFolder = kept.path
            #expect(kept.path?.hasPrefix("/music/library/") == true, "artist path: \(kept.path ?? "nil")")
            #expect(!kept.tags.contains(provisioned.findTagId))
            #expect(kept.qualityProfileId == provisioned.losslessProfileId)
            // On disk (Lidarr's filesystem): the find's folder left the Finds root and its files are in the new
            // folder. Lidarr 3.2 doesn't update the track file paths on a move, so those aren't checked.
            #expect(try await client.directories(in: "/music/samples").allSatisfy { !$0.hasSuffix("/Judie Tzuke") })
            if let newPath = kept.path, let albumDir = try await client.directories(in: newPath).first {
                #expect(try await client.files(in: albumDir).contains { $0.hasSuffix("Harbour Lights.mp3") })
            } else {
                Issue.record("no album folder in \(kept.path ?? "nil")")
            }
            #expect(try await ledger.entries.filter { $0.lidarrArtistId == artistId }.allSatisfy { $0.keptAt != nil })

            // The song is in the main library now, under its (re-resolved) id.
            for _ in 0..<30 where request.relinkPending != false {
                try await Task.sleep(for: .seconds(2))
                await runner.tick()
                request = try #require(await runner.requests.first { $0.id == id })
            }
            #expect(request.state == .kept)
            let librarySong = try #require(
                try await navidrome.songs(recordingMBID: TryIT.recording, excludingLibrary: finds.id).first,
                "the kept song isn't in the main library")
            #expect(librarySong.libraryId == main.id)
            #expect(request.songId == librarySong.id)
            #expect(await gate.changeLog().filter { $0.path == "/api/v1/artist/editor" }.count == 1, "one move")
        } catch is Done {
        } catch {
            Issue.record(error)
        }

        // Clean up: the artist Magpie created (files kept by Lidarr: deleteFiles=false), then its folder on the dev
        // data volume, then a scan so Navidrome lets the songs go.
        try? FileManager.default.removeItem(at: downloads)
        if let createdArtistId {
            try await TryIT.waitForRefresh(client)
            _ = try await gate.send("DELETE", "artist/\(createdArtistId)?deleteFiles=false&addImportListExclusion=false",
                                    body: nil)
        }
        _ = artistFolder
        var removed = false
        for (root, now) in folders() {
            for created in now.subtracting(before[root] ?? []) where !created.isEmpty && created != ".." && created != "." {
                try? FileManager.default.removeItem(at: musicRoot.appending(path: root).appending(path: created))
                removed = true
            }
        }
        if removed { try? await navidrome.startScan(target: nil) }
    }

    private struct Done: Error {}

    /// Not for me on the ready find: the confirm check says the files go for good (the dev stack has no recycle
    /// bin), then the file leaves the disk, the album is unmonitored and the empty artist is removed with
    /// deleteFiles=false&addImportListExclusion=false.
    private func notForMe(_ runner: RequestRunner, _ id: RequestID, client: LidarrClient, gate: LidarrWriteGate,
                          ledger: Ledger, artistId: Int, albumId: Int, navidrome: NavidromeClient,
                          findsLibrary: Int) async throws {
        let artist = try await client.artist(id: artistId)
        let path = try #require(artist.path)
        let files = try await client.trackFiles(albumId: albumId)
        try #require(!files.isEmpty)
        let check = try await runner.notForMeCheck(id)
        let recycleBin = try await client.recycleBin()
        #expect(check.permanent == (recycleBin == nil))
        var outcome = try await runner.notForMe(id, permanentConfirmed: check.permanent)
        for _ in 0..<30 where outcome == .stillGoing {
            try await Task.sleep(for: .seconds(2))
            outcome = try await runner.notForMe(id, permanentConfirmed: check.permanent)
        }
        #expect(outcome == .removed)
        let request = try #require(await runner.requests.first { $0.id == id })
        #expect(request.state == .dismissed && request.notForMe == nil && !request.notForMeNeedsAttention)
        // Gone from the disk (Lidarr's filesystem), not just from Lidarr's records.
        for file in files {
            let folder = (file.path as NSString).deletingLastPathComponent
            let present = try await client.files(in: folder)
            #expect(!present.contains(file.path), "still on disk: \(file.path)")
        }
        let log = await gate.changeLog().map { "\($0.method) \($0.path)" }
        #expect(log.filter { $0 == "DELETE /api/v1/trackfile/bulk" }.count == 1, "\(log)")
        #expect(log.contains("DELETE /api/v1/artist/\(artistId)?deleteFiles=false&addImportListExclusion=false"), "\(log)")
        #expect(!log.contains { $0.contains("deleteFiles=true") || $0.contains("addImportListExclusion=true") })
        do {
            _ = try await client.artist(id: artistId)
            Issue.record("the empty artist is still in Lidarr")
        } catch LidarrError.http(status: 404) {}
        let folderLeft = try await client.filesystemExists(path: path)
        let filesLeft = folderLeft ? try await client.contents(in: path).files : []
        #expect(filesLeft.isEmpty)
        // Navidrome lets the song go after the scan.
        for _ in 0..<15 {
            if try await navidrome.songs(recordingMBID: TryIT.recording, excludingLibrary: nil)
                .allSatisfy({ $0.libraryId != findsLibrary }) { return }
            try await Task.sleep(for: .seconds(2))
        }
        Issue.record("the find is still listed in the Finds library")
    }

    // MARK: - Fixture set-up (dev stack only)

    /// Imports the files in `folder` (a `/downloads` path) as the recording's track of the album, the way the
    /// owner would with Lidarr's manual import. Test set-up on the dev stack only (G0 checked by
    /// `TryDevStack.client()` first): `ManualImport` is deliberately not on the gate's allow list, so this goes
    /// straight to the dev Lidarr. Waits for the import to finish.
    static func devManualImport(folder: String, artistId: Int, albumId: Int, recording: MBID) async throws {
        let album = try await devLidarr("GET", "album/\(albumId)")
        let release = (album["releases"] as? [[String: Any]])?.first { $0["monitored"] as? Bool == true }
        let releaseId = try #require(release?["id"] as? Int, "the album has no monitored release")
        let tracks = try await devLidarr("GET", "track", query: ["albumId": "\(albumId)"], array: true)
        let rows = tracks["rows"] as? [[String: Any]] ?? []
        let track = try #require(rows.first { $0["foreignRecordingId"] as? String == recording.rawValue },
                                 "the album has no track for the recording")
        let candidates = try await devLidarr("GET", "manualimport", query: ["folder": folder, "artistId": "\(artistId)",
                                                                            "filterExistingFiles": "false"], array: true)
        let file = try #require((candidates["rows"] as? [[String: Any]])?.first, "manual import found no file")
        let command = try await devLidarr("POST", "command", body: [
            "name": "ManualImport", "importMode": "move", "replaceExistingFiles": false,
            "files": [[
                "path": file["path"] as Any, "artistId": artistId, "albumId": albumId, "albumReleaseId": releaseId,
                "trackIds": [track["id"] as Any], "quality": file["quality"] as Any, "indexerFlags": 0,
                "disableReleaseSwitching": false,
            ]],
        ])
        let commandId = try #require(command["id"] as? Int)
        for _ in 0..<60 {
            let status = try await devLidarr("GET", "command/\(commandId)")["status"] as? String ?? ""
            if status == "completed" { return }
            if ["failed", "aborted", "cancelled", "orphaned"].contains(status) {
                throw TryDevStack.NotDevStack(description: "manual import \(status)")
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw TryDevStack.NotDevStack(description: "manual import didn't finish")
    }

    /// A raw request to the dev Lidarr (after `TryDevStack.client()` verified it). Arrays come back as `rows`.
    static func devLidarr(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil,
                          array: Bool = false) async throws -> [String: Any] {
        let (base, key) = try TryDevStack.lidarrAccess()
        var components = URLComponents(url: base.appending(path: "api/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TryDevStack.NotDevStack(description: "\(method) \(path): HTTP \(status) \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        if array { return ["rows": json as? [Any] ?? []] }
        return json as? [String: Any] ?? [:]
    }
}
