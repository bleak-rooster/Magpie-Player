import Foundation
import os
import Testing
import LidarrKit
import MagpieCore
import MagpieTestSupport
@testable import Requests

/// A Lidarr for the singles switch: metadata profiles with their allowed types, one owner-added artist (20) and a
/// refresh that behaves as Lidarr's: albums the artist's profile no longer allows and that have no files are dropped,
/// and the releases the profile now allows appear (monitored when following is "all", or always when `newMonitored`).
final class SinglesLidarr: @unchecked Sendable {
    struct Album { var id: Int; var rg: MBID; var primary: String; var secondary: [String]; var status = "Official"
                   var monitored: Bool; var files = 0 }
    struct State: @unchecked Sendable {
        var profiles: [[String: Any]] = []
        var profileId = 5
        var follow = "all"
        var albums: [Album] = []
        /// What the artist has in MusicBrainz: what a refresh lists, if the profile allows it.
        var catalogue: [Album] = []
        var refreshStatus = "completed"
        var refreshReturnsId = true
        var refreshPending = false
        var newMonitored = false
        var failNextEditor = 0
    }
    let transport = MockTransport()
    let client: LidarrClient
    let ledger: Ledger
    let gate: LidarrWriteGate
    let store: SinglesSwitchStore
    let state = OSAllocatedUnfairLock(initialState: State())
    static let target = MBID("55555555-5555-4555-8555-555555555555")!
    static let otherSingle = MBID("66666666-6666-4666-8666-666666666666")!
    static let album = mbid(901), live = mbid(906), compilation = mbid(907), promo = mbid(908)

    static func profile(_ id: Int, _ name: String, primary: Set<String>, secondary: Set<String>, statuses: Set<String>) -> [String: Any] {
        ["id": id, "name": name,
         "primaryAlbumTypes": ["Album", "EP", "Single", "Broadcast", "Other"].enumerated().map {
             ["albumType": ["id": $0.offset, "name": $0.element], "allowed": primary.contains($0.element)] },
         "secondaryAlbumTypes": ["Studio", "Compilation", "Soundtrack", "Live", "Remix"].enumerated().map {
             ["albumType": ["id": $0.offset, "name": $0.element], "allowed": secondary.contains($0.element)] },
         "releaseStatuses": ["Official", "Promotion", "Bootleg"].enumerated().map {
             ["releaseStatus": ["id": $0.offset, "name": $0.element], "allowed": statuses.contains($0.element)] }]
    }

    /// The owner's profile: albums and EPs, with Studio, Live and Compilation, Official and Promotion releases.
    nonisolated(unsafe) static let ownerProfile = profile(5, "Owner Profile", primary: ["Album", "EP"], secondary: ["Studio", "Live", "Compilation"],
                                      statuses: ["Official", "Promotion"])

