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

/// Holds one request in flight until released, and says when it has arrived.
actor Latch {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var holders: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        if released { return }
        await withCheckedContinuation { holders.append($0) }
    }

    func waitArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        holders.forEach { $0.resume() }
        holders = []
    }
}

/// The transport the client uses: the mock, except that the n-th request matching `hold` waits on `latch`.
struct HoldingTransport: HTTPTransport {
    let inner: MockTransport
    let lidarr: FakeLidarr

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let latch = lidarr.shouldHold(request) { await latch.hold() }
        if request.url?.path.contains("/api/v1/") == true, let answer = lidarr.with({ $0.everyLidarrAnswer }) {
            let http = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: answer.headers)!
            lidarr.transport.record(request)
            return (answer.body, http)
        }
        let timesOut: Bool = lidarr.with { s in
            guard request.httpMethod == "PUT", request.url?.path.hasSuffix("/album/monitor") == true,
                  s.monitorTimesOut > 0 else { return false }
            s.monitorTimesOut -= 1
            return true
        }
        if timesOut { throw URLError(.timedOut) }
        let editorTimesOut: Bool = lidarr.with { s in
            guard request.httpMethod == "PUT", request.url?.path.hasSuffix("/artist/editor") == true,
                  s.editorTimesOut > 0 else { return false }
            s.editorTimesOut -= 1
            return true
        }
        if editorTimesOut { throw URLError(.timedOut) }
        return try await inner.send(request)
    }
}

