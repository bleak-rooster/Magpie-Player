import Foundation
import Testing
import MagpieCore
import ListenBrainzKit
@testable import LidarrKit
@testable import Requests

/// Round 20 (R20-IT): a Try that really grabs, downloads and imports, on the dev stack (`MAGPIE_IT=1 MAGPIE_LIVE=1`,
/// after `dev/fake-indexer/setup.sh`). The dev Lidarr searches the fake Newznab indexer (`dev/fake-indexer/server.py`),
/// sends the NZB to the "Magpie Blackhole" client, and this test plays the downloader (`Completer`): each NZB becomes a
/// finished folder of tagged MP3s in the watch folder, which Lidarr's completed-download handling imports (or blocks).
/// Real MusicBrainz, writes to the dev Lidarr only (G0 as TryIT). Each run prints a timeline: the request's state, note
/// and the release asked for at every change, with Lidarr's queue and history and what the indexer was asked.
///
/// The song: Lorde – "Solar Power". Its title is also a studio album's (2021-08-20) and a Single's (2021-06-10), one
/// recording on both, same year: a release named "Lorde - Solar Power (2021)" can be either.
@Suite(.enabled(if: TryDevStack.enabled && ProcessInfo.processInfo.environment["MAGPIE_LIVE"] == "1"), .serialized)
struct DownloadFlowIT {
    static let recording = MBID("24de5592-9e9d-406e-ba52-cc658b5ec13e")!
    static let artist = MBID("8e494408-8620-4c6a-82c2-c2ca4a1e4f12")!
    static let singleGroup = MBID("1fcb9367-8ad0-4e82-b31a-7b9636c558d0")!
    static let albumGroup = MBID("c274479c-df3f-4566-b09f-04a82063219c")!
    static let song = ExternalRecording(recordingMBID: recording, title: "Solar Power", artist: "Lorde", source: .listenBrainz)

    /// a. The indexer offers the right release for whatever is searched (title filled in from the search).
    @Test func happyPath() async throws {
        try await TryDevStack.exclusive {
            try await Flow.run("a HAPPY", limit: 15 * 60, releases: [
                .init(title: "{artist} - {album} (2021) [MP3 320]", size: 6_000_000),
            ]) { flow, id in
                let r = try await flow.untilDone(id)
                #expect(r.state == .ready, "a: \(r.state) (\(r.note ?? "no note"))")
            }
        }
    }

    /// b. Any search naming the title is answered only with the whole studio album (12 files).
    @Test func titleTrackOnlyAsTheAlbum() async throws {
        try await TryDevStack.exclusive {
            try await Flow.run("b TITLE TRACK", limit: 25 * 60, releases: [
                .init(title: "Lorde - Solar Power (2021) [MP3 320]", size: 100_000_000, match: ["solar power"]),
            ], filesFrom: [Self.albumGroup]) { flow, id in
                let r = try await flow.untilDone(id)
                #expect(r.state == .ready, "b: the song never became ready: \(r.state) (\(r.note ?? "no note"))")
            }
        }
    }

