import Foundation
import os
import Testing
import LidarrKit
import MagpieCore
import MagpieTestSupport
@testable import Requests

/// A Lidarr for "Change what's monitored": the owner's artist 20 at `/music/library/Owner` on "Owner Profile" (5:
/// Album, EP, Single; Studio, Live), Magpie's release-type profiles made already, and a refresh that behaves as
/// Lidarr's (albums the profile no longer allows and that have no files go; the ones it now allows appear, unmonitored
/// unless following is "all"). Track files can be deleted (`DELETE /trackfile/bulk`) and read one by one.
final class MonitoringLidarr: @unchecked Sendable {
    struct Album { var id: Int; var primary: String; var secondary: [String] = []; var monitored: Bool; var title: String }
    struct File { var id: Int; var album: Int; var size: Int64; var title: String; var recording: String }
    struct State: @unchecked Sendable {
        var profileId = 5
        var follow = "none"
        var albums: [Album] = []
        var catalogue: [Album] = []
        var files: [File] = []
        var loseNextAnswer: String?
        var refreshStatus = "completed"
        var profiles: [[String: Any]] = MonitoringLidarr.profiles
        /// Reads of the artist fail (Lidarr unreachable for that call).
        var artistFails = false
        /// Commands Lidarr lists (`GET /command`).
        var commands: [[String: Any]] = []
        /// The next POST /command answers 503 this many times.
        var failCommands = 0
        /// The next refresh saves the artist with this profile (an earlier refresh racing the editor write).
        var resetProfileOnRefresh: Int?
        /// Every refresh saves the artist with this profile (fix round 2 m2).
        var resetProfileAlways: Int?
        /// The editor answers 200 but doesn't take the profile (fix round 2 m3).
        var ignoreEditor = false
        /// Files no track row names (fix round 3 H-M3).
        var untracked: Set<Int> = []
        /// The editor turns "Let Magpie change what Lidarr monitors" off as it answers (fix round 3 H-L2).
        var switchOffAtEditor = false
    }
    static let ownerMBID = MBID("20202020-2020-4020-8020-202020202020")!
    let transport = MockTransport()
    let client: LidarrClient
    let ledger: Ledger
    let gate: LidarrWriteGate
    let state = OSAllocatedUnfairLock(initialState: State())
    let suite = "Monitoring.\(UUID().uuidString)"

    static func profile(_ id: Int, _ name: String, primary: Set<String>, secondary: Set<String>) -> [String: Any] {
        ["id": id, "name": name,
         "primaryAlbumTypes": ["Album", "EP", "Single", "Broadcast"].enumerated().map {
             ["albumType": ["id": $0.offset, "name": $0.element], "allowed": primary.contains($0.element)] },
         "secondaryAlbumTypes": ["Studio", "Compilation", "Soundtrack", "Live"].enumerated().map {
             ["albumType": ["id": $0.offset, "name": $0.element], "allowed": secondary.contains($0.element)] },
         "releaseStatuses": ["Official", "Promotion"].enumerated().map {
             ["releaseStatus": ["id": $0.offset, "name": $0.element], "allowed": $0.element == "Official"] }]
    }

    static let albumsOnly = ReleaseTypes(albums: true, eps: false, singles: false)
    static let albumsEPs = ReleaseTypes(albums: true, eps: true, singles: false)
    static let everything = ReleaseTypes(albums: true, eps: true, singles: true)
    nonisolated(unsafe) static let profiles: [[String: Any]] = [
        profile(5, "Owner Profile", primary: ["Album", "EP", "Single"], secondary: ["Studio", "Live"]),
        profile(30, albumsOnly.profileName, primary: ["Album"], secondary: ["Studio"]),
        profile(32, albumsEPs.profileName, primary: ["Album", "EP"], secondary: ["Studio"]),
        profile(33, everything.profileName, primary: ["Album", "EP", "Single"], secondary: ["Studio"]),
    ]

