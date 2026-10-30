import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import Requests
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
        t.stub(pathSuffix: "/api/v1/artist/lookup", body: Data(#"""
        [{"foreignArtistId":"11111111-1111-4111-8111-111111111111","artistName":"New Artist"}]
        """#.utf8))
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
                                                              rootFolderPath: "/music"))
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

    @Test func statesMapToTheirCopyAndSymbols() {
        typealias P = ArtistLidarrPresentation
        let monitored = P.make(.monitored(lidarrId: 1, searching: false), offline: false, changesAllowed: true, canAdd: true)
        #expect(monitored == P(text: "In Lidarr \u{00B7} Monitored", symbol: "checkmark.circle"))
        let searching = P.make(.monitored(lidarrId: 1, searching: true), offline: false, changesAllowed: true, canAdd: true)
        #expect(searching?.text == "In Lidarr \u{00B7} Monitored \u{00B7} Searching\u{2026}")
        let paused = P.make(.notMonitored(lidarrId: 1, magpieAdded: false), offline: false, changesAllowed: true, canAdd: true)
        #expect(paused == P(text: "In Lidarr \u{00B7} Not monitored", symbol: "pause.circle"), "the owner's: no action")
        let mine = P.make(.notMonitored(lidarrId: 1, magpieAdded: true), offline: false, changesAllowed: true, canAdd: true)
        #expect(mine?.action == .monitor)
        let absent = P.make(.notInLidarr(mbid: newMBID), offline: false, changesAllowed: true, canAdd: true)
        #expect(absent == P(text: "Not in Lidarr", symbol: "plus.circle", action: .add))
        #expect(P.make(nil, offline: false, changesAllowed: true, canAdd: true) == nil, "no Lidarr: nothing shown")
        #expect(P.make(.notInLidarr(mbid: newMBID), offline: true, changesAllowed: true, canAdd: true)
                == P(text: "You're offline", symbol: "wifi.slash"))
        #expect(P.make(.notInLidarr(mbid: nil), offline: false, changesAllowed: true, canAdd: true)?.hint == .unknownArtist)
        #expect(P.make(.notInLidarr(mbid: newMBID), offline: false, changesAllowed: true, canAdd: false)?.hint == .setUpFirst)
        #expect(P.confirmation("New Artist")
                == "Adds New Artist to Lidarr, monitors their albums and starts searching. This may download a lot of music.")
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
        #expect(p.text == "Not in Lidarr" && p.action == nil && p.hint == .turnOnChanges(toAdd: true))
        #expect(ArtistLidarrPresentation.hintText(p.hint!)
                == "Turn on Allow Magpie to change Lidarr in Settings \u{203A} Requests to add artists.")
        line.requestAdd()
        #expect(!line.confirmingAdd)
        await line.confirmAdd()
        #expect(lidarrWrites.isEmpty)
        cleanUp(model)
    }

    @Test func theConfirmationComesBeforeTheWrite() async throws {
        let model = try await connected()
        await model.setChangesAllowed(true)
        let line = ArtistLidarrModel(model: model, name: "New Artist", mbid: newMBID)
        await line.refresh()
        #expect(line.presentation?.action == .add)
        line.requestAdd()
        #expect(line.confirmingAdd, "asks first")
        #expect(lidarrWrites.isEmpty, "nothing written while the confirmation shows")
        await line.confirmAdd()
        #expect(lidarrWrites.map { "\($0.httpMethod!) \($0.url!.path)" } == ["POST /api/v1/artist"])
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
        line.requestAdd()
        await line.confirmAdd()
        await #expect(throws: (any Error).self) { try await model.addArtistToLidarr(mbid: newMBID) }
        #expect(lidarrWrites.isEmpty)
        cleanUp(model)
    }

    @Test func theOwnersArtistIsNeverWritten() async throws {
        let model = try await connected()
        await model.setChangesAllowed(true)
        let line = ArtistLidarrModel(model: model, name: "Owner", mbid: ownerMBID)
        await line.refresh()
        #expect(line.presentation == ArtistLidarrPresentation(text: "In Lidarr \u{00B7} Not monitored", symbol: "pause.circle"))
        await line.monitor()
        await #expect(throws: ArtistLidarrError.notMagpies) { try await model.monitorArtistInLidarr(id: 20) }
        await #expect(throws: ArtistLidarrError.alreadyInLidarr) { _ = try await model.addArtistToLidarr(mbid: ownerMBID) }
        #expect(lidarrWrites.isEmpty)
        cleanUp(model)
    }
}