    /// c. Stop during a slow search: the artist must stay while Lidarr's search for its album still runs, and once
    /// everything is cleaned up nothing for that album is downloading or imported.
    @Test func stopDuringSearch() async throws {
        try await TryDevStack.exclusive {
            try await Flow.run("c STOP DURING SEARCH", limit: 5 * 60, releases: [
                .init(title: "{artist} - {album} (2021) [MP3 320]", size: 6_000_000, delaySeconds: 90),
            ]) { flow, id in
                var r = try await flow.until(id) { $0.searchCommandId != nil || $0.state.isTerminal }
                let command = try #require(r.searchCommandId, "the AlbumSearch was never sent: \(r.state)")
                // Until the indexer has been asked, the search can't be "still running" in the sense that matters.
                try await flow.untilIndexerAsked()
                #expect(try await flow.commandRunning(command), "the search finished before Stop: lower the delay?")
                flow.log("STOP (runner.cancel) while AlbumSearch \(command) runs")
                await flow.runner.cancel(id)
                var removedDuringSearch = false
                let stopAt = Date()
                while Date().timeIntervalSince(stopAt) < 5 * 60 {
                    await flow.runner.tick()
                    try await flow.complete()
                    r = try #require(await flow.runner.requests.first { $0.id == id })
                    let running = try await flow.commandRunning(command)
                    let exists = try await flow.artistId() != nil
                    if running && !exists { removedDuringSearch = true }
                    try await flow.snapshot(r, extra: "search \(running ? "running" : "done") artist \(exists ? "kept" : "removed")")
                    try await Task.sleep(for: .seconds(3))
                }
                #expect(!removedDuringSearch, "c: the artist was removed while Lidarr's search for its album still ran")
                let queued = try await flow.queueTitles(allArtists: true).filter { $0.localizedCaseInsensitiveContains("Solar Power") }
                #expect(queued.isEmpty, "c: still in Lidarr's queue after clean-up: \(queued)")
                let imported = try await flow.importedFiles()
                #expect(imported.isEmpty, "c: imported after Stop: \(imported)")
            }
        }
    }
}

/// One scenario's world: the runner, the indexer's table, the completer, the timeline and the clean-up.
final class Flow: @unchecked Sendable {
    let name: String
    let client: LidarrClient
    let runner: RequestRunner
    let started = Date()
    let completer: Completer
    private var lastLine = ""

    struct Release: Encodable {
        var title: String, size: Int
        var match: [String] = []
        var delaySeconds: Double = 0
    }

    private init(name: String, client: LidarrClient, runner: RequestRunner, completer: Completer) {
        self.name = name; self.client = client; self.runner = runner; self.completer = completer
    }