    init(monitoringOn: Bool = true, changesOn: Bool = true, ledgerURL: URL? = nil, root: String = "/music/library") async {
        client = LidarrClient(base: URL(string: "http://127.0.0.1:8686")!, apiKey: "devkey", transport: transport)
        ledger = Ledger(fileURL: ledgerURL, instance: client.instanceScope)
        let dir = FileManager.default.temporaryDirectory.appending(path: "Monitoring-\(UUID().uuidString)")
        gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite,
                               confinement: WriteConfinement(ledger: ledger, roots: {
                                   WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: 2)
                               }))
        await gate.setEnabled(changesOn)
        await gate.setMonitoringChangesEnabled(monitoringOn)
        state.withLockUnchecked { s in
            s.albums = [Album(id: 1, primary: "Album", monitored: true, title: "First Album"),
                        Album(id: 2, primary: "EP", monitored: true, title: "An EP"),
                        Album(id: 3, primary: "Single", monitored: true, title: "Hit"),
                        Album(id: 6, primary: "Album", secondary: ["Live"], monitored: true, title: "Live At Home"),
                        Album(id: 9, primary: "Album", monitored: false, title: "Owner Unmonitored")]
            s.catalogue = s.albums + [Album(id: 7, primary: "EP", monitored: false, title: "Later EP"),
                                      Album(id: 8, primary: "Single", monitored: false, title: "Later Single")]
            s.files = [File(id: 101, album: 1, size: 1000, title: "One", recording: "rec-101"),
                       File(id: 102, album: 1, size: 2000, title: "Two", recording: "rec-102"),
                       File(id: 103, album: 2, size: 500, title: "EP Song", recording: "rec-103"),
                       File(id: 104, album: 3, size: 300, title: "Hit", recording: "rec-104"),
                       File(id: 109, album: 9, size: 900, title: "Old", recording: "rec-109")]
        }
        install(root: root)
    }

    static func reply(_ o: Any, status: Int = 200) -> MockTransport.Response {
        .init(status: status, body: try! JSONSerialization.data(withJSONObject: o))
    }

    private func loseAnswer(_ what: String) throws {
        let lose = state.withLockUnchecked { s -> Bool in
            guard s.loseNextAnswer == what else { return false }
            s.loseNextAnswer = nil
            return true
        }
        if lose { throw URLError(.networkConnectionLost) }
    }

    func applyRefresh() {
        state.withLockUnchecked { s in
            let profile = s.profiles.first { $0["id"] as? Int == s.profileId } ?? [:]
            func allowed(_ field: String) -> Set<String> {
                Set((profile[field] as? [[String: Any]] ?? []).filter { $0["allowed"] as? Bool == true }
                    .compactMap { ($0["albumType"] as? [String: Any])?["name"] as? String })
            }
            let primary = allowed("primaryAlbumTypes"), secondary = allowed("secondaryAlbumTypes")
            func allows(_ a: Album) -> Bool {
                primary.contains(a.primary) && Set(a.secondary.isEmpty ? ["Studio"] : a.secondary).isSubset(of: secondary)
            }
            let files = s.files
            s.albums.removeAll { a in !allows(a) && !files.contains { $0.album == a.id } }
            for a in s.catalogue where allows(a) && !s.albums.contains(where: { $0.id == a.id }) {
                var added = a
                added.monitored = s.follow == "all"
                s.albums.append(added)
            }
        }
    }

    private func install(root: String) {
        let t = transport
        t.stub(pathSuffix: "/api/v1/rootfolder") { _ in Self.reply([["id": 1, "path": "/music/library"], ["id": 2, "path": "/music/samples"]]) }
        t.stub(pathSuffix: "/api/v1/artist/20") { [self] _ in
            if state.withLockUnchecked({ $0.artistFails }) { return .init(status: 503) }
            let p = state.withLockUnchecked { $0.profileId }
            return Self.reply(["id": 20, "artistName": "Owner", "foreignArtistId": Self.ownerMBID.rawValue, "monitored": true,
                               "tags": [Int](), "metadataProfileId": p, "monitorNewItems": "none",
                               "path": "\(root)/Owner", "rootFolderPath": root])
        }
        t.stub(pathSuffix: "/api/v1/metadataprofile") { [self] _ in Self.reply(state.withLockUnchecked { $0.profiles }) }
        t.stub(pathSuffix: "/api/v1/metadataprofile/schema") { _ in
            Self.reply(Self.profile(0, "", primary: [], secondary: []))
        }
        t.stub(method: "POST", pathSuffix: "/api/v1/metadataprofile") { [self] req in
            var body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let id = state.withLockUnchecked { $0.profiles.count + 40 }
            body["id"] = id
            let made = body
            state.withLockUnchecked { $0.profiles.append(made) }
            return Self.reply(made, status: 201)
        }
        t.stub(pathSuffix: "/api/v1/command") { [self] _ in Self.reply(state.withLockUnchecked { $0.commands }) }
        t.stub(pathSuffix: "/api/v1/album") { [self] _ in
            Self.reply(state.withLockUnchecked { s in s.albums.map { a -> [String: Any] in
                ["id": a.id, "title": a.title, "artistId": 20, "monitored": a.monitored, "albumType": a.primary,
                 "secondaryTypes": a.secondary, "statistics": ["trackFileCount": s.files.filter { $0.album == a.id }.count]] } })
        }
        for id in [1, 2, 3, 6, 7, 8, 9] {
            t.stub(pathSuffix: "/api/v1/album/\(id)") { [self] _ in
                guard let a = state.withLockUnchecked({ s in s.albums.first { $0.id == id } }) else { return .init(status: 404) }
                return Self.reply(["id": id, "title": a.title, "artistId": 20, "monitored": a.monitored, "albumType": a.primary,
                                   "secondaryTypes": a.secondary])
            }
        }
        let fileJSON: @Sendable (File) -> [String: Any] = { f in
            ["id": f.id, "artistId": 20, "albumId": f.album, "size": f.size, "path": "\(root)/Owner/A\(f.album)/\(f.id).flac",
             "quality": ["quality": ["name": "FLAC"]]]
        }
        t.stub(pathSuffix: "/api/v1/trackfile") { [self] _ in Self.reply(state.withLockUnchecked { $0.files.map(fileJSON) }) }
        for id in [101, 102, 103, 104, 109] {
            t.stub(pathSuffix: "/api/v1/trackfile/\(id)") { [self] _ in
                guard let f = state.withLockUnchecked({ s in s.files.first { $0.id == id } }) else { return .init(status: 404) }
                return Self.reply(fileJSON(f))
            }
        }
        t.stub(pathSuffix: "/api/v1/track") { [self] _ in
            Self.reply(state.withLockUnchecked { s in s.files.filter { !s.untracked.contains($0.id) }.map { ["id": $0.id + 1000, "albumId": $0.album, "trackFileId": $0.id,
                                                            "title": $0.title, "foreignRecordingId": $0.recording] } })
        }
        t.stub(pathSuffix: "/api/v1/command/9") { [self] _ in
            Self.reply(["id": 9, "name": "RefreshArtist", "status": state.withLockUnchecked { $0.refreshStatus }])
        }
        t.stub(method: "POST", pathSuffix: "/api/v1/command") { [self] req in
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            if state.withLockUnchecked({ s -> Bool in
                guard s.failCommands > 0 else { return false }
                s.failCommands -= 1
                return true
            }) { return .init(status: 503) }
            if (body["name"] as? String) == "RefreshArtist" {
                applyRefresh()
                state.withLockUnchecked { s in
                    if let back = s.resetProfileOnRefresh { s.profileId = back; s.resetProfileOnRefresh = nil }
                    if let back = s.resetProfileAlways { s.profileId = back }
                }
                try loseAnswer("refresh")
            }
            return Self.reply(["id": 9], status: 201)
        }
        t.stub(method: "PUT", pathSuffix: "/api/v1/artist/editor") { [self] req in
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            state.withLockUnchecked { s in if let p = body["metadataProfileId"] as? Int, !s.ignoreEditor { s.profileId = p } }
            if state.withLockUnchecked({ $0.switchOffAtEditor }) {
                UserDefaults(suiteName: suite)?.set(false, forKey: LidarrWriteGate.monitoringChangesKey(scope: client.instanceScope))
            }
            try loseAnswer("editor")
            return Self.reply([[String: Any]]())
        }
        t.stub(method: "PUT", pathSuffix: "/api/v1/album/monitor") { [self] req in
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let ids = body["albumIds"] as! [Int], monitored = body["monitored"] as! Bool
            state.withLockUnchecked { s in for i in s.albums.indices where ids.contains(s.albums[i].id) { s.albums[i].monitored = monitored } }
            try loseAnswer("monitor")
            return Self.reply([[String: Any]]())
        }
        t.stub(method: "DELETE", pathSuffix: "/api/v1/trackfile/bulk") { [self] req in
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let ids = body["trackFileIds"] as! [Int]
            state.withLockUnchecked { s in s.files.removeAll { ids.contains($0.id) } }
            try loseAnswer("delete")
            return Self.reply([String: Any]())
        }
    }

    func changer(checks: Int = 2) -> MonitoringChanger {
        MonitoringChanger(lidarr: client, gate: gate, ledger: ledger, roots: {
            WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: 2)
        }, checks: checks, pause: .zero)
    }

    var writes: [(String, [String: Any])] {
        transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" }.map { r in
            ("\(r.httpMethod!) \(r.url!.path.replacingOccurrences(of: "/api/v1/", with: ""))",
             (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:])
        }
    }
    var deletes: [[Int]] { writes.filter { $0.0 == "DELETE trackfile/bulk" }.map { $0.1["trackFileIds"] as? [Int] ?? [] } }
    var monitored: Set<Int> { state.withLockUnchecked { Set($0.albums.filter(\.monitored).map(\.id)) } }
    var fileIds: Set<Int> { state.withLockUnchecked { Set($0.files.map(\.id)) } }
}