    init(changesOn: Bool = true, storeURL: URL? = nil, checks: Int = 2) async {
        client = LidarrClient(base: ArtistLidarrTests.base, apiKey: "devkey", transport: transport)
        ledger = Ledger(fileURL: nil, instance: client.instanceScope)
        let dir = FileManager.default.temporaryDirectory.appending(path: "Singles-\(UUID().uuidString)")
        let store = SinglesSwitchStore(fileURL: storeURL ?? dir.appending(path: "singles.json"))
        self.store = store
        gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: "Singles.\(UUID().uuidString)",
                               confinement: WriteConfinement(ledger: ledger, roots: {
                                   WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: nil, findTagId: nil)
                               }, singlesOriginal: { await store.original(artistId: $0) }))
        await gate.setEnabled(changesOn)
        state.withLockUnchecked { s in
            s.profiles = [Self.ownerProfile]
            s.albums = [Album(id: 1, rg: Self.album, primary: "Album", secondary: [], monitored: true, files: 10),
                        Album(id: 6, rg: Self.live, primary: "Album", secondary: ["Live"], monitored: true),
                        Album(id: 7, rg: Self.compilation, primary: "Album", secondary: ["Compilation"], monitored: true),
                        Album(id: 8, rg: Self.promo, primary: "EP", secondary: [], status: "Promotion", monitored: true)]
            s.catalogue = s.albums + [Album(id: 2, rg: Self.target, primary: "Single", secondary: [], monitored: false),
                                      Album(id: 3, rg: Self.otherSingle, primary: "Single", secondary: [], monitored: false)]
        }
        install()
    }

    static func reply(_ o: Any, status: Int = 200) -> MockTransport.Response {
        .init(status: status, body: try! JSONSerialization.data(withJSONObject: o))
    }

    private func allows(_ profile: [String: Any], _ a: Album) -> Bool {
        func allowed(_ field: String, _ key: String) -> Set<String> {
            Set((profile[field] as? [[String: Any]] ?? []).filter { $0["allowed"] as? Bool == true }
                .compactMap { ($0[key] as? [String: Any])?["name"] as? String })
        }
        let secondary = a.secondary.isEmpty ? ["Studio"] : a.secondary
        return allowed("primaryAlbumTypes", "albumType").contains(a.primary)
            && Set(secondary).isSubset(of: allowed("secondaryAlbumTypes", "albumType"))
            && allowed("releaseStatuses", "releaseStatus").contains(a.status)
    }

    /// Lidarr's refresh of artist 20 under its profile now.
    func applyRefresh() {
        state.withLockUnchecked { s in
            guard let profile = s.profiles.first(where: { $0["id"] as? Int == s.profileId }) else { return }
            s.albums.removeAll { !allows(profile, $0) && $0.files == 0 }
            for a in s.catalogue where allows(profile, a) && !s.albums.contains(where: { $0.rg == a.rg }) {
                var added = a
                added.monitored = s.newMonitored || s.follow == "all"
                s.albums.append(added)
            }
        }
    }

    private func install() {
        let t = transport
        t.stub(pathSuffix: "/api/v1/artist/20") { [self] _ in
            let (p, f) = state.withLockUnchecked { ($0.profileId, $0.follow) }
            return Self.reply(["id": 20, "artistName": "Owner", "foreignArtistId": ArtistLidarrTests.ownerMBID.rawValue, "monitored": true,
                          "tags": [Int](), "metadataProfileId": p, "monitorNewItems": f, "path": "/music/library/Owner"])
        }
        t.stub(pathSuffix: "/api/v1/metadataprofile") { [self] _ in Self.reply(state.withLockUnchecked { $0.profiles }) }
        t.stub(method: "POST", pathSuffix: "/api/v1/metadataprofile") { [self] req in
            var body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let id = state.withLockUnchecked { $0.profiles.count + 20 }
            body["id"] = id
            let made = body
            state.withLockUnchecked { $0.profiles.append(made) }
            return Self.reply(made, status: 201)
        }
        t.stub(pathSuffix: "/api/v1/album") { [self] _ in
            Self.reply(state.withLockUnchecked { s in s.albums.map { a -> [String: Any] in
                ["id": a.id, "title": "A\(a.id)", "artistId": 20, "foreignAlbumId": a.rg.rawValue, "monitored": a.monitored,
                 "albumType": a.primary, "statistics": ["trackFileCount": a.files]] } })
        }
        t.stub(pathSuffix: "/api/v1/trackfile") { [self] req in
            let albumId = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "albumId" }?.value.flatMap(Int.init)
            let files = state.withLockUnchecked { s in s.albums.first { $0.id == albumId }?.files ?? 0 }
            return Self.reply((0..<files).map { ["id": 100 + $0, "path": "/music/library/Owner/x\($0).flac", "albumId": albumId ?? 0] })
        }
        t.stub(pathSuffix: "/api/v1/command/9") { [self] _ in Self.reply(["id": 9, "name": "RefreshArtist", "status": state.withLockUnchecked { $0.refreshStatus }]) }
        t.stub(method: "POST", pathSuffix: "/api/v1/command") { [self] _ in
            let withId: Bool = state.withLockUnchecked { $0.refreshReturnsId }
            let pending: Bool = state.withLockUnchecked { $0.refreshPending }
            if !pending { applyRefresh() }
            let answer: [String: Any] = withId ? ["id": 9] : [:]
            return Self.reply(answer, status: 201)
        }
        t.stub(method: "PUT", pathSuffix: "/api/v1/artist/editor") { [self] req in
            if state.withLockUnchecked({ s -> Bool in
                guard s.failNextEditor > 0 else { return false }
                s.failNextEditor -= 1
                return true
            }) { return .init(status: 503) }
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            state.withLockUnchecked { s in
                if let p = body["metadataProfileId"] as? Int { s.profileId = p }
                if let f = body["monitorNewItems"] as? String { s.follow = f }
            }
            return Self.reply([[String: Any]]())
        }
        t.stub(method: "PUT", pathSuffix: "/api/v1/album/monitor") { [self] req in
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let ids = body["albumIds"] as! [Int], monitored = body["monitored"] as! Bool
            state.withLockUnchecked { s in for i in s.albums.indices where ids.contains(s.albums[i].id) { s.albums[i].monitored = monitored } }
            return Self.reply([[String: Any]]())
        }
    }

    func switcher(checks: Int = 2) -> SinglesSwitcher {
        SinglesSwitcher(lidarr: client, gate: gate, store: store, checks: checks, pause: .zero)
    }

    var writes: [(String, [String: Any])] {
        transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" }.map { r in
            ("\(r.httpMethod!) \(r.url!.path.replacingOccurrences(of: "/api/v1/", with: ""))",
             (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:])
        }
    }
    var listed: Set<MBID> { state.withLockUnchecked { Set($0.albums.map(\.rg)) } }
    var monitored: Set<MBID> { state.withLockUnchecked { Set($0.albums.filter(\.monitored).map(\.rg)) } }
}