    /// Sets up the stack for one scenario, runs `body`, prints the timeline and cleans up whatever happened.
    static func run(_ name: String, limit: TimeInterval, releases: [Release], filesFrom: [MBID] = [],
                    _ body: (Flow, RequestID) async throws -> Void) async throws {
        let client = try await TryDevStack.client()
        try await FakeIndexer.check()
        let mb = MusicBrainzClient(transport: URLSessionTransport(timeout: 20), userAgent: MusicBrainzClient.userAgent(version: "it"))
        try await verifyCatalogue(mb)
        try #require(try await client.artists().first { $0.foreignArtistId == DownloadFlowIT.artist } == nil,
                     "the dev Lidarr already has Lorde; remove it (left by an earlier run?)")
        try FakeIndexer.reset()
        try FakeIndexer.add(releases)

        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-download-\(UUID().uuidString)")
        let suite = "magpie-download-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let plainGate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite)
        await plainGate.setEnabled(true)
        let provisioned = try await Provisioner().ensure(gate: plainGate, client: client)
        let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: provisioned.fastStartProfileId,
                                        metadataProfileId: provisioned.findsMetadataProfileId, tagIds: [provisioned.magpieTagId],
                                        finds: .init(rootFolderPath: "/music/samples",
                                                     tagIds: [provisioned.magpieTagId, provisioned.findTagId]))
        let keep = RequestRunner.KeepSetup(findsRoot: "/music/samples", mainRoot: "/music/library",
                                           losslessProfileId: provisioned.losslessProfileId, findTagId: provisioned.findTagId)
        let ledger = Ledger(fileURL: dir.appending(path: "ledger.json"), instance: client.instanceScope)
        let gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite,
                                   confinement: WriteConfinement(ledger: ledger, roots: {
                                       .init(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: provisioned.findTagId)
                                   }))
        // "In the library" here means Lidarr has a file for the recording: the dev stack's Navidrome isn't asked.
        let library = LibraryAccess(startScan: {}, isScanning: { false }, refreshIndex: {}, songId: { r in
            guard let mbid = r.recordingMBID else { return nil }
            return try? await Flow.lidarrSong(recording: mbid)
        })
        let runner = RequestRunner(lidarr: client, gate: gate, ledger: ledger, mb: mb, library: library,
                                   store: RequestStore(fileURL: dir.appending(path: "requests.json")), setup: { setup },
                                   // As the app: where Keep moves finds, which also lets a stopped find's late import be
                                   // proven Magpie's and removed (D161).
                                   keepSetup: { keep })
        let completer = try Completer(filesFrom: filesFrom)
        let flow = Flow(name: name, client: client, runner: runner, completer: completer)
        flow.limit = limit
        let musicBefore = HostFiles.musicFolders()

        flow.log("Try “\(DownloadFlowIT.song.title)” by \(DownloadFlowIT.song.artist); indexer offers \(releases.map(\.title))")
        do {
            let id = try await runner.tryRecording(DownloadFlowIT.song, tier: .standard)
            await runner.settle()
            try await body(flow, id)
            await runner.cancel(id)   // nothing more from Magpie for this one
            await runner.tick()
        } catch {
            Issue.record(error)
        }
        await flow.printSummary()
        await flow.cleanUp(musicBefore: musicBefore)
    }

    var limit: TimeInterval = 600

    // MARK: Driving

    /// Ticks (and plays the downloader) until the request is ready or finished, or the scenario's time is up.
    func untilDone(_ id: RequestID) async throws -> MagpieRequest {
        try await until(id) { $0.state == .ready || $0.state.isTerminal }
    }

    func until(_ id: RequestID, _ done: (MagpieRequest) -> Bool) async throws -> MagpieRequest {
        var r = try #require(await runner.requests.first { $0.id == id })
        while !done(r) {
            if Date().timeIntervalSince(started) > limit {
                log("TIME UP after \(Int(limit)) s")
                break
            }
            try await Task.sleep(for: .seconds(3))
            await runner.tick()
            try await complete()
            r = try #require(await runner.requests.first { $0.id == id })
            try await snapshot(r)
        }
        try await snapshot(r, force: true)
        if r.state == .ready { log("READY after \(Int(Date().timeIntervalSince(started))) s") }
        return r
    }

    /// Waits (up to 60 s) until the indexer has been asked something since the scenario began.
    func untilIndexerAsked() async throws {
        for _ in 0..<60 {
            if try !FakeIndexer.log().queries.isEmpty { return }
            try await Task.sleep(for: .seconds(1))
        }
    }

    func complete() async throws {
        for line in try await completer.step(artistId: artistId()) { log(line) }
    }

    func commandRunning(_ id: Int) async throws -> Bool {
        ["queued", "started"].contains(try await client.command(id: id).status.lowercased())
    }

    // MARK: Reading Lidarr (dev only, G0 in devLidarr)

    func artistId() async throws -> Int? {
        try await client.artists().first { $0.foreignArtistId == DownloadFlowIT.artist }?.id
    }

    /// The library's "song id" for this test: Lidarr's track with a file for the recording.
    static func lidarrSong(recording: MBID) async throws -> String? {
        let artists = try await FindsIT.devLidarr("GET", "artist", array: true)["rows"] as? [[String: Any]] ?? []
        guard let artistId = artists.first(where: { $0["foreignArtistId"] as? String == DownloadFlowIT.artist.rawValue })?["id"] as? Int
        else { return nil }
        let tracks = try await FindsIT.devLidarr("GET", "track", query: ["artistId": "\(artistId)"], array: true)["rows"] as? [[String: Any]] ?? []
        let track = tracks.first { $0["foreignRecordingId"] as? String == recording.rawValue && $0["hasFile"] as? Bool == true }
        return (track?["id"] as? Int).map { "lidarr-track-\($0)" }
    }

    func queueTitles(allArtists: Bool = false) async throws -> [String] {
        let page = try await FindsIT.devLidarr("GET", "queue", query: [
            "page": "1", "pageSize": "100", "includeUnknownArtistItems": "true", "includeAlbum": "true",
        ])
        let rows = page["records"] as? [[String: Any]] ?? []
        return rows.map { row in
            let msgs = (row["statusMessages"] as? [[String: Any]] ?? []).flatMap { $0["messages"] as? [String] ?? [] }
            let album = (row["album"] as? [String: Any]).map { "\($0["albumType"] as? String ?? "?") “\($0["title"] as? String ?? "?")”" } ?? "no album"
            return "\(row["title"] as? String ?? "?") → \(album) [\(row["status"] as? String ?? "?")/\(row["trackedDownloadState"] as? String ?? "?")]"
                + (msgs.isEmpty ? "" : " \(msgs.joined(separator: "; "))")
        }
    }

    func history() async throws -> [String] {
        guard let artistId = try await artistId() else { return [] }
        let rows = try await FindsIT.devLidarr("GET", "history/artist", query: ["artistId": "\(artistId)"], array: true)["rows"] as? [[String: Any]] ?? []
        return rows.reversed().map { "\($0["eventType"] as? String ?? "?"): \($0["sourceTitle"] as? String ?? "?")" }
    }

    func importedFiles() async throws -> [String] {
        var files = HostFiles.newFiles(since: musicSnapshot)
        if let artistId = try await artistId() {
            files += try await client.trackFiles(artistId: artistId).map(\.path)
        }
        return Array(Set(files)).sorted()
    }

    private var musicSnapshot = HostFiles.musicFolders()
    private var albumsById: [Int: String] = [:]

    // MARK: Timeline

    func log(_ text: String) {
        print("[DownloadFlowIT \(name)] +\(String(format: "%4d", Int(Date().timeIntervalSince(started))))s \(text)")
    }

    func snapshot(_ r: MagpieRequest, extra: String = "", force: Bool = false) async throws {
        var asked = r.albumTitle.map { "“\($0)”" } ?? "nothing yet"
        if let albumId = r.albumId {
            if albumsById[albumId] == nil, let artistId = r.lidarrArtistId {
                for a in (try? await client.albums(artistId: artistId)) ?? [] {
                    albumsById[a.id] = "\(a.albumType ?? "?") “\(a.title)”\(a.monitored ? " monitored" : "")"
                }
            }
            asked = "\(albumsById[albumId] ?? asked) (album \(albumId))"
        }
        let queue = (try? await queueTitles()) ?? []
        let history = (try? await history()) ?? []
        let queries = (try? FakeIndexer.log().queries.count) ?? 0
        let line = "state \(r.state) | note \(r.note ?? "-") | asked \(asked)\(r.grabbed ? " | grabbed" : "")"
            + " | queue \(queue) | history \(history) | indexer asked \(queries)×\(extra.isEmpty ? "" : " | \(extra)")"
        if force || line != lastLine { log(line) }
        lastLine = line
    }

    func printSummary() async {
        if let entries = try? FakeIndexer.log() {
            for q in entries.queries {
                log("indexer query t=\(q.t) artist=\(q.artist ?? "-") album=\(q.album ?? "-") q=\(q.q ?? "-") → \(q.matched.count) release(s)"
                    + " (delay \(Int(q.delaySeconds)) s, answered \(q.end.map { "after \(Int($0 - q.start)) s" } ?? "never"))")
            }
            for g in entries.grabs { log("NZB fetched: \(g.title ?? g.id)") }
        }
    }

    // MARK: Clean-up

    /// Only what this scenario made: the indexer's table, the artist (deleteFiles=false, once Lidarr has stopped
    /// refreshing it), the blackhole folders it wrote and the new folders under the dev music roots.
    func cleanUp(musicBefore: HostFiles.Folders) async {
        try? FakeIndexer.reset()
        do {
            if let artistId = try await artistId() {
                try await PopularSinglesDevStackIT.settled(client)
                _ = try await FindsIT.devLidarr("DELETE", "artist/\(artistId)",
                                                query: ["deleteFiles": "false", "addImportListExclusion": "false"])
                log("clean-up: removed the artist (files kept by Lidarr, removed from disk below)")
            }
        } catch {
            Issue.record(error)
        }
        completer.cleanUp()
        HostFiles.removeNewFolders(since: musicBefore)
    }
}