/// Round 24 (owner, 2026-11-08, D237–D244): "Change what's monitored" asks before anything is deleted (Keep by default),
/// keeps or deletes exactly what it showed, records what it kept, cleans up later only what's still unmatched, can be
/// put back, and resumes after a lost answer without sending again what Lidarr already did.
@Suite struct MonitoringChangeTests {
    static let nothingKept = MonitoringKeepList()

    @Test func reduce_asksBeforeAnyDelete() async throws {
        let fake = await MonitoringLidarr()
        let preview = try await fake.changer().preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        #expect(fake.writes.isEmpty, "the preview only reads")
        #expect(preview.asksDeleteOrKeep)
        #expect(Set(preview.unmonitorAlbumIds) == [2, 3, 6], "the EP, the Single and the live album stop being monitored")
        #expect(preview.albumCount == 3)
        #expect(Set(preview.files.map(\.id)) == [103, 104])
        #expect(preview.songCount == 2 && preview.bytes == 800)
        #expect(preview.currentTypes == nil, "the owner's own profile reads as Custom")
        #expect((try await fake.ledger.monitoringBook).intents.isEmpty, "nothing recorded until the owner answers")
    }

    @Test func reduce_keepIsDefault() async throws {
        #expect(ReduceChoice.default == .keep)
        let fake = await MonitoringLidarr()
        let preview = try await fake.changer().preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        #expect(preview.defaultChoice == .keep)
    }