/// Round 15 C3 review fixes C1, I1–I3 (D146): the singles switch never narrows the artist's profile, is a persisted
/// journal resumed or rolled back, waits for a confirmed refresh, and runs once per artist.
@Suite struct SinglesSwitchTests {
    static let before: Set<MBID> = [SinglesLidarr.album, SinglesLidarr.live, SinglesLidarr.compilation, SinglesLidarr.promo]

    /// C1: the owner's Live, Compilation and Promotion releases (no files, monitored, wanted) are all still listed and
    /// monitored after the switch; the new profile is theirs plus Single.
    @Test func theSwitchNeverNarrowsTheProfile() async throws {
        let fake = await SinglesLidarr()
        let outcome = try await fake.switcher().start(artistId: 20, target: SinglesLidarr.target)
        #expect(outcome == .finished)
        #expect(Self.before.isSubset(of: fake.listed), "every listed album stays")
        #expect(Self.before.isSubset(of: fake.monitored), "and stays monitored")
        let made = try #require(fake.writes.first { $0.0 == "POST metadataprofile" }?.1)
        #expect(made["name"] as? String == "Owner Profile + Singles (Magpie)")
        func allowed(_ field: String, _ key: String) -> Set<String> {
            Set((made[field] as? [[String: Any]] ?? []).filter { $0["allowed"] as? Bool == true }
                .compactMap { ($0[key] as? [String: Any])?["name"] as? String })
        }
        #expect(allowed("primaryAlbumTypes", "albumType") == ["Album", "EP", "Single"])
        #expect(allowed("secondaryAlbumTypes", "albumType") == ["Studio", "Live", "Compilation"])
        #expect(allowed("releaseStatuses", "releaseStatus") == ["Official", "Promotion"])
        #expect(fake.listed.contains(SinglesLidarr.target))
    }