/// The fake indexer's control API (dev/fake-indexer/server.py). Reads go through URLSession; the two control writes
/// go through curl, so no test here sets a write method on a request (scripts/check-writes.sh, G1).
enum FakeIndexer {
    static var base: URL {
        URL(string: ProcessInfo.processInfo.environment["FAKE_INDEXER_URL"] ?? "http://127.0.0.1:3903")!
    }

    struct Log: Decodable {
        struct Query: Decodable {
            var t: String, q: String?, artist: String?, album: String?
            var matched: [String], delaySeconds: Double, start: Double, end: Double?
        }
        struct Grab: Decodable { var id: String, title: String? }
        var queries: [Query], grabs: [Grab]
    }

    static func check() async throws {
        guard ["127.0.0.1", "localhost"].contains(base.host ?? "") else {
            throw TryDevStack.NotDevStack(description: "FAKE_INDEXER_URL must be local")
        }
        guard (try? Data(contentsOf: base.appending(path: "control/ping"))) != nil else {
            throw TryDevStack.NotDevStack(description: "the fake indexer isn't answering: run dev/fake-indexer/setup.sh")
        }
        let indexers = try await FindsIT.devLidarr("GET", "indexer", array: true)["rows"] as? [[String: Any]] ?? []
        let clients = try await FindsIT.devLidarr("GET", "downloadclient", array: true)["rows"] as? [[String: Any]] ?? []
        guard indexers.contains(where: { $0["name"] as? String == "Magpie Fake Indexer" }),
              clients.contains(where: { $0["name"] as? String == "Magpie Blackhole" }) else {
            throw TryDevStack.NotDevStack(description: "the dev Lidarr has no fake indexer or blackhole: run dev/fake-indexer/setup.sh")
        }
    }