    @Test func reduce_keepRecordsUnmonitoredSet() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        let outcome = try await changer.apply(preview, choice: .keep)
        #expect(outcome == .finished)
        #expect(fake.deletes.isEmpty, "Keep deletes nothing")
        #expect(fake.state.withLockUnchecked { $0.profileId } == 30, "Magpie's Albums profile")
        #expect(!fake.monitored.contains(2) && !fake.monitored.contains(3), "the kept albums are unmonitored")
        #expect(fake.monitored.contains(1))
        let kept = try #require(try await fake.ledger.monitoringBook.kept(artistId: 20))
        #expect(Set(kept.albumIds) == [2, 3])
        #expect(Set(kept.files) == [OwnedFile(id: 103, albumId: 2, size: 500), OwnedFile(id: 104, albumId: 3, size: 300)])
        #expect(fake.fileIds == [101, 102, 103, 104, 109])
        let editor = try #require(fake.writes.first { $0.0 == "PUT artist/editor" }?.1)
        #expect(Set(editor.keys) == ["artistIds", "metadataProfileId"], "no root folder, no move, no monitored")
        // The unmonitor went before the profile (so Lidarr never searches for what is falling out).
        let order = fake.writes.map(\.0)
        #expect(order.firstIndex(of: "PUT album/monitor")! < order.firstIndex(of: "PUT artist/editor")!)
    }

    @Test func reduce_deleteWritesOnlyShownIds() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        // "Hit" is favourited: it stays.
        let keep = MonitoringKeepList(recordings: [], titles: ["Hit"], albumTitles: [])
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: keep)
        #expect(preview.excludedFileIds == [104])
        #expect(preview.deletable.map(\.id) == [103])
        let outcome = try await changer.apply(preview, choice: .delete, keep: Self.nothingKept)
        #expect(outcome == .finished)
        #expect(fake.deletes == [[103]], "exactly the shown file, never the favourite or the owner's other files")
        #expect(fake.fileIds == [101, 102, 104, 109])
        #expect(try await fake.ledger.monitoringBook.intents.allSatisfy { !$0.isOpen })
    }

    @Test func reduce_noFilesFallingOut_asksNothing() async throws {
        let fake = await MonitoringLidarr()
        fake.state.withLockUnchecked { $0.files.removeAll { [103, 104].contains($0.id) } }
        let preview = try await fake.changer().preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        #expect(!preview.asksDeleteOrKeep)
        #expect(preview.reduces)
    }

    @Test func more_monitorsAndSearchesWhatTheNewChoiceBringsIn() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.everything, keep: Self.nothingKept)
        #expect(Set(preview.unmonitorAlbumIds) == [6], "only the live album falls out")
        _ = try await changer.apply(preview, choice: .keep)
        #expect(fake.state.withLockUnchecked { $0.profileId } == 33)
        #expect(fake.monitored.isSuperset(of: [7, 8]), "the EP and Single the refresh listed are monitored")
        #expect(!fake.monitored.contains(9), "an album the owner unmonitored before stays as he left it")
        let search = try #require(fake.writes.first { $0.0 == "POST command" && $0.1["name"] as? String == "AlbumSearch" }?.1)
        #expect(Set(search["albumIds"] as? [Int] ?? []) == [7, 8])
    }

    @Test func cleanup_neverDeletesFavouritedOrInPlaylist() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        _ = try await changer.apply(try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept),
                                    choice: .keep)
        // Later: the EP's song is in a playlist (its recording), the Single's isn't.
        let keep = MonitoringKeepList(recordings: ["rec-103"], titles: [], albumTitles: [])
        let cleanup = try await changer.cleanupPreview(artistId: 20, keep: keep)
        #expect(cleanup.files.map(\.id) == [104])
        #expect(cleanup.rows.first { $0.file.id == 103 }?.kept == true)
        #expect(try await changer.cleanUp(cleanup, keep: Self.nothingKept) == .finished)
        #expect(fake.deletes == [[104]])
        #expect(fake.fileIds.contains(103))
        let kept = try await fake.ledger.monitoringBook.kept(artistId: 20)
        #expect(kept?.files.map(\.id) == [103], "what's left stays offered")
    }

    @Test func cleanup_skipsAlbumsMonitoredAgainOrFilesChanged() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        _ = try await changer.apply(try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept),
                                    choice: .keep)
        fake.state.withLockUnchecked { s in
            if let i = s.albums.firstIndex(where: { $0.id == 2 }) { s.albums[i].monitored = true }   // the owner monitors the EP again
            if let i = s.files.firstIndex(where: { $0.id == 104 }) { s.files[i].size = 301 }        // the Single's file changed
        }
        let cleanup = try await changer.cleanupPreview(artistId: 20, keep: Self.nothingKept)
        #expect(cleanup.files.isEmpty)
        #expect(fake.writes.filter { $0.0.hasPrefix("DELETE") }.isEmpty)
    }

    @Test func revert_restoresRecordedProfile() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        _ = try await changer.apply(try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept),
                                    choice: .keep)
        // A second change keeps the owner's original as the one to go back to.
        _ = try await changer.apply(try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsEPs, keep: Self.nothingKept),
                                    choice: .keep)
        #expect(fake.state.withLockUnchecked { $0.profileId } == 32)
        #expect(try await changer.current(artistId: 20).canRevert)
        #expect(try await changer.revert(artistId: 20) == .finished)
        #expect(fake.state.withLockUnchecked { $0.profileId } == 5, "the owner's own profile, recorded before Magpie's first change")
        #expect(try await changer.current(artistId: 20).canRevert == false)
    }

    @Test func revert_leavesAProfileTheOwnerChanged() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        _ = try await changer.apply(try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept),
                                    choice: .keep)
        fake.state.withLockUnchecked { $0.profileId = 5 }   // the owner put it back himself
        let before = fake.writes.count
        await #expect(throws: MonitoringChangeError.nothingToRevert) { _ = try await changer.revert(artistId: 20) }
        #expect(fake.writes.count == before)
    }

    @Test func runner_resumesAfterLostAnswer() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { $0.loseNextAnswer = "monitor" }
        #expect(try await changer.apply(preview, choice: .delete, keep: Self.nothingKept) == .pending)
        let open = try #require(try await fake.ledger.monitoringBook.open(artistId: 20).first)
        #expect(open.sending == .unmonitored, "the step that was sent is recorded")
        #expect(fake.writes.filter { $0.0 == "PUT album/monitor" }.count == 1)
        // Resumed: Lidarr is read first; the unmonitor it already did isn't sent again.
        fake.state.withLockUnchecked { $0.loseNextAnswer = "delete" }
        #expect(await changer.resume(artistId: 20, keep: Self.nothingKept) == .pending)
        #expect(fake.writes.filter { $0.0 == "PUT album/monitor" }.count == 1)
        #expect(fake.deletes.count == 1)
        // The delete's answer was lost too: the files are read again (gone), so nothing is deleted twice.
        #expect(await changer.resume(artistId: 20, keep: Self.nothingKept) == .finished)
        #expect(fake.deletes.count == 1)
        #expect(fake.fileIds == [101, 102, 109])
    }

    @Test func refusedWhenTheSwitchIsOff_nothingSentOrSaved() async throws {
        let fake = await MonitoringLidarr(monitoringOn: false)
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        await #expect(throws: MonitoringChangeError.switchOff) { _ = try await changer.apply(preview, choice: .keep) }
        #expect(fake.writes.isEmpty)
        #expect(try await fake.ledger.monitoringBook.intents.isEmpty)
    }

    @Test func refusedForAnArtistOutsideTheMainRoot() async throws {
        let fake = await MonitoringLidarr(root: "/music/samples")
        await #expect(throws: MonitoringChangeError.notInMainRoot) {
            _ = try await fake.changer().preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        }
        #expect(fake.writes.isEmpty)
    }

    @Test func nothingIsSentWhenTheIntentCantBeSaved() async throws {
        // The ledger's folder is a file: every save fails.
        let blocker = FileManager.default.temporaryDirectory.appending(path: "Blocked-\(UUID().uuidString)")
        try Data().write(to: blocker)
        let fake = await MonitoringLidarr(ledgerURL: blocker.appending(path: "ledger.json"))
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        await #expect(throws: MonitoringChangeError.notSaved) { _ = try await changer.apply(preview, choice: .keep) }
        #expect(fake.writes.isEmpty)
    }

    @Test func aStalePreviewIsAskedAgain() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { $0.profileId = 33 }   // changed in Lidarr meanwhile
        await #expect(throws: MonitoringChangeError.stale) { _ = try await changer.apply(preview, choice: .delete, keep: Self.nothingKept) }
        #expect(fake.writes.isEmpty)
    }

    @Test func cleanup_capsPerCall_inBatchesOfFifty() async throws {
        let fake = await MonitoringLidarr()
        fake.state.withLockUnchecked { s in
            for id in 300..<360 { s.files.append(.init(id: id, album: 2, size: 100, title: "Song \(id)", recording: "rec-\(id)")) }
        }
        for id in 300..<360 {
            fake.transport.stub(pathSuffix: "/api/v1/trackfile/\(id)") { [fake] _ in
                guard fake.state.withLockUnchecked({ s in s.files.contains { $0.id == id } }) else { return .init(status: 404) }
                return MonitoringLidarr.reply(["id": id, "artistId": 20, "albumId": 2, "size": 100,
                                               "path": "/music/library/Owner/A2/\(id).flac"])
            }
        }
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        #expect(preview.deletable.count == 62)
        #expect(try await changer.apply(preview, choice: .delete, keep: Self.nothingKept) == .finished)
        #expect(fake.deletes.map(\.count) == [50, 12])
        #expect(Set(fake.deletes.flatMap { $0 }) == Set(preview.deletable.map(\.id)))
    }

    @Test func theBookIsPerLidarrAndSurvivesARelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Book-\(UUID().uuidString)")
        let url = dir.appending(path: "lidarr-ledger.json")
        let a = Ledger(fileURL: url, instance: "lidarr-a"), b = Ledger(fileURL: url, instance: "lidarr-b")
        let intent = MonitoringIntent(kind: .monitoringChange, artistId: 20, artistMbid: MonitoringLidarr.ownerMBID,
                                      previousProfileId: 5, targetProfileId: 30, createdAt: Date())
        try await a.saveIntent(intent)
        try await a.setKept(artistId: 20, UnmonitoredKept(artistId: 20, artistMbid: MonitoringLidarr.ownerMBID, albumIds: [2],
                                                          files: [OwnedFile(id: 103, albumId: 2, size: 500)], recordedAt: Date()))
        #expect(try await b.monitoringBook.intents.isEmpty, "another Lidarr never sees it")
        let again = Ledger(fileURL: url, instance: "lidarr-a")
        #expect(try await again.monitoringBook.intents.map(\.id) == [intent.id])
        #expect(try await again.monitoringBook.kept(artistId: 20)?.files.map(\.id) == [103])
        #expect(try await again.entries.isEmpty, "the album entries never see an owner's artist")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "lidarr-ledger-monitoring.json").path))
    }

    // MARK: - Fix round 1

    /// I3: sign-out forgets the book of every Lidarr with nothing open, and keeps a Lidarr's whose change is unfinished.
    @Test func i3_signOutForgetsFinishedMonitoring() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Forget-\(UUID().uuidString)")
        let url = Ledger.defaultURL(in: dir)
        let done = Ledger(fileURL: url, instance: "lidarr-a"), open = Ledger(fileURL: url, instance: "lidarr-b")
        var finished = MonitoringIntent(kind: .monitoringChange, artistId: 20, artistMbid: MonitoringLidarr.ownerMBID,
                                        previousProfileId: 5, targetProfileId: 30, createdAt: Date())
        finished.step = .done
        try await done.saveIntent(finished)
        try await done.setKept(artistId: 20, UnmonitoredKept(artistId: 20, artistMbid: MonitoringLidarr.ownerMBID, albumIds: [2],
                                                             files: [OwnedFile(id: 103, albumId: 2, size: 500)], recordedAt: Date()))
        try await open.saveIntent(MonitoringIntent(kind: .monitoringChange, artistId: 21, artistMbid: MonitoringLidarr.ownerMBID,
                                                   previousProfileId: 5, targetProfileId: 30, createdAt: Date()))
        Ledger.forgetFinished(in: dir)
        #expect(try await done.monitoringBook == MonitoringBook(), "nothing open: forgotten, kept set too")
        #expect(try await open.monitoringBook.intents.count == 1, "an unfinished change stays")
        // Once the last open change is closed, the file goes.
        var last = try #require(try await open.monitoringBook.intents.first)
        last.step = .abandoned
        try await open.saveIntent(last)
        Ledger.forgetFinished(in: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "Magpie/lidarr-ledger-monitoring.json").path))
    }

    /// I1: the Magpie profile is made only once the intent is saved: a save that fails sends nothing, not even the profile.
    @Test func i1_noProfileIsMadeBeforeTheIntentIsSaved() async throws {
        let blocker = FileManager.default.temporaryDirectory.appending(path: "Blocked-\(UUID().uuidString)")
        try Data().write(to: blocker)
        let fake = await MonitoringLidarr(ledgerURL: blocker.appending(path: "ledger.json"))
        fake.state.withLockUnchecked { $0.profiles.removeAll { $0["id"] as? Int == 30 } }
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        await #expect(throws: MonitoringChangeError.notSaved) { _ = try await changer.apply(preview, choice: .keep) }
        #expect(fake.writes.isEmpty, "\(fake.writes.map(\.0))")
    }

    /// I1: a missing profile is made after the save, and its id recorded before the first change write.
    @Test func i1_aMissingProfileIsMadeAfterTheSaveAndRecorded() async throws {
        let fake = await MonitoringLidarr()
        fake.state.withLockUnchecked { $0.profiles.removeAll { $0["id"] as? Int == 30 } }
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        #expect(try await changer.apply(preview, choice: .keep) == .finished)
        #expect(fake.writes.first?.0 == "POST metadataprofile")
        let made = try #require(fake.state.withLockUnchecked { $0.profiles.last?["id"] as? Int })
        #expect(fake.state.withLockUnchecked { $0.profileId } == made)
        #expect(try await fake.ledger.monitoringBook.intents.first?.targetProfileId == made)
    }

    /// I2: a clean-up deletes only kept files, whatever rows the caller hands it.
    @Test func i2_cleanUpDeletesOnlyKeptFiles() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        _ = try await changer.apply(try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept),
                                    choice: .keep)
        var cleanup = try await changer.cleanupPreview(artistId: 20, keep: Self.nothingKept)
        // A row for the album the owner unmonitored himself (never kept on reducing).
        cleanup.rows.append(.init(file: OwnedFile(id: 109, albumId: 9, size: 900), title: "Old", album: "Owner Unmonitored",
                                  recording: nil, kept: false))
        #expect(try await changer.cleanUp(cleanup, keep: Self.nothingKept) == .finished)
        #expect(Set(fake.deletes.flatMap { $0 }) == [103, 104])
        #expect(fake.fileIds.contains(109))
    }

    /// I2: Delete them deletes only files of albums that stop being monitored, whatever files the preview carries.
    @Test func i2_deleteThemOnlyFilesOfAlbumsFallingOut() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        var preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        preview.files.append(OwnedFile(id: 109, albumId: 9, size: 900))
        preview.files.append(OwnedFile(id: 101, albumId: 1, size: 1000))
        #expect(try await changer.apply(preview, choice: .delete, keep: Self.nothingKept) == .finished)
        #expect(Set(fake.deletes.flatMap { $0 }) == [103, 104])
        #expect(fake.fileIds == [101, 102, 109])
    }

    /// I4: a change that stopped partway (given up after repeated failures) can still be put back while the artist is on
    /// the profile it set.
    @Test func i4_aChangeThatStoppedPartwayCanBePutBack() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { $0.failCommands = 100 }
        var outcome = try await changer.apply(preview, choice: .keep)
        for _ in 0..<MonitoringChanger.maxFailures where outcome == .pending {
            outcome = await changer.resume(artistId: 20) ?? .pending
        }
        #expect(outcome == .abandoned)
        #expect(fake.state.withLockUnchecked { $0.profileId } == 30)
        let now = try await changer.current(artistId: 20)
        #expect(now.stoppedPartway && now.canRevert)
        fake.state.withLockUnchecked { $0.failCommands = 0 }
        #expect(try await changer.revert(artistId: 20) == .finished)
        #expect(fake.state.withLockUnchecked { $0.profileId } == 5)
    }

    /// I5: nothing is recorded or sent while a Try of Magpie's is under way for the artist.
    @Test func i5_aTryUnderWayRefusesTheChange() async throws {
        let fake = await MonitoringLidarr()
        try await fake.ledger.record(LedgerEntry(lidarrArtistId: 20, albumId: 7, rgMbid: MBID("00000000-0000-0000-0000-000000000007")!,
                                                 createdArtist: false, wasMonitoredBefore: false, root: "/music/library",
                                                 mode: .fallback, send: .applied, requestId: "r-7"))
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        await #expect(throws: MonitoringChangeError.tryUnderWay) { _ = try await changer.apply(preview, choice: .keep) }
        #expect(fake.writes.isEmpty)
        #expect(try await fake.ledger.monitoringBook.intents.isEmpty)
    }

    /// Seen on the dev stack: a refresh Lidarr had under way saved the artist with its old profile after the editor write.
    /// The profile is read again after the confirmed refresh and sent again.
    @Test func aProfileARefreshPutBackIsSentAgain() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { $0.resetProfileOnRefresh = 5 }
        #expect(try await changer.apply(preview, choice: .keep) == .pending)
        #expect(await changer.resume(artistId: 20) == .finished)
        #expect(fake.state.withLockUnchecked { $0.profileId } == 30)
        #expect(fake.writes.filter { $0.0 == "PUT artist/editor" }.count == 2)
    }

    // MARK: - Fix round 3

    /// H-M1: a later choice that monitors the kept albums' type again ends their clean-up: not offered, and refused.
    @Test func cleanup_refusedAfterWideningIncludesTheAlbumType() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        _ = try await changer.apply(try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept),
                                    choice: .keep)
        _ = try await changer.apply(try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsEPs, keep: Self.nothingKept),
                                    choice: .keep)
        let kept = try #require(try await fake.ledger.monitoringBook.kept(artistId: 20))
        #expect(kept.files.map(\.id) == [104], "the EP's file left the kept set")
        let cleanup = try await changer.cleanupPreview(artistId: 20, keep: Self.nothingKept)
        #expect(cleanup.files.map(\.id) == [104])
        #expect(try await changer.cleanUp(cleanup, keep: Self.nothingKept) == .finished)
        #expect(fake.deletes == [[104]])
        #expect(fake.fileIds.contains(103))
    }

    /// H-M1: Revert ends every clean-up of the artist.
    @Test func cleanup_notOfferedAfterRevert() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        _ = try await changer.apply(try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept),
                                    choice: .keep)
        #expect(await changer.hasKept(artistId: 20))
        #expect(try await changer.revert(artistId: 20) == .finished)
        #expect(await changer.hasKept(artistId: 20) == false)
        #expect(try await changer.cleanupPreview(artistId: 20, keep: Self.nothingKept).rows.isEmpty)
    }

    /// H-M3: resuming on its own never starts a delete; with a fresh keep list it drops what the owner keeps now.
    @Test func resume_neverDeletesWithoutAFreshKeepList() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { $0.loseNextAnswer = "monitor" }
        #expect(try await changer.apply(preview, choice: .delete, keep: Self.nothingKept) == .pending)
        #expect(await changer.resume(artistId: 20) == .waitingForKeepList)
        #expect(fake.deletes.isEmpty, "no delete without a keep list")
        #expect(await changer.waitsForKeepList(artistId: 20))
        await changer.resumeAll()
        #expect(fake.deletes.isEmpty)
        // "Hit" is a favourite now: it stays.
        #expect(await changer.resume(artistId: 20, keep: MonitoringKeepList(titles: ["Hit"])) == .finished)
        #expect(fake.deletes == [[103]])
        #expect(fake.fileIds.contains(104))
    }

    /// H-M3: a file no track row names can't be matched against the keep list: it is kept.
    @Test func kept_aFileWithNoTrackIsKept() async throws {
        let fake = await MonitoringLidarr()
        fake.state.withLockUnchecked { $0.untracked = [104] }
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        #expect(preview.excludedFileIds == [104])
        #expect(try await changer.apply(preview, choice: .delete, keep: Self.nothingKept) == .finished)
        #expect(fake.deletes == [[103]])
    }

    /// H-L1: sizes near Int64.max from a server never trap.
    @Test func preview_bytesNeverTrapsOnHugeSizes() async throws {
        let fake = await MonitoringLidarr()
        fake.state.withLockUnchecked { s in for i in s.files.indices { s.files[i].size = Int64.max } }
        let preview = try await fake.changer().preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        #expect(preview.bytes == Int64.max)
        #expect(ByteTotal.of([Int64.max, Int64.max, -5, 3]) == Int64.max)
    }

    /// H-L2: the switch turned off mid-change: paused, open, never counted or given up; on again, it finishes.
    @Test func switchOffMidChangeStaysPending() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { $0.switchOffAtEditor = true }
        #expect(try await changer.apply(preview, choice: .keep) == .paused)
        let open = try #require(try await fake.ledger.monitoringBook.open(artistId: 20).first)
        #expect(open.failures == 0 && open.step != .abandoned)
        #expect(await changer.resume(artistId: 20) == .paused)
        fake.state.withLockUnchecked { $0.switchOffAtEditor = false }
        await fake.gate.setMonitoringChangesEnabled(true)
        #expect(await changer.resume(artistId: 20) == .finished)
    }

    /// H-L3: one file of a batch fails its check: it is kept (recorded), the rest are deleted.
    @Test func cleanup_aRefusedFileIsKeptAndTheRestGo() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        // 104 changes size after the owner confirmed: the gate refuses it.
        fake.state.withLockUnchecked { s in if let i = s.files.firstIndex(where: { $0.id == 104 }) { s.files[i].size = 301 } }
        #expect(try await changer.apply(preview, choice: .delete, keep: Self.nothingKept) == .finished)
        #expect(Set(fake.deletes.flatMap { $0 }) == [103])
        #expect(fake.fileIds.contains(104))
        let done = try #require(try await fake.ledger.monitoringBook.intents.first { $0.kind == .unmatchedCleanup })
        #expect(done.excludedFileIds.contains(104) && done.step == .done, "recorded as kept, not dropped silently")
    }

    // MARK: - Fix round 2

    /// R1: a later change that stopped before its profile was sent never hides the one that set the profile: Revert still
    /// goes back to the owner's, and the next change records the owner's as the one to go back to.
    @Test func r1_aLaterStoppedChangeDoesntHideTheOneThatSetTheProfile() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        _ = try await changer.apply(try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept),
                                    choice: .keep)
        #expect(fake.state.withLockUnchecked { $0.profileId } == 30)
        var stopped = MonitoringIntent(kind: .monitoringChange, artistId: 20, artistMbid: MonitoringLidarr.ownerMBID,
                                       previousProfileId: 30, targetProfileId: 32, targetTypes: MonitoringLidarr.albumsEPs,
                                       createdAt: Date().addingTimeInterval(60))
        stopped.step = .abandoned
        try await fake.ledger.saveIntent(stopped)
        #expect(try await changer.current(artistId: 20).canRevert)
        let next = try await changer.preview(artistId: 20, types: MonitoringLidarr.everything, keep: Self.nothingKept)
        #expect(next.previousProfileId == 5, "the owner's profile, not Magpie's")
    }

    /// m2: Lidarr puts the profile back on every pass: exactly 5 editor writes, then the change stops (abandoned).
    @Test func m2_aProfileLidarrAlwaysPutsBackGivesUpAfterFive() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { $0.resetProfileAlways = 5 }
        var outcome = try await changer.apply(preview, choice: .keep)
        for _ in 0..<10 where outcome == .pending { outcome = await changer.resume(artistId: 20) ?? .pending }
        #expect(outcome == .abandoned)
        #expect(fake.writes.filter { $0.0 == "PUT artist/editor" }.count == 5)
    }

    /// m3: an editor write Lidarr doesn't take is a counted failure: 5 writes, then abandoned.
    @Test func m3_aProfileLidarrDoesntTakeIsCounted() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { $0.ignoreEditor = true }
        var outcome = try await changer.apply(preview, choice: .keep)
        for _ in 0..<10 where outcome == .pending { outcome = await changer.resume(artistId: 20) ?? .pending }
        #expect(outcome == .abandoned)
        #expect(fake.writes.filter { $0.0 == "PUT artist/editor" }.count == 5)
    }

    /// m3: a refresh Lidarr reports failed is a counted failure: 5 refreshes, then abandoned.
    @Test func m3_aFailedRefreshIsCounted() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { $0.refreshStatus = "failed" }
        var outcome = try await changer.apply(preview, choice: .keep)
        for _ in 0..<10 where outcome == .pending { outcome = await changer.resume(artistId: 20) ?? .pending }
        #expect(outcome == .abandoned)
        #expect(fake.writes.filter { $0.0 == "POST command" && $0.1["name"] as? String == "RefreshArtist" }.count == 5)
    }

    /// M2: after a lost answer, a profile that can't be read is never sent blind.
    @Test func m2_aFailedProfileReadNeverSends() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { $0.loseNextAnswer = "monitor" }
        #expect(try await changer.apply(preview, choice: .keep) == .pending)
        fake.state.withLockUnchecked { $0.artistFails = true }
        #expect(await changer.resume(artistId: 20) == .pending)
        let open = try #require(try await fake.ledger.monitoringBook.open(artistId: 20).first)
        #expect(open.sending != .profileSet, "the profile wasn't sent blind")
        #expect(!fake.writes.contains { $0.0 == "PUT artist/editor" })
        fake.state.withLockUnchecked { $0.artistFails = false }
        #expect(await changer.resume(artistId: 20) == .finished)
    }

    /// M2: a refresh whose answer was lost is looked for in Lidarr's commands before one is sent again.
    @Test func m2_aLostRefreshIsReadBeforeSendingAgain() async throws {
        let fake = await MonitoringLidarr()
        let changer = fake.changer()
        let preview = try await changer.preview(artistId: 20, types: MonitoringLidarr.albumsOnly, keep: Self.nothingKept)
        fake.state.withLockUnchecked { s in
            s.loseNextAnswer = "refresh"
            s.commands = [["id": 9, "name": "RefreshArtist", "status": "started", "body": ["artistId": 20]]]
        }
        #expect(try await changer.apply(preview, choice: .keep) == .pending)
        #expect(await changer.resume(artistId: 20) == .finished)
        let refreshes = fake.writes.filter { $0.0 == "POST command" && $0.1["name"] as? String == "RefreshArtist" }
        #expect(refreshes.count == 1, "the running refresh was found, not sent again")
    }


    @Test func presetFromAMagpieProfile() async throws {
        let fake = await MonitoringLidarr()
        fake.state.withLockUnchecked { $0.profileId = 32 }
        let current = try await fake.changer().current(artistId: 20)
        #expect(current.types == MonitoringLidarr.albumsEPs)
        fake.state.withLockUnchecked { $0.profileId = 5 }
        #expect(try await fake.changer().current(artistId: 20).types == nil)
    }
}
