import Foundation
import LidarrKit
import MagpieCore
import MatchIndex
import NavidromeKit
import os
import Search
import Testing
@testable import Magpie

final class MemoryLidarrStore: LidarrConnectionStoring, @unchecked Sendable {
    private let saved = OSAllocatedUnfairLock<LidarrConnection?>(initialState: nil)
    func save(_ connection: LidarrConnection) throws { saved.withLock { $0 = connection } }
    func load() -> LidarrConnection? { saved.withLock { $0 } }
    func clear() { saved.withLock { $0 = nil } }
}

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!

/// `/api/song` rows: the library has "Harbour Lights" by Corin Hale (no MBIDs, 232 s).
private let songPage = Data(#"""
[{"id":"s1","title":"Harbour Lights","artist":"Corin Hale","album":"Saltwater Hymns","duration":232,"missing":false},
 {"id":"s2","title":"Gone","artist":"Corin Hale","album":"Saltwater Hymns","duration":100,"missing":true}]
"""#.utf8)
private let emptySearch = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{}}}"#.utf8)
private let labs = Data(#"""
[{"recording_name":"Harbour Lights","recording_mbid":"c2272a15-8f3a-4cdc-8f32-7e723352d44d","artist_credit_name":"Corin Hale"},
 {"recording_name":"Harbour Wall","recording_mbid":"4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11","artist_credit_name":"Ines Morrow"}]
"""#.utf8)
private let lidarrSearch = Data(#"""
[{"foreignId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2","artist":{"artistName":"Ines Morrow","foreignArtistId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2"}}]
"""#.utf8)

@MainActor
@Suite(.serialized) struct LidarrAndMergedSearchTests {
    let transport = HostSwitchTransport()
    let lidarrStore = MemoryLidarrStore()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: songPage, headers: ["X-Total-Count": "2"])
        t.stub(pathSuffix: "/rest/search3", body: emptySearch)
        t.stub(pathSuffix: "/recording-search/json", body: labs)
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0.4999","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music/library","freeSpace":1000000000}]"#.utf8))
        t.stub(pathSuffix: "/api/v1/search", body: lidarrSearch)
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, matchIndexDirectory: nil, dataDirectory: nil, transport: transport,
                 probeTransport: transport, engine: FakeEngine(), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                 systemNowPlaying: false)
    }

    @Test func matchIndexBuildsAfterSignInSkippingMissingSongs() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.matchIndexSettled()
        let index = try #require(await model.matchIndex?.index)
        #expect(index.count == 1)
        let req = try #require(transport.inner.requests.first { $0.url?.path.hasSuffix("/api/song") == true })
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "_end", value: "1000")))
        #expect(items.contains(URLQueryItem(name: "_sort", value: "id")))
        model.signOut()
        #expect(model.matchIndex == nil)
    }

    @Test func searchDropsLibraryDuplicatesAndAsksLidarrOnlyWhenConnected() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.matchIndexSettled()

        let s = await model.mergedSearch().run("harbour")
        #expect(s.libraryIsEmpty)
        #expect(s.notYet.songs.map(\.title) == ["Harbour Wall"], "Harbour Lights is in the library (match index)")
        #expect(!transport.inner.requests.contains { $0.url?.path.hasSuffix("/api/v1/search") == true })
        let labsRequest = try #require(transport.inner.requests.first { $0.url?.path.hasSuffix("/recording-search/json") == true })
        #expect(labsRequest.value(forHTTPHeaderField: "Authorization") == nil)

        _ = try await model.connectLidarr(base: lidarrBase, apiKey: " key ")
        let withLidarr = await model.mergedSearch().run("ines")
        #expect(withLidarr.notYet.artists.map(\.name) == ["Ines Morrow"])
        let lidarrRequest = try #require(transport.inner.requests.last { $0.url?.path.hasSuffix("/api/v1/search") == true })
        #expect(lidarrRequest.httpMethod == "GET")
        #expect(lidarrRequest.value(forHTTPHeaderField: "X-Api-Key") == "key")
    }

    @Test func connectLidarrSavesAndAuditsReadOnly() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        let audit = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(audit.reachable && audit.version == "3.2.0.4999" && audit.authEnabled)
        #expect(audit.roots.map(\.path) == ["/music/library"])
        #expect(lidarrStore.load() == LidarrConnection(base: lidarrBase, apiKey: "key"))
        #expect(model.lidarr != nil)
        let lidarrCalls = transport.inner.requests.filter { $0.url?.port == 8686 }
        #expect(!lidarrCalls.isEmpty && lidarrCalls.allSatisfy { $0.httpMethod == "GET" }, "connecting never writes to Lidarr")

        model.signOut()
        #expect(model.lidarr == nil)
        #expect(lidarrStore.load() == nil)
    }

    @Test func wrongKeyIsNotSaved() async throws {
        let t = HostSwitchTransport()
        t.inner.stub(pathSuffix: "/api/v1/system/status", status: 401)
        let model = AppModel(store: store, lidarrStore: lidarrStore, matchIndexDirectory: nil, dataDirectory: nil, transport: t,
                             probeTransport: t, engine: FakeEngine(), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                             systemNowPlaying: false)
        await #expect(throws: LidarrError.unauthorized) {
            _ = try await model.connectLidarr(base: lidarrBase, apiKey: "wrong")
        }
        #expect(model.lidarr == nil)
        #expect(lidarrStore.load() == nil)
        #expect(LidarrConnectCopy.message(for: LidarrError.unauthorized, url: lidarrBase) == LidarrConnectCopy.badKey)
    }

    /// Final review I2: Lidarr speaks plain http on 8686; an assumed https fails the TLS handshake.
    @Test func lidarrTLSFailureOverHTTPSSuggestsPlainHTTP() {
        let https = URL(string: "https://nas.tail1234.ts.net:8686")!
        for code in [URLError.Code.secureConnectionFailed, .cannotParseResponse, .badServerResponse] {
            #expect(LidarrConnectCopy.message(for: URLError(code), url: https) == ConnectErrorCopy.httpsNotAnswering)
        }
        let plain = URL(string: "http://nas.tail1234.ts.net:8686")!
        #expect(LidarrConnectCopy.message(for: URLError(.badServerResponse), url: plain)
                == "Couldn't reach Lidarr at nas.tail1234.ts.net:8686. Check the address and that Lidarr is running.")
    }

    @Test func musicBrainzClientIsSharedAndLazy() {
        let model = makeModel()
        #expect(model.musicBrainz === model.musicBrainz)
    }
}

@Suite struct LidarrSummaryTests {
    @Test func calmLinesForEachSetting() {
        let audit = LidarrAudit(reachable: true, version: "3.2.0", authEnabled: false,
                                roots: [RootFolder(id: 1, path: "/music")], tubifarry: true, recycleBinSet: false,
                                healthIssues: [HealthIssue(source: "x", type: "warning", message: "Indexer down")])
        let lines = Dictionary(uniqueKeysWithValues: LidarrSummary.lines(for: audit).map { ($0.title, $0.value) })
        #expect(lines["Version"] == "3.2.0")
        #expect(lines["Sign-in"] == "Off")
        #expect(lines["Root folders"] == "1")
        #expect(lines["Tubifarry"] == "Found")
        #expect(lines["Recycle bin"] == "Not set: deletes are permanent")
        #expect(lines["Health"] == "1 thing to look at")
        #expect(LidarrSummary.lines(for: LidarrAudit()).map(\.title) == ["Status"])
    }

    @Test func tryWhileChangesAreOffSaysWhereToTurnThemOn() {
        #expect(TryAvailability.changesOff.message == "Bringing songs home is switched off. Turn it on in Settings.")
    }
}