    static func log() throws -> Log {
        try JSONDecoder().decode(Log.self, from: Data(contentsOf: base.appending(path: "control/log")))
    }

    static func reset() throws { try curl(["-X", "POST", base.appending(path: "control/reset").absoluteString]) }

    static func add(_ releases: [Flow.Release]) throws {
        let body = String(decoding: try JSONEncoder().encode(releases), as: UTF8.self)
        try curl(["-X", "POST", "-H", "Content-Type: application/json", "--data-binary", body,
                  base.appending(path: "control/releases").absoluteString])
    }

    private static func curl(_ args: [String]) throws {
        let out = try Shell.run("/usr/bin/curl", ["-fsS", "--max-time", "10"] + args)
        guard out.status == 0 else { throw TryDevStack.NotDevStack(description: "fake indexer control: \(out.text)") }
    }
}

/// Plays the download client: an NZB Lidarr dropped in the blackhole's NZB folder becomes a finished folder of MP3s
/// named like the release in the watch folder (built in a staging folder and moved in whole), and the NZB goes.
/// The files are silent MP3s (320 kbit/s) as long as Lidarr's tracks, tagged with the MusicBrainz ids so Lidarr can
/// identify them; without ffmpeg, copies of the dev fixture named "01 - Title.mp3".
final class Completer: @unchecked Sendable {
    static let blackhole = TryDevStack.repoRoot.appending(path: "dev/data/downloads/magpie-blackhole")
    let nzbFolder = blackhole.appending(path: "nzb")
    let watchFolder = blackhole.appending(path: "complete")
    /// Release groups whose tracks fill every download (b: the studio album); empty: the album Lidarr grabbed for.
    let filesFrom: [MBID]
    private(set) var made: [URL] = []
    private let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    init(filesFrom: [MBID]) throws {
        self.filesFrom = filesFrom
        let fm = FileManager.default
        guard fm.fileExists(atPath: nzbFolder.path), fm.fileExists(atPath: watchFolder.path) else {
            throw TryDevStack.NotDevStack(description: "no blackhole folders: run dev/fake-indexer/setup.sh")
        }
        let leftovers = ((try? fm.contentsOfDirectory(atPath: nzbFolder.path)) ?? [])
            + ((try? fm.contentsOfDirectory(atPath: watchFolder.path)) ?? [])
        guard leftovers.filter({ !$0.hasPrefix(".") }).isEmpty else {
            throw TryDevStack.NotDevStack(description: "the blackhole folders aren't empty (an earlier run?): \(leftovers)")
        }
    }