    /// The whole order, following "all": off first, the superset profile, a confirmed refresh, only the target newly
    /// monitored, following back.
    @Test func anOwnersArtistEndsWithOnlyTheTargetNewlyMonitoredAndFollowingRestored() async throws {
        let fake = await SinglesLidarr()
        fake.state.withLockUnchecked { $0.newMonitored = true }   // the worst case: Lidarr monitors what appears
        #expect(try await fake.switcher().start(artistId: 20, target: SinglesLidarr.target) == .finished)
        #expect(fake.writes.map(\.0) == ["PUT artist/editor", "POST metadataprofile", "PUT artist/editor", "POST command",
                                         "PUT album/monitor", "PUT artist/editor"])
        #expect(fake.writes[0].1["monitorNewItems"] as? String == "none")
        #expect(fake.writes[4].1["albumIds"] as? [Int] == [3], "the other single goes back to unmonitored")
        #expect(fake.monitored == Self.before.union([SinglesLidarr.target]))
        #expect(fake.state.withLockUnchecked { $0.follow } == "all", "following restored")
        #expect(try await fake.store.job(20)?.step == .done)
    }

    @Test func aMagpieSupersetProfileIsReusedAndAProfileWithSinglesIsLeftAlone() async throws {
        let fake = await SinglesLidarr()
        var existing = SinglesLidarr.profile(30, "Owner Profile + Singles (Magpie)", primary: ["Album", "EP", "Single"],
                                             secondary: ["Studio", "Live", "Compilation"], statuses: ["Official", "Promotion"])
        existing["id"] = 30
        fake.state.withLockUnchecked { $0.profiles.append(existing) }
        #expect(try await fake.switcher().start(artistId: 20, target: SinglesLidarr.target) == .finished)
        #expect(!fake.writes.contains { $0.0 == "POST metadataprofile" }, "reused")
        #expect(fake.state.withLockUnchecked { $0.profileId } == 30)
        // Already listing singles (the same artist now): nothing switched, and Magpie's profile is never saved as original.
        let before = fake.writes.count
        #expect(try await fake.switcher().start(artistId: 20, target: SinglesLidarr.target) == .alreadyListed, "it lists singles now")
        #expect(fake.writes.count == before)
        #expect(try await fake.store.job(20)?.originalProfileId == 5)
    }

    @Test func aProfileThatAlreadyListsSinglesSwitchesNothing() async throws {
        let fake = await SinglesLidarr()
        fake.state.withLockUnchecked { s in
            s.profiles = [SinglesLidarr.profile(5, "Everything", primary: ["Album", "EP", "Single"], secondary: ["Studio"],
                                                statuses: ["Official"])]
        }
        #expect(try await fake.switcher().start(artistId: 20, target: SinglesLidarr.target) == .alreadyListed)
        let none = try await fake.store.job(20)
        #expect(fake.writes.isEmpty && none == nil)
    }

    /// Undo: the saved profile and following back, then a refresh, from the journal (not the change log).
    @Test func undoRestoresProfileAndFollowingThenRefreshes() async throws {
        let fake = await SinglesLidarr()
        let switcher = fake.switcher()
        _ = try await switcher.start(artistId: 20, target: SinglesLidarr.target)
        fake.state.withLockUnchecked { $0.follow = "new" }   // whatever it is now, the saved value comes back
        let before = fake.writes.count
        try await switcher.undo(artistId: 20)
        let undo = Array(fake.writes.dropFirst(before))
        #expect(undo.map(\.0) == ["PUT artist/editor", "PUT artist/editor", "POST command"])
        #expect(undo[0].1["monitorNewItems"] as? String == "all" && undo[1].1["metadataProfileId"] as? Int == 5)
        #expect(fake.state.withLockUnchecked { ($0.profileId, $0.follow) } == (5, "all"))
        #expect(try await fake.store.job(20)?.step == .undone)
        // After the undo the gate allows no more switch writes for the artist.
        await #expect(throws: WriteGateError.self) {
            _ = try await fake.gate.send("PUT", "artist/editor", body: SinglesSwitchTests.Follow(artistIds: [20], monitorNewItems: "none"),
                                         confinedAs: .singlesSwitch)
        }
    }

    struct Follow: Encodable, Sendable { var artistIds: [Int]; var monitorNewItems: String }
    struct Profile: Encodable, Sendable { var artistIds: [Int]; var metadataProfileId: Int }

    /// I1: killed after "following off" (the journal says so): a restart finishes the switch.
    @Test func anInterruptedSwitchIsFinishedOnRestart() async throws {
        let fake = await SinglesLidarr()
        fake.state.withLockUnchecked { $0.failNextEditor = 1_000 }   // the profile edit keeps failing: the app "dies" there
        fake.state.withLockUnchecked { $0.failNextEditor = 0 }
        var job = SinglesSwitchJob(artistId: 20, target: SinglesLidarr.target, originalProfileId: 5, originalFollow: "all",
                                   beforeAlbumIds: [1, 6, 7, 8], beforeReleaseGroups: Array(Self.before), startedAt: Date())
        job.step = .followOff
        try await fake.store.save(job)
        fake.state.withLockUnchecked { $0.follow = "none" }   // what the killed run had sent
        let outcomes = await fake.switcher().resumeAll()
        #expect(outcomes == [20: .finished])
        #expect(fake.state.withLockUnchecked { $0.follow } == "all" && fake.listed.contains(SinglesLidarr.target))
        #expect(Self.before.isSubset(of: fake.monitored))
    }

    /// I1: one that can't be finished is rolled back (following and the profile back, then a refresh), and says so.
    @Test func aSwitchThatCantBeFinishedIsRolledBack() async throws {
        let fake = await SinglesLidarr()
        fake.state.withLockUnchecked { $0.refreshStatus = "failed" }
        let switcher = fake.switcher()
        var outcome = try await switcher.start(artistId: 20, target: SinglesLidarr.target)
        for _ in 0..<SinglesSwitcher.maxFailures where outcome == .pending {
            outcome = await switcher.resumeAll()[20] ?? .pending
        }
        #expect(outcome == .rolledBack)
        #expect(fake.state.withLockUnchecked { ($0.profileId, $0.follow) } == (5, "all"))
        #expect(fake.writes.last?.0 == "POST command", "a refresh after the profile is back")
        #expect(try await fake.store.job(20)?.step == .rolledBack)
    }

    /// I2: no command id, or a refresh that doesn't finish in time: following stays off and nothing is unmonitored yet;
    /// once it completes, the late singles are unmonitored and following comes back.
    @Test func anUnconfirmedRefreshKeepsFollowingOffUntilItCompletes() async throws {
        let noId = await SinglesLidarr()
        noId.state.withLockUnchecked { $0.refreshReturnsId = false }
        #expect(try await noId.switcher().start(artistId: 20, target: SinglesLidarr.target) == .pending)
        #expect(noId.state.withLockUnchecked { $0.follow } == "none" && !noId.writes.contains { $0.0 == "PUT album/monitor" })

        let slow = await SinglesLidarr()
        slow.state.withLockUnchecked { s in s.refreshPending = true; s.refreshStatus = "started"; s.newMonitored = true }
        let switcher = slow.switcher()
        #expect(try await switcher.start(artistId: 20, target: SinglesLidarr.target) == .pending)
        #expect(slow.state.withLockUnchecked { $0.follow } == "none", "not restored while the refresh runs")
        #expect(!slow.writes.contains { $0.0 == "PUT album/monitor" })
        // The refresh finishes later, listing the singles (monitored, the worst case).
        slow.applyRefresh()
        slow.state.withLockUnchecked { $0.refreshStatus = "completed" }
        #expect(await switcher.resumeAll() == [20: .finished])
        #expect(slow.monitored == Self.before.union([SinglesLidarr.target]), "the late single unmonitored")
        #expect(slow.state.withLockUnchecked { $0.follow } == "all")
    }

    /// I3: two confirmations at once make one switch; the second joins it.
    @Test func twoSwitchesAtOnceAreOne() async throws {
        let fake = await SinglesLidarr()
        let switcher = fake.switcher()
        async let a = switcher.start(artistId: 20, target: SinglesLidarr.target)
        async let b = switcher.start(artistId: 20, target: SinglesLidarr.target)
        let outcomes = try await [a, b]
        #expect(Set(outcomes.map { "\($0)" }) == ["finished", "alreadyListed"], "the second waits, then finds singles listed")
        #expect(fake.writes.filter { $0.0 == "POST metadataprofile" }.count == 1)
        #expect(fake.writes.filter { $0.1["monitorNewItems"] as? String == "none" }.count == 1)
        #expect(try await fake.store.job(20)?.originalFollow == "all", "the original is never \"none\"")
    }

    /// I3: the journal must be saved before any write: unwritable, nothing is sent.
    @Test func anUnsavedJournalSendsNothing() async throws {
        let blocked = FileManager.default.temporaryDirectory.appending(path: "Singles-ro-\(UUID().uuidString)")
        try Data().write(to: blocked)   // a file where the folder would be: the save fails
        let fake = await SinglesLidarr(storeURL: blocked.appending(path: "singles.json"))
        await #expect(throws: SinglesSwitchError.notSaved) {
            _ = try await fake.switcher().start(artistId: 20, target: SinglesLidarr.target)
        }
        #expect(fake.writes.isEmpty)
    }

    /// The gate: without a journal entry no switch write goes; with one, only the superset profile, the saved original,
    /// following off while open or back to its saved value.
    @Test func theGateFollowsTheJournal() async throws {
        let fake = await SinglesLidarr()
        await #expect(throws: WriteGateError.self) {
            _ = try await fake.gate.send("PUT", "artist/editor", body: Follow(artistIds: [20], monitorNewItems: "none"), confinedAs: .singlesSwitch)
        }
        try await fake.store.save(SinglesSwitchJob(artistId: 20, target: SinglesLidarr.target, originalProfileId: 5,
                                                   originalFollow: "new", beforeAlbumIds: [], beforeReleaseGroups: [],
                                                   startedAt: Date()))
        _ = try await fake.gate.send("PUT", "artist/editor", body: Follow(artistIds: [20], monitorNewItems: "none"), confinedAs: .singlesSwitch)
        await #expect(throws: WriteGateError.self) {
            _ = try await fake.gate.send("PUT", "artist/editor", body: Follow(artistIds: [20], monitorNewItems: "all"), confinedAs: .singlesSwitch)
        }
        await #expect(throws: WriteGateError.self) {   // a Magpie profile that isn't a "+ Singles" superset
            fake.state.withLockUnchecked { $0.profiles.append(SinglesLidarr.profile(40, "Magpie Albums+EPs+Singles · Studio",
                                                                         primary: ["Album", "EP", "Single"], secondary: ["Studio"],
                                                                         statuses: ["Official"])) }
            _ = try await fake.gate.send("PUT", "artist/editor", body: Profile(artistIds: [20], metadataProfileId: 40), confinedAs: .singlesSwitch)
        }
        _ = try await fake.gate.send("PUT", "artist/editor", body: Profile(artistIds: [20], metadataProfileId: 5), confinedAs: .singlesSwitch)
        _ = try await fake.gate.send("PUT", "artist/editor", body: Follow(artistIds: [20], monitorNewItems: "new"), confinedAs: .singlesSwitch)
    }

    @Test func changesOffSendsNothing() async throws {
        let fake = await SinglesLidarr(changesOn: false)
        await #expect(throws: SinglesSwitchError.changesOff) {
            _ = try await fake.switcher().start(artistId: 20, target: SinglesLidarr.target)
        }
        #expect(fake.writes.isEmpty)
    }

    @Test func theJournalIsErasedWithTheRequests() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "SinglesErase-\(UUID().uuidString)")
        let url = SinglesSwitchStore.defaultURL(in: dir, instance: "lidarr-a")
        try await SinglesSwitchStore(fileURL: url).save(SinglesSwitchJob(artistId: 1, target: SinglesLidarr.target,
                                                                          originalProfileId: 1, originalFollow: "all",
                                                                          beforeAlbumIds: [], beforeReleaseGroups: [], startedAt: Date()))
        #expect(FileManager.default.fileExists(atPath: url.path))
        RequestStore.eraseAll(in: dir)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
