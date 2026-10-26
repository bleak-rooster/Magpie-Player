import Foundation
import os
import LidarrKit
import ListenBrainzKit
import MagpieCore
import MagpieTestSupport
@testable import Requests

// A scripted Lidarr + MusicBrainz behind one MockTransport, a fake library and a hand-moved clock.

func mbid(_ n: Int) -> MBID { MBID(String(format: "00000000-0000-0000-0000-%012d", n))! }

let artistA = mbid(1)
let rgSingle = mbid(10)
let rgAlbum = mbid(11)
let rgLive = mbid(12)
let recSingleAndAlbum = mbid(100)   // on the single and the album
let recAlbumOnly = mbid(101)        // album only
let recAlbumOnly2 = mbid(102)       // album only

final class TestClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_900_000_000))
    var now: Date { lock.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { lock.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

final class FakeLidarr: @unchecked Sendable {
    struct Artist { var id: Int; var mbid: MBID; var root: String }
    struct Album { var id: Int; var artistId: Int; var rg: MBID; var title: String; var monitored: Bool }
    struct Queued { var albumId: Int; var size: Double; var sizeleft: Double }
    struct Event { var albumId: Int; var type: String; var date: Date }

    struct State {
        var artists: [Artist] = []
        var albums: [Album] = []
        /// Albums Lidarr gets for an artist it adds (after its refresh).
        var albumsOnAdd: [Album] = []
        var albumsAppearOnAdd = true
        var queue: [Queued] = []
        var history: [Event] = []
        var commandStatus = "completed"
        var nextArtistId = 42
        var nextCommandId = 77
        var down = false
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    let transport = MockTransport()

    func with<T>(_ change: (inout State) -> T) -> T { state.withLockUnchecked { change(&$0) } }

    @Sendable static func reply(_ object: Any, status: Int = 200) -> MockTransport.Response {
        MockTransport.Response(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    func down() -> MockTransport.Response? {
        state.withLock { $0.down } ? MockTransport.Response(status: 503) : nil
    }

    /// Every request that is not a GET.
    var writes: [URLRequest] { transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" } }

    func writeBodies() -> [(String, [String: Any])] {
        writes.map { req in
            let path = req.url!.path.replacingOccurrences(of: "/lidarr/api/v1/", with: "")
            let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return ("\(req.httpMethod!) \(path)", body)
        }
    }

    init() {
        let t = transport
        @Sendable func reply(_ object: Any, status: Int = 200) -> MockTransport.Response { Self.reply(object, status: status) }
        t.stub(pathSuffix: "/api/v1/artist") { [self] _ in
            if let d = down() { return d }
            return reply(with { s in s.artists.map { ["id": $0.id, "artistName": "A", "foreignArtistId": $0.mbid.rawValue,
                                                       "rootFolderPath": $0.root, "monitored": true, "tags": [Int]()] } })
        }
        t.stub(pathSuffix: "/api/v1/artist/lookup") { _ in
            reply([["artistName": "Aurora Field", "foreignArtistId": artistA.rawValue, "qualityProfileId": 0,
                    "metadataProfileId": 0, "monitored": false, "monitorNewItems": "all", "tags": [Int](),
                    "RootFolderPath": "/x", "overview": "Band"]])
        }
        t.stub(pathSuffix: "/api/v1/album") { [self] req in
            if let d = down() { return d }
            let artistId = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "artistId" }?.value.flatMap(Int.init)
            return reply(with { s in s.albums.filter { $0.artistId == artistId }.map {
                ["id": $0.id, "title": $0.title, "artistId": $0.artistId, "foreignAlbumId": $0.rg.rawValue,
                 "monitored": $0.monitored, "albumType": "Album"] as [String: Any] } })
        }
        t.stub(method: "PUT", pathSuffix: "/api/v1/album/monitor") { [self] req in
            let body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let ids = body["albumIds"] as! [Int], on = body["monitored"] as! Bool
            with { s in for i in s.albums.indices where ids.contains(s.albums[i].id) { s.albums[i].monitored = on } }
            return reply([[String: Any]]())
        }
        t.stub(method: "POST", pathSuffix: "/api/v1/artist") { [self] req in
            let body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let id: Int = with { s in
                let id = s.nextArtistId
                s.nextArtistId += 1
                s.artists.append(Artist(id: id, mbid: MBID(body["foreignArtistId"] as! String)!,
                                        root: body["rootFolderPath"] as! String))
                if s.albumsAppearOnAdd {
                    s.albums += s.albumsOnAdd.map { var a = $0; a.artistId = id; return a }
                }
                return id
            }
            return reply(["id": id, "artistName": "Aurora Field"], status: 201)
        }
        t.stub(method: "POST", pathSuffix: "/api/v1/command") { [self] _ in
            let id: Int = with { s in s.nextCommandId += 1; return s.nextCommandId }
            return reply(["id": id, "name": "AlbumSearch", "status": "queued"], status: 201)
        }
        t.stub(pathSuffix: "/api/v1/queue/details") { [self] _ in
            if let d = down() { return d }
            return reply(with { s in s.queue.map { ["albumId": $0.albumId, "size": $0.size, "sizeleft": $0.sizeleft,
                                                    "status": "downloading", "trackedDownloadState": "downloading"] as [String: Any] } })
        }
        t.stub(pathSuffix: "/api/v1/history/since") { [self] _ in
            if let d = down() { return d }
            let f = ISO8601DateFormatter()
            return reply(with { s in s.history.map { ["albumId": $0.albumId, "eventType": $0.type,
                                                      "date": f.string(from: $0.date)] as [String: Any] } })
        }
        t.stub(pathSuffix: "/api/v1/command/78") { [self] _ in
            reply(["id": 78, "name": "AlbumSearch", "status": with { $0.commandStatus }])
        }
        // MusicBrainz
        func release(_ n: Int, _ rg: MBID, _ type: String, secondary: [String] = []) -> [String: Any] {
            ["id": mbid(500 + n).rawValue, "title": "Release \(n)", "status": "Official", "date": "2001",
             "release-group": ["id": rg.rawValue, "primary-type": type, "secondary-types": secondary]]
        }
        let credit: [[String: Any]] = [["name": "Aurora Field", "artist": ["id": artistA.rawValue]]]
        let recordings: [MBID: [[String: Any]]] = [
            recSingleAndAlbum: [release(1, rgAlbum, "Album"), release(2, rgSingle, "Single"),
                                release(3, rgLive, "Album", secondary: ["Live"])],
            recAlbumOnly: [release(4, rgAlbum, "Album")],
            recAlbumOnly2: [release(5, rgAlbum, "Album")],
        ]
        for (id, releases) in recordings {
            let body = try! JSONSerialization.data(withJSONObject: ["id": id.rawValue, "title": "Song", "releases": releases,
                                                                    "artist-credit": credit])
            t.stub(pathSuffix: "/ws/2/recording/\(id.rawValue)", body: body)
        }
    }

    /// Lidarr already has the artist (id 7) with the album (id 31) and a live album (id 33).
    func ownerHasArtist(albumMonitored: Bool) {
        with { s in
            s.artists = [Artist(id: 7, mbid: artistA, root: "/music/library")]
            s.albums = [Album(id: 31, artistId: 7, rg: rgAlbum, title: "Lowlands", monitored: albumMonitored),
                        Album(id: 33, artistId: 7, rg: rgLive, title: "Lowlands Live", monitored: false)]
        }
    }

    /// Lidarr does not have the artist; adding it brings the single (album id 50) and the album (51).
    func artistIsNew() {
        with { s in
            s.albumsOnAdd = [Album(id: 50, artistId: 0, rg: rgSingle, title: "Lowlands (single)", monitored: true),
                             Album(id: 51, artistId: 0, rg: rgAlbum, title: "Lowlands", monitored: true)]
        }
    }
}

final class FakeLibrary: @unchecked Sendable {
    struct State {
        var scanning = false
        var listed: [MBID: String] = [:]
        var scans = 0
        var refreshes = 0
        /// What the index knows: `listed` is copied in on refresh.
        var indexed: [MBID: String] = [:]
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    func list(_ recording: MBID, as songId: String) { state.withLock { $0.listed[recording] = songId } }

    var access: LibraryAccess {
        LibraryAccess(
            startScan: { [self] in state.withLock { $0.scans += 1 } },
            isScanning: { [self] in state.withLock { $0.scanning } },
            refreshIndex: { [self] in state.withLock { $0.refreshes += 1; $0.indexed = $0.listed } },
            songId: { [self] r in r.recordingMBID.flatMap { id in state.withLock { $0.indexed[id] } } })
    }
}

struct Harness {
    let server: FakeLidarr
    let library = FakeLibrary()
    let clock = TestClock()
    let ready = OSAllocatedUnfairLock(initialState: [RequestID]())
    let gate: LidarrWriteGate
    let ledger: Ledger
    let store: RequestStore
    let runner: RequestRunner
    let suite = "magpie-runner-\(UUID().uuidString)"

    static let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: 4,
                                           metadataProfileId: 3, tagIds: [1])

    init(changesOn: Bool = true, directory: URL? = nil, lidarr existing: FakeLidarr? = nil) async {
        let dir = directory ?? FileManager.default.temporaryDirectory.appending(path: "magpie-runner-\(UUID().uuidString)")
        let lidarr = existing ?? FakeLidarr()
        let client = LidarrClient(base: URL(string: "https://music.example/lidarr")!, apiKey: "k", transport: lidarr.transport)
        gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite)
        await gate.setEnabled(changesOn)
        ledger = Ledger(fileURL: dir.appending(path: "ledger.json"))
        store = RequestStore(fileURL: dir.appending(path: "requests.json"))
        let mb = MusicBrainzClient(transport: lidarr.transport,
                                   limiter: RateLimiter(perSecond: 1_000, sleep: { _ in }))
        let clock = self.clock, ready = self.ready
        runner = RequestRunner(lidarr: client, gate: gate, ledger: ledger, mb: mb, library: library.access,
                               store: store, setup: { Harness.setup }, now: { clock.now },
                               onReady: { r in ready.withLock { $0.append(r.id) } })
        self.server = lidarr
        self.dir = dir
    }

    let dir: URL

    func recording(_ id: MBID, title: String = "Song") -> ExternalRecording {
        ExternalRecording(recordingMBID: id, title: title, artist: "Aurora Field", source: .listenBrainz)
    }

    func request(_ id: RequestID) async -> MagpieRequest? { await runner.requests.first { $0.id == id } }

    func state(_ id: RequestID) async -> RequestState? { await request(id)?.state }
}