    /// One pass; returns what it did, for the timeline.
    func step(artistId: Int?) async throws -> [String] {
        let fm = FileManager.default
        var done: [String] = []
        for file in (try? fm.contentsOfDirectory(atPath: nzbFolder.path)) ?? [] where file.hasSuffix(".nzb") {
            let release = String(file.dropLast(4))
            let tracks = try await self.tracks(release: release, artistId: artistId)
            let staging = Self.blackhole.appending(path: ".staging-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for t in tracks { try write(t, to: staging) }
            let target = watchFolder.appending(path: release)
            try fm.moveItem(at: staging, to: target)
            made.append(target)
            try fm.removeItem(at: nzbFolder.appending(path: file))
            done.append("DOWNLOADER: “\(release)” finished with \(tracks.count) file(s)\(ffmpeg == nil ? " (fixture copies, no ffmpeg)" : "")")
        }
        return done
    }

    struct Track {
        var number: Int, count: Int, disc: Int, title: String, seconds: Double
        var album: String, year: String, artist: String
        var recording: String?, releaseTrack: String?, release: String?, group: String?
    }

    /// The tracks of `filesFrom`'s album, or of the album Lidarr's grab was for (its monitored release).
    private func tracks(release: String, artistId: Int?) async throws -> [Track] {
        guard let artistId else { return [] }
        let albums = try await FindsIT.devLidarr("GET", "album", query: ["artistId": "\(artistId)"], array: true)["rows"] as? [[String: Any]] ?? []
        var album: [String: Any]?
        if let group = filesFrom.first {
            album = albums.first { $0["foreignAlbumId"] as? String == group.rawValue }
        } else {
            let history = try await FindsIT.devLidarr("GET", "history/artist", query: ["artistId": "\(artistId)"], array: true)["rows"] as? [[String: Any]] ?? []
            let grab = history.last { $0["eventType"] as? String == "grabbed" && $0["sourceTitle"] as? String == release }
                ?? history.last { $0["eventType"] as? String == "grabbed" }
            album = albums.first { $0["id"] as? Int == grab?["albumId"] as? Int }
        }
        guard let album, let albumId = album["id"] as? Int else { return [] }
        let full = try await FindsIT.devLidarr("GET", "album/\(albumId)")
        let releases = full["releases"] as? [[String: Any]] ?? []
        let chosen = releases.first { $0["monitored"] as? Bool == true } ?? releases.first
        let rows = try await FindsIT.devLidarr("GET", "track", query: ["albumId": "\(albumId)"], array: true)["rows"] as? [[String: Any]] ?? []
        let title = album["title"] as? String ?? release
        let year = String((album["releaseDate"] as? String ?? "").prefix(4))
        return rows.enumerated().map { i, row in
            Track(number: row["absoluteTrackNumber"] as? Int ?? i + 1, count: rows.count, disc: row["mediumNumber"] as? Int ?? 1,
                  title: row["title"] as? String ?? "Track \(i + 1)",
                  seconds: max(10, Double(row["duration"] as? Int ?? 180_000) / 1000), album: title, year: year,
                  artist: DownloadFlowIT.song.artist, recording: row["foreignRecordingId"] as? String,
                  releaseTrack: row["foreignTrackId"] as? String, release: chosen?["foreignReleaseId"] as? String,
                  group: album["foreignAlbumId"] as? String)
        }
    }

    private func write(_ t: Track, to folder: URL) throws {
        let safe = t.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let file = folder.appending(path: String(format: "%02d - %@.mp3", t.number, safe))
        guard let ffmpeg else {
            try FileManager.default.copyItem(at: TryDevStack.repoRoot.appending(path: FindsIT.fixture), to: file)
            return
        }
        var meta = ["title": t.title, "artist": t.artist, "album_artist": t.artist, "album": t.album,
                    "track": "\(t.number)/\(t.count)", "disc": "\(t.disc)", "date": t.year,
                    "MusicBrainz Artist Id": DownloadFlowIT.artist.rawValue,
                    "MusicBrainz Album Artist Id": DownloadFlowIT.artist.rawValue]
        meta["MusicBrainz Album Id"] = t.release
        meta["MusicBrainz Release Group Id"] = t.group
        meta["MusicBrainz Release Track Id"] = t.releaseTrack
        meta["MusicBrainz Track Id"] = t.recording
        let args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                    "-t", String(format: "%.2f", t.seconds), "-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", "3"]
            + meta.sorted { $0.key < $1.key }.flatMap { ["-metadata", "\($0.key)=\($0.value)"] } + [file.path]
        let out = try Shell.run(ffmpeg, args)
        guard out.status == 0 else { throw TryDevStack.NotDevStack(description: "ffmpeg: \(out.text)") }
    }

