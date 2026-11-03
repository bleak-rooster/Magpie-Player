import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import Requests
import Search
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let lidarrScope = LidarrClient(base: lidarrBase, apiKey: "key", transport: MockTransport()).instanceScope
private let newMBID = MBID("11111111-1111-4111-8111-111111111111")!
private let ownerMBID = MBID("22222222-2222-4222-8222-222222222222")!
private let soloMBID = MBID("33333333-3333-4333-8333-333333333333")!
private let twinA = MBID("44444444-4444-4444-8444-444444444444")!
private let twinB = MBID("55555555-5555-4555-8555-555555555555")!

/// P3: the artist page's Lidarr line in the app: the states and their copy, no line without Lidarr, the button
/// replaced by a hint while changes are off, the confirmation before the write, no request offline, and the owner's
/// artists never written.
@MainActor @Suite(.serialized) struct ArtistLidarrAppTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!
    let data = FileManager.default.temporaryDirectory.appending(path: "ArtistLidarrAppTests-\(UUID().uuidString)")

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music"}]"#.utf8))
        t.stub(pathSuffix: "/api/v1/artist", body: Data(#"""
        [{"id":20,"artistName":"Owner","foreignArtistId":"22222222-2222-4222-8222-222222222222","monitored":false,"tags":[]}]
        """#.utf8))
        t.stub(pathSuffix: "/api/v1/artist/20", body: Data(#"""
        {"id":20,"artistName":"Owner","foreignArtistId":"22222222-2222-4222-8222-222222222222","monitored":false,"tags":[]}
        """#.utf8))
        t.stub(pathSuffix: "/api/v1/command", body: Data("[]".utf8))
        // By MBID (`lidarr:<mbid>`): the new artist. By name: "Solo" has one exact match, "Twin" two, "Ghost" none.
        t.stub(pathSuffix: "/api/v1/artist/lookup") { request in
            let term = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "term" }?.value ?? ""
            let row = { (mbid: String, name: String, dis: String) in
                #"{"foreignArtistId":"\#(mbid)","artistName":"\#(name)","disambiguation":"\#(dis)","artistType":"Group"}"#
            }
            let rows: [String] = switch term {
            case "lidarr:" + newMBID.rawValue: [row(newMBID.rawValue, "New Artist", "")]
            case "Solo": [row(soloMBID.rawValue, "SOLÓ", "Leeds duo"), row("77777777-7777-4777-8777-777777777777", "Solo Tribute", "")]
            case "Twin": [row(twinA.rawValue, "Twin", "US band"), row(twinB.rawValue, "twin", "UK band")]
            case "lidarr:" + twinB.rawValue: [row(twinB.rawValue, "twin", "UK band")]
            case "Dup": [row(ownerMBID.rawValue, "Dup", "in Lidarr as Owner"), row(twinA.rawValue, "dup", "another")]
            default: []
            }
            return MockTransport.Response(status: 200, body: Data("[\(rows.joined(separator: ","))]".utf8))
        }
        t.stub(method: "POST", pathSuffix: "/api/v1/artist", body: Data(#"{"id":55}"#.utf8))
        t.stub(method: "PUT", pathSuffix: "/api/v1/artist/editor", body: Data("[]".utf8))
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: data, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    /// Signed in, Lidarr connected and set up (profiles, tag, the one root).
    func connected() async throws -> AppModel {
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(base: lidarrBase, scope: lidarrScope, fastStartProfileId: 4,
                                                              findsMetadataProfileId: 3, magpieTagId: 1,
                                                              losslessProfileId: 7, rootFolderPath: "/music"))
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        return model
    }

    var lidarrWrites: [URLRequest] {
        transport.inner.requests.filter { $0.url?.path.contains("/api/v1/") == true && ($0.httpMethod ?? "GET") != "GET" }
    }

    var lidarrReads: [URLRequest] { transport.inner.requests.filter { $0.url?.path.hasPrefix("/api/v1/artist") == true } }

    func cleanUp(_ model: AppModel) {
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
        try? FileManager.default.removeItem(at: data)
    }

    /// The existing Magpie profile for the default release types, so an add reuses it (no profile write).
    func stubProfiles(existing: Bool = true) {
        let t = transport.inner
        let standard: [String: Any] = [
            "id": 12, "name": ReleaseTypes.standard.profileName,
            "primaryAlbumTypes": ["Album", "EP", "Single"].enumerated().map {
                ["albumType": ["id": $0.offset, "name": $0.element], "allowed": $0.element != "Single"] as [String: Any]
            },
            "secondaryAlbumTypes": ["Studio", "Live"].enumerated().map {
                ["albumType": ["id": $0.offset, "name": $0.element], "allowed": $0.element == "Studio"] as [String: Any]
            },
            "releaseStatuses": ["Official", "Bootleg"].enumerated().map {
                ["releaseStatus": ["id": $0.offset, "name": $0.element], "allowed": $0.element == "Official"] as [String: Any]
            },
        ]
        let list = existing ? [standard] : []
        t.stub(pathSuffix: "/api/v1/metadataprofile",
               body: try! JSONSerialization.data(withJSONObject: list))
    }

    /// Commits the Add the line handed over, as the sheet or the confirmation does (picking `pick` when several).
    func commit(_ line: ArtistLidarrModel, pick: MBID? = nil, choices: DownloadChoices = .defaults) async throws -> AddOutcome {
        let flow = try #require(line.addFlow)
        let picked = pick.flatMap { m in flow.candidates.first { $0.mbid == m } }
        return await flow.commit(choices, picked, nil)
    }

    @Test func statesMapToTheirCopyAndSymbols() {
        typealias P = ArtistLidarrPresentation
        let monitored = P.make(.monitored(lidarrId: 1, searching: false), offline: false, changesAllowed: true, canAdd: true)
        #expect(monitored == P(text: "In Lidarr \u{00B7} Monitored", symbol: "checkmark.circle"))
        let searching = P.make(.monitored(lidarrId: 1, searching: true), offline: false, changesAllowed: true, canAdd: true)
        #expect(searching?.text == "In Lidarr \u{00B7} Monitored \u{00B7} Searching\u{2026}")
        let paused = P.make(.notMonitored(lidarrId: 1, magpieAdded: false), offline: false, changesAllowed: true, canAdd: true)
        #expect(paused == P(text: "In Lidarr \u{00B7} Not monitored", symbol: "pause.circle"), "the owner's: no action")
        let mine = P.make(.notMonitored(lidarrId: 1, magpieAdded: true), offline: false, changesAllowed: true, canAdd: true)
        #expect(mine?.action == .addMore, "R20: Add more to your library")
        #expect(P.actionTitle(.addMore) == "Add more to your library")
        let absent = P.make(.notInLidarr(mbid: newMBID), offline: false, changesAllowed: true, canAdd: true)
        #expect(absent == P(text: "Not in Lidarr", symbol: "plus.circle", action: .add), "R20: the status stays visible")
        #expect(P.actionTitle(.add) == "Add to your library")
        #expect(P.make(nil, offline: false, changesAllowed: true, canAdd: true) == nil, "no Lidarr: nothing shown")
        #expect(P.make(.notInLidarr(mbid: newMBID), offline: true, changesAllowed: true, canAdd: true)
                == P(text: "You're offline", symbol: "wifi.slash"))
        #expect(P.make(.notInLidarr(mbid: nil), offline: false, changesAllowed: true, canAdd: true)?.action == .add,
                "without an MBID the tap asks Lidarr's search (I3)")
        #expect(P.make(.notInLidarr(mbid: newMBID), offline: false, changesAllowed: true, canAdd: false)?.hint == .setUpFirst)
        #expect(P.make(.notMonitored(lidarrId: 1, magpieAdded: true), offline: false, changesAllowed: false, canAdd: true)?.hint
                == .turnOnChanges)
    }

    @Test func noLidarrShowsNothingAndAsksNothing() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        let line = ArtistLidarrModel(model: model, name: "New Artist", mbid: newMBID)
        await line.refresh()
        #expect(line.presentation == nil)
        #expect(lidarrReads.isEmpty)
        cleanUp(model)
    }

    @Test func changesOffReplacesTheButtonWithTheHint() async throws {
        let model = try await connected()
        #expect(!model.changesAllowed)
        let line = ArtistLidarrModel(model: model, name: "New Artist", mbid: newMBID)
        await line.refresh()
        let p = try #require(line.presentation)
        #expect(p.text == "Not in Lidarr" && p.action == nil && p.hint == .turnOnChanges)
        #expect(ArtistLidarrPresentation.hintText(p.hint!)
                == "Turn on Allow Magpie to change your library in Settings \u{203A} Lidarr to add more.")
        await line.requestAdd()
        #expect(line.addFlow == nil)
        #expect(lidarrWrites.isEmpty)
        cleanUp(model)
    }

    @Test func theAddComesBeforeTheWrite() async throws {
        let model = try await connected()
        await model.setChangesAllowed(true)
        stubProfiles()
        let line = ArtistLidarrModel(model: model, name: "New Artist", mbid: newMBID)
        await line.refresh()
        #expect(line.presentation?.action == .add)
        await line.requestAdd()
        let flow = try #require(line.addFlow, "asks first (the Add sheet, or one confirmation)")
        #expect(flow.kind == .add && flow.artist == "New Artist" && flow.candidates.map(\.mbid) == [newMBID])
        #expect(lidarrWrites.isEmpty, "nothing written while the Add shows")
        #expect(!transport.inner.requests.contains { $0.url?.query?.contains("term=New") == true },
                "with the library's MBID, no name search (I3)")
        let outcome = try await commit(line, choices: DownloadChoices(quality: .smaller, follow: true))
        #expect(outcome.succeeded, "\(outcome.message)")
        #expect(lidarrWrites.map { "\($0.httpMethod!) \($0.url!.path)" } == ["POST /api/v1/artist"],
                "the existing Magpie profile for these types is reused")
        let body = try #require(lidarrWrites.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["metadataProfileId"] as? Int == 12, "R18: the release types' Magpie profile")
        #expect(body["qualityProfileId"] as? Int == 4, "Smaller files: Magpie Fast Start")
        #expect(body["monitorNewItems"] as? String == "all", "Follow new releases")
        #expect(line.presentation?.text == "In Lidarr \u{00B7} Monitored \u{00B7} Searching\u{2026}")
        let added = LidarrArtist(id: 55, artistName: "New Artist", foreignArtistId: newMBID, monitored: true)
        #expect(try await model.ledger?.createdArtist(added) == true, "ledgered as Magpie's")
        cleanUp(model)
    }

    @Test func offlineShowsYoureOfflineAndSendsNoRequest() async throws {
        let model = try await connected()
        await model.setChangesAllowed(true)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let before = lidarrReads.count
        let line = ArtistLidarrModel(model: model, name: "New Artist", mbid: newMBID)
        await line.refresh()
        #expect(line.presentation == ArtistLidarrPresentation(text: "You're offline", symbol: "wifi.slash"))
        #expect(lidarrReads.count == before, "no request offline")
        await line.requestAdd()
        #expect(line.addFlow == nil)
        await #expect(throws: (any Error).self) { _ = try await model.addArtist(mbid: newMBID, choices: .defaults) }
        #expect(lidarrWrites.isEmpty)
        cleanUp(model)
    }

    @Test func theOwnersArtistIsNeverWritten() async throws {
        let model = try await connected()
        await model.setChangesAllowed(true)
        stubProfiles(existing: false)
        let line = ArtistLidarrModel(model: model, name: "Owner", mbid: ownerMBID)
        await line.refresh()
        #expect(line.presentation == ArtistLidarrPresentation(text: "In Lidarr \u{00B7} Not monitored", symbol: "pause.circle"))
        line.requestAddMore()
        #expect(line.addFlow == nil, "no Add more for the owner's artist")
        await #expect(throws: ArtistLidarrError.notMagpies) {
            try await model.addMoreToLibrary(lidarrId: 20, choices: .defaults)
        }
        let outcome = await model.addMoreRequest(artist: "Owner", lidarrId: 20).commit(.defaults, nil, nil)
        #expect(!outcome.succeeded && outcome.message == "Added outside Magpie. Change it where you added it.")
        await #expect(throws: ArtistLidarrError.alreadyInLidarr) { _ = try await model.addArtist(mbid: ownerMBID, choices: .defaults) }
        #expect(lidarrWrites.isEmpty, "not even a metadata profile")
        cleanUp(model)
    }

    /// R19: the outside artist (and album) page's Add to your library is this line: it asks first, then adds through
    /// the gate; for an artist already in the owner's Lidarr there is no Add and nothing can be written.
    @Test func outsidePagesAddThroughTheGateAndRefuseTheOwnersArtist() async throws {
        let model = try await connected()
        await model.setChangesAllowed(true)
        stubProfiles()
        let owner = OutsideArtistModel(app: model, artist: NotYetArtist(name: "Owner", mbid: ownerMBID))
        await owner.lidarrLine.refresh()
        #expect(owner.lidarrLine.presentation?.text == "In Lidarr \u{00B7} Not monitored")
        #expect(owner.lidarrLine.presentation?.action == nil, "the owner's artist offers no Add")
        await owner.lidarrLine.requestAdd()
        #expect(owner.lidarrLine.addFlow == nil)
        await #expect(throws: ArtistLidarrError.alreadyInLidarr) { _ = try await model.addArtist(mbid: ownerMBID, choices: .defaults) }
        #expect(lidarrWrites.isEmpty)

        let album = OutsideAlbumModel(app: model, album: NotYetAlbum(title: "First", artist: "New Artist", mbid: soloMBID,
                                                                     artistMBID: newMBID), librarySong: { _ in nil })
        let line = album.lidarrLine
        await line.refresh()
        #expect(line.presentation?.action == .add)
        await line.requestAdd()
        #expect(lidarrWrites.isEmpty, "nothing written while the Add shows")
        let outcome = try await commit(line)
        #expect(outcome.succeeded, "\(outcome.message)")
        #expect(lidarrWrites.map { "\($0.httpMethod!) \($0.url!.path)" } == ["POST /api/v1/artist"])
        let added = LidarrArtist(id: 55, artistName: "New Artist", foreignArtistId: newMBID, monitored: true)
        #expect(try await model.ledger?.createdArtist(added) == true, "through the gate and its ledger")
        cleanUp(model)
    }

    // MARK: - I3: no MBID in the library

    @Test func oneExactSearchMatchIsNamedInTheAdd() async throws {
        let model = try await connected()
        await model.setChangesAllowed(true)
        let line = ArtistLidarrModel(model: model, name: "Solo", mbid: nil)
        await line.refresh()
        #expect(!transport.inner.requests.contains { $0.url?.path.hasSuffix("/lookup") == true }, "no search on view")
        await line.requestAdd()
        let flow = try #require(line.addFlow)
        #expect(flow.candidates.map(\.label) == ["SOLÓ (Leeds duo, Group)"])
        #expect(lidarrWrites.isEmpty)
        await #expect(throws: ArtistLidarrError.failed) { try await line.add(twinA, .defaults) }   // not offered
        #expect(lidarrWrites.isEmpty)
        cleanUp(model)
    }

    @Test func severalExactMatchesAreListedToPickOne() async throws {
        let model = try await connected()
        await model.setChangesAllowed(true)
        stubProfiles()
        let line = ArtistLidarrModel(model: model, name: "Twin", mbid: nil)
        await line.refresh()
        await line.requestAdd()
        let flow = try #require(line.addFlow)
        #expect(flow.candidates.map(\.label) == ["Twin (US band, Group)", "twin (UK band, Group)"])
        #expect(AddRoute.route(withMyDefaults: true, defaults: .defaults, albumContext: false,
                               candidates: flow.candidates.count) == .sheet(.defaults),
                "several: the sheet asks \u{201C}Which Twin?\u{201D} even with Add with my defaults on")
        #expect(lidarrWrites.isEmpty)
        // N4: the add sends the picked one's MBID.
        let outcome = try await commit(line, pick: twinB)
        #expect(outcome.succeeded)
        let post = try #require(lidarrWrites.first)
        #expect(lidarrWrites.count == 1 && post.httpMethod == "POST" && post.url?.path == "/api/v1/artist")
        let body = try #require(post.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["foreignArtistId"] as? String == twinB.rawValue)
        #expect(line.presentation?.text == "In Lidarr \u{00B7} Monitored \u{00B7} Searching\u{2026}")
        cleanUp(model)
    }

    @Test func noExactMatchAddsNothing() async throws {
        let model = try await connected()
        await model.setChangesAllowed(true)
        let line = ArtistLidarrModel(model: model, name: "Ghost", mbid: nil)
        await line.refresh()
        await line.requestAdd()
        #expect(line.addFlow == nil)
        #expect(line.error == "Couldn't find Ghost to add. Try again later.")
        #expect(lidarrWrites.isEmpty)
        cleanUp(model)
    }

    /// N2: a picked candidate that is in Lidarr already (under another name) writes nothing and doesn't stick: the line
    /// stays "Not in Lidarr" for this library artist, so the owner can pick again.
    @Test func aPickedCandidateAlreadyInLidarrDoesntStick() async throws {
        let model = try await connected()
        await model.setChangesAllowed(true)
        let line = ArtistLidarrModel(model: model, name: "Dup", mbid: nil)
        await line.refresh()
        #expect(line.presentation?.text == "Not in Lidarr")
        await line.requestAdd()
        let outcome = try await commit(line, pick: ownerMBID)
        #expect(!outcome.succeeded && outcome.message == "That artist is in your library already.")
        line.finished(outcome)
        #expect(lidarrWrites.isEmpty)
        #expect(line.error == "That artist is in your library already.")
        await line.refresh()
        #expect(line.presentation == ArtistLidarrPresentation(text: "Not in Lidarr", symbol: "plus.circle", action: .add))
        cleanUp(model)
    }
}