final class FakeLidarr: @unchecked Sendable {
    struct Artist {
        var id: Int; var mbid: MBID; var root: String
        /// Lidarr's artist folder; nil: `<root>/Aurora Field`.
        var path: String? = nil
        var tags: [Int] = []
        var quality = 4
        /// Where the artist's files really are on disk; nil: no files.
        var files: String? = nil
        /// Where `GET /trackfile?artistId=` says they are (Lidarr updates it shortly after a move).
        var recorded: String? = nil
        var currentPath: String { path ?? root + "/Aurora Field" }
    }
    /// A `/command` row (Keep's BulkMoveArtist, A3).
    struct Command { var id: Int; var name: String; var status: String; var artistIds: [Int] }
    /// How Lidarr's BulkMoveArtist goes after `PUT /artist/editor` with a root folder (Task 6.2b).
    enum Move: Equatable {
        /// queued → started → completed over the next `/command` reads; the files are moved.
        case completes
        /// queued → started → failed; Lidarr reverts the artist path (`RevertPath`).
        case fails
        /// Completes, but the move hit an IOException: Lidarr logged it and reverted the path.
        case revertsSilently
        /// Stays started (a slow copy to another volume).
        case hangs
        /// No command shows up at all: it completed and Lidarr pruned it; the files moved.
        case neverListed
        /// No command shows up at all and the files never moved (a restart orphaned the move, then it was pruned).
        case prunedFilesStayed
    }
    struct Album { var id: Int; var artistId: Int; var rg: MBID; var title: String; var monitored: Bool }
    struct Queued {
        var albumId: Int; var size: Double; var sizeleft: Double
        var status = "downloading"; var tracked = "downloading"; var messages: [String] = []
    }
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
        /// Every Lidarr request (any method) gets this answer: a proxy's HTML page, a 401 for a wrong key.
        var everyLidarrAnswer: MockTransport.Response?
        /// POST /artist creates the artist but answers 504 (the outcome looks unclear to Magpie).
        var addAnswers504 = false
        /// PUT /album/monitor: applies, then answers 504 (lost answer) this many times.
        var monitorAppliedThen504 = 0
        /// PUT /album/monitor: answers 503 without applying this many times.
        var monitorFails503 = 0
        /// PUT /album/monitor: answers `monitorRejectStatus` (a 4xx) without applying this many times.
        var monitorRejects = 0
        var monitorRejectStatus = 400
        /// PUT /album/monitor: the client times out (URLError) before Lidarr has applied it, this many times.
        var monitorTimesOut = 0
        /// After a failed monitor PUT (504 lost answer or 503), the next GET /album fails too (the confirm
        /// can't tell).
        var confirmFailsAfterLost = false
        /// GET /album answers 503 this many times.
        var albumGetFailures = 0
        /// Hold the n-th request (method `holdMethod`) whose path ends with `suffix`.
        var hold: (suffix: String, n: Int)?
        /// `GET /rootfolder` (Finds mode re-checks the Finds root before every add).
        var roots = ["/music/library", "/music/samples"]
        var rootsDown = false
        var holdMethod = "GET"
        var holdSeen = 0
        // Keep (Task 6.2b)
        var commands: [Command] = [Command(id: 70, name: "RssSync", status: "completed", artistIds: [])]
        var move = Move.completes
        /// `/command` reads so far, each with the BulkMoveArtist statuses it showed.
        var commandReads: [String] = []
        /// Folders that exist on Lidarr's filesystem (besides the artists' own folders).
        var folders: Set<String> = []
        /// `PUT /artist/editor` answers this status (a 4xx: not applied) this many times.
        var editorRejects = 0
        /// `PUT /artist/editor` applies, then answers 504 (lost answer) this many times.
        var editorAppliedThen504 = 0
        var commandsDown = false
        /// `PUT /artist/editor`: the client times out before it reaches Lidarr, this many times.
        var editorTimesOut = 0
        /// The artist folder Lidarr's naming format gives (lookup `folder`); a move lands there.
        var lookupFolder = "Aurora Field"
        /// `PUT /artist/editor` putting a find back (`applyTags: add`) answers 400.
        var rejectRestores = false
        /// A completed move leaves the files here instead of in the new artist folder.
        var filesLandIn: String?
        /// `/trackfile` follows a move (Lidarr 3.2 doesn't: the paths stay at the old folder).
        var trackFilesFollowMove = false
    }

    let latch = Latch()
    static let songFile = "Lowlands (2016)/01 - Song.mp3"
    /// What happened, in order: `/command` reads (`command:<BulkMoveArtist statuses>`) and library rescans.
    let events = OSAllocatedUnfairLock(initialState: [String]())

    func shouldHold(_ request: URLRequest) -> Latch? {
        let path = request.url?.path ?? ""
        let hit: Bool = with { s in
            guard let h = s.hold, (request.httpMethod ?? "GET") == s.holdMethod, path.hasSuffix(h.suffix) else {
                return false
            }
            s.holdSeen += 1
            return s.holdSeen == h.n
        }
        return hit ? latch : nil
    }

    var clientTransport: HoldingTransport { HoldingTransport(inner: transport, lidarr: self) }

    /// GETs to MusicBrainz so far.
    var mbCalls: Int { transport.requests.filter { $0.url?.path.contains("/ws/2/") == true }.count }

    /// `history/since` `date` values asked for, in order.
    var historyDates: [String] {
        transport.requests.filter { $0.url?.path.hasSuffix("/history/since") == true }.compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "date" }?.value
        }
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
            let path = req.url!.path.replacingOccurrences(of: "/lidarr/api/v1/", with: "").replacingOccurrences(of: "/api/v1/", with: "")
            let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return ("\(req.httpMethod!) \(path)", body)
        }
    }

    init() {
        let t = transport
        @Sendable func reply(_ object: Any, status: Int = 200) -> MockTransport.Response { Self.reply(object, status: status) }
        t.stub(pathSuffix: "/api/v1/artist") { [self] _ in
            if let d = down() { return d }
            return reply(with { s in s.artists.map(Self.artistJSON) })
        }
        for id in [7, 42, 43] {
            t.stub(pathSuffix: "/api/v1/artist/\(id)") { [self] _ in
                if let d = down() { return d }
                guard let artist = with({ s in s.artists.first { $0.id == id } }) else { return MockTransport.Response(status: 404) }
                return reply(Self.artistJSON(artist))
            }
        }
        t.stub(method: "PUT", pathSuffix: "/api/v1/artist/editor") { [self] req in
            let body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            if body["applyTags"] as? String == "add", with({ $0.rejectRestores }) { return MockTransport.Response(status: 400) }
            if let rejected: Int = with({ s in
                guard s.editorRejects > 0 else { return nil }
                s.editorRejects -= 1
                return 400
            }) { return MockTransport.Response(status: rejected) }
            let lost: Bool = with { s in
                let ids = body["artistIds"] as! [Int]
                for i in s.artists.indices where ids.contains(s.artists[i].id) {
                    let tags = body["tags"] as? [Int] ?? []
                    switch body["applyTags"] as? String {
                    case "remove": s.artists[i].tags.removeAll { tags.contains($0) }
                    case "add": s.artists[i].tags += tags.filter { !s.artists[i].tags.contains($0) }
                    default: break
                    }
                    if let q = body["qualityProfileId"] as? Int { s.artists[i].quality = q }
                    if let root = body["rootFolderPath"] as? String, body["moveFiles"] as? Bool == false {
                        // Path only, from the existing folder name; nothing moves.
                        let folder = String(s.artists[i].currentPath.split(separator: "/").last!)
                        s.artists[i].path = root + "/" + folder
                        s.artists[i].root = root
                    } else if let root = body["rootFolderPath"] as? String {
                        // Lidarr saves the new path at once (its naming format's folder) and queues the move (A3).
                        s.artists[i].path = root + "/" + s.lookupFolder
                        s.artists[i].root = root
                        if s.move == .neverListed {
                            s.artists[i].files = s.artists[i].path
                            s.artists[i].recorded = s.artists[i].path
                        }
                        if s.move != .neverListed, s.move != .prunedFilesStayed {
                            s.nextCommandId += 1
                            s.commands.append(Command(id: s.nextCommandId, name: "BulkMoveArtist", status: "queued",
                                                      artistIds: [s.artists[i].id]))
                        }
                    }
                }
                guard s.editorAppliedThen504 > 0 else { return false }
                s.editorAppliedThen504 -= 1
                return true
            }
            return lost ? MockTransport.Response(status: 504) : reply([[String: Any]](), status: 202)
        }
        t.stub(pathSuffix: "/api/v1/command") { [self] _ in
            if with({ $0.commandsDown }) { return MockTransport.Response(status: 503) }
            return reply(with { s in
                // Each read moves a BulkMoveArtist one step on.
                for i in s.commands.indices where s.commands[i].name == "BulkMoveArtist" {
                    let next: String? = switch (s.commands[i].status, s.move) {
                    case ("queued", _): "started"
                    case ("started", .completes), ("started", .revertsSilently): "completed"
                    case ("started", .fails): "failed"
                    default: nil
                    }
                    guard let next else { continue }
                    if s.commands[i].status == "started", s.move == .completes {
                        for a in s.artists.indices where s.commands[i].artistIds.contains(s.artists[a].id) {
                            s.artists[a].files = s.filesLandIn ?? s.artists[a].currentPath
                            if s.trackFilesFollowMove { s.artists[a].recorded = s.artists[a].files }
                        }
                    }
                    if s.commands[i].status == "started", s.move != .completes {
                        for a in s.artists.indices where s.commands[i].artistIds.contains(s.artists[a].id) {
                            s.artists[a].root = "/music/samples"
                            s.artists[a].path = nil   // RevertPath
                        }
                    }
                    s.commands[i].status = next
                }
                let statuses = s.commands.filter { $0.name == "BulkMoveArtist" }.map(\.status).joined(separator: ",")
                s.commandReads.append(statuses)
                events.withLock { $0.append("command:" + statuses) }
                return s.commands.map { c in
                    ["id": c.id, "name": c.name, "status": c.status,
                     "body": ["artist": c.artistIds.map { ["artistId": $0, "sourcePath": "/music/samples/x"] },
                              "destinationRootFolder": "/music/library", "name": c.name]] as [String: Any]
                }
            })
        }
        t.stub(pathSuffix: "/api/v1/filesystem") { [self] req in
            let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let parent = items.first { $0.name == "path" }?.value ?? ""
            let withFiles = items.first { $0.name == "includeFiles" }?.value == "true"
            let (dirs, files): ([String], [String]) = with { s in
                // On disk: the extra folders, and each artist's files folder with its album folder and song.
                let songs = s.artists.compactMap(\.files).map { $0 + "/" + FakeLidarr.songFile }
                var folders = s.folders
                for song in songs {
                    var d = (song as NSString).deletingLastPathComponent
                    while d.count > 1 { folders.insert(d); d = (d as NSString).deletingLastPathComponent }
                }
                let inParent = { (p: String) in (p as NSString).deletingLastPathComponent + "/" == parent }
                return (folders.filter(inParent).sorted(), songs.filter(inParent).sorted())
            }
            return reply(["parent": parent, "directories": dirs.map { ["path": $0 + "/", "name": "x"] },
                          "files": withFiles ? files.map { ["path": $0, "name": "x"] } : [[String: Any]]()])
        }
        t.stub(pathSuffix: "/api/v1/rootfolder") { [self] _ in
            if with({ $0.rootsDown }) { return MockTransport.Response(status: 503) }
            return reply(with { s in s.roots.enumerated().map { ["id": $0.offset + 1, "path": $0.element] as [String: Any] } })
        }
        t.stub(pathSuffix: "/api/v1/artist/lookup") { [self] _ in
            reply([["artistName": "Aurora Field", "foreignArtistId": artistA.rawValue, "qualityProfileId": 0,
                    "metadataProfileId": 0, "monitored": false, "monitorNewItems": "all", "tags": [Int](),
                    "RootFolderPath": "/x", "overview": "Band", "folder": with { $0.lookupFolder }]])
        }
        t.stub(pathSuffix: "/api/v1/trackfile") { [self] req in
            let artistId = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "artistId" }?.value.flatMap(Int.init)
            return reply(with { s in
                return s.artists.filter { $0.id == artistId }.compactMap(\.recorded).map {
                    ["id": 1, "path": $0 + "/" + FakeLidarr.songFile, "albumId": 50] as [String: Any]
                }
            })
        }
        t.stub(pathSuffix: "/api/v1/album") { [self] req in
            if let d = down() { return d }
            let fail: Bool = with { s in
                guard s.albumGetFailures > 0 else { return false }
                s.albumGetFailures -= 1
                return true
            }
            if fail { return MockTransport.Response(status: 503) }
            let artistId = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "artistId" }?.value.flatMap(Int.init)
            return reply(with { s in s.albums.filter { $0.artistId == artistId }.map {
                ["id": $0.id, "title": $0.title, "artistId": $0.artistId, "foreignAlbumId": $0.rg.rawValue,
                 "monitored": $0.monitored, "albumType": "Album"] as [String: Any] } })
        }
        t.stub(method: "PUT", pathSuffix: "/api/v1/album/monitor") { [self] req in
            let body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let ids = body["albumIds"] as! [Int], on = body["monitored"] as! Bool
            let unapplied: Bool = with { s in
                guard s.monitorFails503 > 0 else { return false }
                s.monitorFails503 -= 1
                if s.confirmFailsAfterLost { s.albumGetFailures += 1 }
                return true
            }
            if unapplied { return MockTransport.Response(status: 503) }
            let rejected: Int? = with { s in
                guard s.monitorRejects > 0 else { return nil }
                s.monitorRejects -= 1
                return s.monitorRejectStatus
            }
            if let rejected { return MockTransport.Response(status: rejected) }
            let lost: Bool = with { s in
                for i in s.albums.indices where ids.contains(s.albums[i].id) { s.albums[i].monitored = on }
                guard s.monitorAppliedThen504 > 0 else { return false }
                s.monitorAppliedThen504 -= 1
                if s.confirmFailsAfterLost { s.albumGetFailures += 1 }
                return true
            }
            return lost ? MockTransport.Response(status: 504) : reply([[String: Any]]())
        }
        t.stub(method: "POST", pathSuffix: "/api/v1/artist") { [self] req in
            let body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let id: Int = with { s in
                let id = s.nextArtistId
                s.nextArtistId += 1
                let root = body["rootFolderPath"] as! String
                s.artists.append(Artist(id: id, mbid: MBID(body["foreignArtistId"] as! String)!,
                                        root: root, tags: body["tags"] as? [Int] ?? [],
                                        quality: body["qualityProfileId"] as? Int ?? 0, files: root + "/Aurora Field",
                                        recorded: root + "/Aurora Field"))
                if s.albumsAppearOnAdd {
                    s.albums += s.albumsOnAdd.map { var a = $0; a.artistId = id; return a }
                }
                return id
            }
            if with({ $0.addAnswers504 }) { return MockTransport.Response(status: 504) }
            return reply(["id": id, "artistName": "Aurora Field"], status: 201)
        }
        t.stub(method: "POST", pathSuffix: "/api/v1/command") { [self] _ in
            let id: Int = with { s in s.nextCommandId += 1; return s.nextCommandId }
            return reply(["id": id, "name": "AlbumSearch", "status": "queued"], status: 201)
        }
        t.stub(pathSuffix: "/api/v1/queue/details") { [self] _ in
            if let d = down() { return d }
            return reply(with { s in s.queue.map { ["albumId": $0.albumId, "size": $0.size, "sizeleft": $0.sizeleft,
                                                    "status": $0.status, "trackedDownloadState": $0.tracked,
                                                    "statusMessages": [["title": "t", "messages": $0.messages]]] as [String: Any] } })
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

    static func artistJSON(_ a: Artist) -> [String: Any] {
        ["id": a.id, "artistName": "A", "foreignArtistId": a.mbid.rawValue, "rootFolderPath": a.root,
         "path": a.currentPath, "monitored": true, "tags": a.tags, "qualityProfileId": a.quality]
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
        /// Keep: the scans after a move (Lidarr's old and new artist folder).
        var rescans: [(from: String, to: String)] = []
        /// Keep: songs of the main library by recording (re-resolved after the move).
        var mainSongs: [MBID: Song] = [:]
        var mainSongReads = 0
        /// The artist folders the kept song was looked up in.
        var keptSongFolders: [String] = []
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    /// Shared with the fake Lidarr's `/command` reads, so tests can see what happened in which order.
    let events: OSAllocatedUnfairLock<[String]>

    init(events: OSAllocatedUnfairLock<[String]> = .init(initialState: [])) { self.events = events }

    func list(_ recording: MBID, as songId: String) { state.withLock { $0.listed[recording] = songId } }

    var access: LibraryAccess {
        LibraryAccess(
            startScan: { [self] in state.withLock { $0.scans += 1 } },
            isScanning: { [self] in state.withLock { $0.scanning } },
            refreshIndex: { [self] in state.withLock { $0.refreshes += 1; $0.indexed = $0.listed } },
            songId: { [self] r in r.recordingMBID.flatMap { id in state.withLock { $0.indexed[id] } } },
            rescanMoved: { [self] from, to in
                state.withLock { $0.rescans.append((from, to)) }
                events.withLock { $0.append("rescan") }
            },
            keptSong: { [self] id, folder in
                state.withLock {
                    $0.mainSongReads += 1
                    $0.keptSongFolders.append(folder)
                    return $0.mainSongs[id]
                }
            })
    }
}

struct Harness {
    let server: FakeLidarr
    let library: FakeLibrary
    let clock = TestClock()
    let ready = OSAllocatedUnfairLock(initialState: [RequestID]())
    let gate: LidarrWriteGate
    let ledger: Ledger
    let store: RequestStore
    let runner: RequestRunner
    let suite = "magpie-runner-\(UUID().uuidString)"

    static let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: 4,
                                           metadataProfileId: 3, tagIds: [1])
    /// Finds mode (Task 6.2a): new artists go to `/music/samples`, tagged `magpie` (1) and `magpie-find` (2).
    static let findsSetup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: 4,
                                                metadataProfileId: 3, tagIds: [1],
                                                finds: .init(rootFolderPath: "/music/samples", tagIds: [1, 2]))
    /// Keep (Task 6.2b): Finds root `/music/samples`, main root `/music/library`, "Magpie Lossless" 9, magpie-find 2.
    static let keepSetup = RequestRunner.KeepSetup(findsRoot: "/music/samples", mainRoot: "/music/library",
                                                   losslessProfileId: 9, findTagId: 2)
    /// `onRelinked` calls: (request, the song id before, the song after).
    let relinked = OSAllocatedUnfairLock(initialState: [(RequestID, String?, Song)]())

    init(changesOn: Bool = true, directory: URL? = nil, lidarr existing: FakeLidarr? = nil,
         base: URL = URL(string: "https://music.example/lidarr")!, setup: RequestRunner.Setup = Harness.setup,
         keep: RequestRunner.KeepSetup? = Harness.keepSetup) async {
        let dir = directory ?? FileManager.default.temporaryDirectory.appending(path: "magpie-runner-\(UUID().uuidString)")
        let lidarr = existing ?? FakeLidarr()
        library = FakeLibrary(events: lidarr.events)
        let client = LidarrClient(base: base, apiKey: "k", transport: lidarr.clientTransport)
        gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite)
        await gate.setEnabled(changesOn)
        ledger = Ledger(fileURL: dir.appending(path: "ledger.json"), instance: client.instanceScope)
        store = RequestStore(fileURL: RequestStore.defaultURL(in: dir, instance: client.instanceScope))
        let mb = MusicBrainzClient(transport: lidarr.clientTransport,
                                   limiter: RateLimiter(perSecond: 1_000, sleep: { _ in }))
        let clock = self.clock, ready = self.ready, relinked = self.relinked
        runner = RequestRunner(lidarr: client, gate: gate, ledger: ledger, mb: mb, library: library.access,
                               store: store, setup: { setup }, keepSetup: { keep }, now: { clock.now },
                               sleep: { d in clock.advance(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) },
                               onReady: { r in ready.withLock { $0.append(r.id) } },
                               onRelinked: { r, before, song in relinked.withLock { $0.append((r.id, before, song)) } })
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