    /// Removes what this completer made (Lidarr may have moved the files out already), stray NZBs and staging folders.
    func cleanUp() {
        let fm = FileManager.default
        for url in made { try? fm.removeItem(at: url) }
        for file in (try? fm.contentsOfDirectory(atPath: nzbFolder.path)) ?? [] where file.hasSuffix(".nzb") {
            try? fm.removeItem(at: nzbFolder.appending(path: file))
        }
        for file in (try? fm.contentsOfDirectory(atPath: Self.blackhole.path)) ?? [] where file.hasPrefix(".staging-") {
            try? fm.removeItem(at: Self.blackhole.appending(path: file))
        }
    }
}

/// The dev music roots on the host: which top-level (artist) folders a scenario added, to remove them afterwards.
enum HostFiles {
    typealias Folders = [String: Set<String>]
    static let music = TryDevStack.repoRoot.appending(path: "dev/data/music")

    static func musicFolders() -> Folders {
        Dictionary(uniqueKeysWithValues: ["library", "samples"].map { root in
            (root, Set((try? FileManager.default.contentsOfDirectory(atPath: music.appending(path: root).path)) ?? []))
        })
    }

    static func newFiles(since before: Folders) -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        for (root, now) in musicFolders() {
            for folder in now.subtracting(before[root] ?? []) {
                let url = music.appending(path: root).appending(path: folder)
                let found = fm.enumerator(atPath: url.path)?.compactMap { $0 as? String } ?? []
                files += found.filter { $0.hasSuffix(".mp3") || $0.hasSuffix(".flac") }.map { "/music/\(root)/\(folder)/\($0)" }
            }
        }
        return files
    }

    static func removeNewFolders(since before: Folders) {
        for (root, now) in musicFolders() {
            for folder in now.subtracting(before[root] ?? []) {
                try? FileManager.default.removeItem(at: music.appending(path: root).appending(path: folder))
            }
        }
    }
}

enum Shell {
    static func run(_ exe: String, _ args: [String]) throws -> (status: Int32, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension Flow {
    /// MusicBrainz and Lidarr's metadata both know the Single and the studio album "Solar Power", both holding the
    /// recording; otherwise the scenarios don't test what they say.
    static func verifyCatalogue(_ mb: MusicBrainzClient) async throws {
        let releases = try await mb.allReleases(recording: DownloadFlowIT.recording)
        let groups = Dictionary(releases.map { ($0.releaseGroup.id, $0.releaseGroup.primaryType ?? "?") }, uniquingKeysWith: { a, _ in a })
        #expect(groups[DownloadFlowIT.singleGroup] == "Single", "MusicBrainz: no Single “Solar Power” holding the song")
        #expect(groups[DownloadFlowIT.albumGroup] == "Album", "MusicBrainz: no studio album “Solar Power” holding the song")
        let lookup = try await FindsIT.devLidarr("GET", "album/lookup", query: ["term": "Lorde Solar Power"], array: true)["rows"] as? [[String: Any]] ?? []
        let ids = Set(lookup.compactMap { $0["foreignAlbumId"] as? String })
        #expect(ids.contains(DownloadFlowIT.singleGroup.rawValue) && ids.contains(DownloadFlowIT.albumGroup.rawValue),
                "Lidarr's album/lookup lacks the Single or the album: \(ids)")
    }
}
