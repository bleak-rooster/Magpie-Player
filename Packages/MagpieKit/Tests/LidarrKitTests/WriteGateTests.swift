import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// A fresh, empty UserDefaults suite and a temp change-log location per test.
struct GateEnv {
    let defaults: String
    let logURL: URL

    init() {
        defaults = "magpie-test-\(UUID().uuidString)"
        UserDefaults(suiteName: defaults)!.removePersistentDomain(forName: defaults)
        logURL = FileManager.default.temporaryDirectory
            .appending(path: "magpie-gate-\(UUID().uuidString)/lidarr-change-log.json")
    }

    func gate(_ client: LidarrClient, enabled: Bool) async -> LidarrWriteGate {
        let gate = LidarrWriteGate(client: client, logURL: logURL, defaultsSuite: defaults)
        await gate.setEnabled(enabled)
        return gate
    }
}

@Suite struct WriteGateTests {
    @Test func disabledThrows() async throws {
        let env = GateEnv()
        let (client, t) = makeClient()
        t.stub(method: "POST", pathSuffix: "/tag", body: json(#"{"id":1,"label":"magpie"}"#))
        let gate = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults)

        #expect(await gate.enabled == false)   // default off (G1)
        await #expect(throws: WriteGateError.disabled) {
            _ = try await gate.send("POST", "tag", body: JSONValue.object(["label": .string("magpie")]))
        }
        #expect(t.requests.isEmpty)
        #expect(await gate.changeLog().isEmpty)
    }

    @Test func enabledSwitchPersists() async throws {
        let env = GateEnv()
        let (client, _) = makeClient()
        let gate = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults)
        await gate.setEnabled(true)
        #expect(await LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults).enabled)
        await gate.setEnabled(false)
        #expect(await LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults).enabled == false)
    }

    /// Security M3: the switch belongs to one Lidarr instance (address + API key). Another Lidarr, or the same
    /// address with a new key, starts with writes off; the old global key means nothing.
    @Test func switchIsScopedToOneLidarr() async throws {
        let env = GateEnv()
        let (client, t) = makeClient()
        t.stub(method: "POST", pathSuffix: "/tag", body: json(#"{"id":1}"#))
        let gate = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults)
        await gate.setEnabled(true)
        #expect(await gate.enabled)
        let other = LidarrClient(base: URL(string: "http://192.168.1.3:8686")!, apiKey: "other", transport: t)
        let newKey = LidarrClient(base: testBase, apiKey: "rotated", transport: t)
        for c in [other, newKey] {
            let g = LidarrWriteGate(client: c, logURL: env.logURL, defaultsSuite: env.defaults)
            #expect(await g.enabled == false)
            await #expect(throws: WriteGateError.disabled) {
                _ = try await g.send("POST", "tag", body: JSONValue.object(["label": .string("x")]))
            }
        }
        let legacy = UserDefaults(suiteName: env.defaults)!
        legacy.set(true, forKey: LidarrWriteGate.enabledDefaultsKey)
        #expect(await LidarrWriteGate(client: other, logURL: env.logURL, defaultsSuite: env.defaults).enabled == false)
        #expect(legacy.bool(forKey: LidarrWriteGate.enabledKey(scope: client.instanceScope)))
        #expect(t.requests.isEmpty)
    }

    struct Call: Sendable, CustomTestStringConvertible {
        var method: String
        var path: String
        var body: String?
        var testDescription: String { "\(method) \(path)" + (body.map { " " + $0 } ?? "") }
        init(_ method: String, _ path: String, _ body: String? = nil) { self.method = method; self.path = path; self.body = body }
    }

    /// Every entry of the never-call list (brief ruling 2, G3, G5), plus case, `//`, trailing-slash,
    /// percent-encoding, prefix and query-order variants.
    static let forbidden: [Call] = [
        // DELETE /artist/editor (bulk delete)
        Call("DELETE", "artist/editor"),
        Call("DELETE", "/api/v1/artist/editor"),
        Call("delete", "/API/V1/Artist/Editor/"),
        Call("DELETE", "//api//v1//artist//editor//"),
        Call("DELETE", "/api/v1/artist%2Feditor"),
        Call("DELETE", "/api/v1/%61rtist/%65ditor"),
        Call("DELETE", "/api/v1/artist%252Feditor"),
        Call("DELETE", "artist/editor", #"{"artistIds":[1],"deleteFiles":false}"#),
        // DELETE /artist/{id} with deleteFiles=true
        Call("DELETE", "artist/12?deleteFiles=true"),
        Call("DELETE", "/api/v1/artist/12/?addImportListExclusion=false&deleteFiles=true"),
        Call("DELETE", "artist/12?DELETEFILES=True"),
        Call("DELETE", "artist/12?deleteFiles=%74rue"),
        Call("DELETE", "artist/12?delete%46iles=true"),
        Call("DELETE", "artist/12?deleteFiles=1"),
        Call("DELETE", "artist/12?deleteFiles"),
        Call("DELETE", "artist/12?deleteFiles=false&deleteFiles=true"),
        Call("DELETE", "artist?deleteFiles=true"),
        Call("DELETE", "artist/12", #"{"deleteFiles":true}"#),
        // addImportListExclusion=true, anywhere
        Call("DELETE", "artist/12?addImportListExclusion=true"),
        Call("DELETE", "artist/12?deleteFiles=false&AddImportListExclusion=TRUE"),
        Call("DELETE", "album/7?addImportListExclusion=true"),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"addImportListExclusion":true}"#),
        Call("POST", "artist", #"{"addOptions":{"addImportListExclusion":"true"}}"#),
        // DELETE /api/missing and /api/v1/missing
        Call("DELETE", "/api/missing"),
        Call("DELETE", "/api/v1/missing"),
        Call("DELETE", "/API/Missing/"),
        Call("DELETE", "missing/3"),
        // Owner configuration (G5)
        Call("PUT", "config/mediamanagement", #"{"recycleBin":""}"#),
        Call("POST", "/api/v1/config/mediamanagement"),
        Call("PUT", "/api/v1/config/mediamanagement/1"),
        Call("PUT", "config/naming", #"{"renameTracks":true}"#),
        Call("PUT", "Config//Naming/"),
        Call("DELETE", "config/naming/1"),
        Call("PUT", "config/metadataprovider"),
        Call("POST", "config/metadataprovider"),
        Call("PUT", "config/host"),
        Call("PUT", "qualityprofile/1", #"{"id":1,"name":"Any"}"#),
        Call("DELETE", "qualityprofile/1"),
        Call("PUT", "/api/v1/QualityProfile/1/"),
        Call("PUT", "qualityprofile"),
        Call("PUT", "metadataprofile/1"),
        Call("DELETE", "metadataprofile/1"),
        Call("DELETE", "/api/v1/metadataprofile%2F1"),
        Call("POST", "rootfolder", #"{"path":"/music/x"}"#),
        Call("PUT", "rootfolder/1"),
        Call("DELETE", "rootfolder/1"),
        Call("POST", "indexer"),
        Call("PUT", "indexer/1"),
        Call("DELETE", "indexer/1"),
        Call("POST", "downloadclient"),
        Call("PUT", "downloadclient/1"),
        Call("DELETE", "downloadclient/1"),
        Call("POST", "notification"),
        Call("PUT", "notification/1"),
        Call("DELETE", "notification/1"),
        Call("POST", "importlistexclusion", #"{"foreignId":"x"}"#),
        // Commands outside the allow list (rename/retag rewrite the owner's library)
        Call("POST", "command", #"{"name":"RenameFiles","artistId":1}"#),
        Call("POST", "command", #"{"name":"RetagArtist"}"#),
        Call("POST", "command", #"{"name":"ResetApiKey"}"#),
        Call("POST", "command"),
        Call("POST", "command", #"{"name":"AlbumSearch","Name":"RenameFiles"}"#),
        Call("POST", "command", #"{"name":"AlbumSearch","NAME":"AlbumSearch"}"#),
        Call("POST", "command/5", #"{"name":"AlbumSearch"}"#),
        // Fix round 1: not on the allow list (G5)
        Call("DELETE", "tag/1"),
        Call("PUT", "qualitydefinition/update", #"[]"#),
        Call("DELETE", "delayprofile/1"),
        Call("PUT", "releaseprofile/1"),
        Call("DELETE", "customformat/1"),
        Call("PUT", "remotepathmapping/1"),
        // Not for me (Task 6.2c, A16): only `DELETE trackfile/{id}` (no query, no body) and `DELETE trackfile/bulk`
        // with exactly a non-empty list of track file ids.
        Call("DELETE", "trackfile"),
        Call("DELETE", "trackfile/bulk"),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[]}"#),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[9],"deleteFiles":false}"#),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[9],"artistId":4}"#),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":["9"]}"#),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[true]}"#),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[9.5]}"#),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[0]}"#),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":9}"#),
        Call("DELETE", "trackfile/bulk", #"[9]"#),
        Call("DELETE", "trackfile/bulk?artistId=4", #"{"trackFileIds":[9]}"#),
        Call("DELETE", "trackfile/9?deleteFiles=false"),
        Call("DELETE", "trackfile/9", #"{"id":9}"#),
        Call("DELETE", "trackfile/abc"),
        Call("DELETE", "trackfile/9/x"),
        Call("PUT", "trackfile/9", #"{"id":9}"#),
        Call("PUT", "trackfile/bulk", #"{"trackFileIds":[9]}"#),
        Call("POST", "somethingnew"),
        Call("POST", "/api/v2/tag", #"{"label":"x"}"#),
        Call("POST", "/api/tag", #"{"label":"x"}"#),
        Call("POST", "tag/5", #"{"label":"x"}"#),
        Call("PUT", "tag/1", #"{"label":"x"}"#),
        Call("POST", "artist/5"),
        Call("DELETE", "album/7"),
        Call("PUT", "album/abc"),
        Call("DELETE", "artist/abc?deleteFiles=false&addImportListExclusion=false"),
        // DELETE artist/{id} without both explicit false flags, or with anything else
        Call("DELETE", "artist/12"),
        Call("DELETE", "artist/12?deleteFiles=false"),
        Call("DELETE", "artist/12?addImportListExclusion=false"),
        Call("DELETE", "artist/12?deleteFiles=false&addImportListExclusion=false&moveFiles=true"),
        // Queries are not allowed on the other shapes (moveFiles would move the owner's folders)
        Call("PUT", "artist/12?moveFiles=true", #"{"id":12}"#),
        Call("POST", "tag?x=1", #"{"label":"x"}"#),
        // artist/editor body rules
        Call("PUT", "artist/editor", #"{"artistIds":[1],"deleteFiles":false}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"nested":{"AddImportListExclusion":false}}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"tags":[2],"applyTags":"replace"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"tags":[2],"applyTags":"add","ApplyTags":"replace"}"#),
        Call("PUT", "artist/editor"),
        // Follow new releases (Task 7.1b): one artist, monitorNewItems new, nothing else; never un-follow or "all"
        Call("PUT", "artist/editor", #"{"artistIds":[1],"monitorNewItems":"none"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"monitorNewItems":"all"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"monitorNewItems":"All"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"monitorNewItems":true}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1,2],"monitorNewItems":"new"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[],"monitorNewItems":"new"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"monitorNewItems":"new","monitored":false}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"monitorNewItems":"all","qualityProfileId":3}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"MonitorNewItems":"new","rootFolderPath":"/x"}"#),
        Call("PUT", "artist/editor", #"{"monitorNewItems":"new"}"#),
    ]

    @Test(arguments: forbidden)
    func forbiddenRefused(_ call: Call) async throws {
        let env = GateEnv()
        let t = MockTransport()
        for m in ["POST", "PUT", "DELETE"] { t.stub(method: m, pathSuffix: "", body: json("{}")) }
        let (client, _) = makeClient(t)
        let gate = await env.gate(client, enabled: true)
        let body = call.body.map { try! JSONDecoder().decode(JSONValue.self, from: json($0)) }
        do {
            _ = try await gate.send(call.method, call.path, body: body)
            Issue.record("sent \(call.testDescription)")
        } catch let error as WriteGateError {
            guard case .forbidden = error else { Issue.record("wrong error \(error)"); return }
        }
        #expect(t.requests.isEmpty)
        #expect(await gate.changeLog().isEmpty)
    }

    @Test func malformedWritesRejected() async throws {
        let env = GateEnv()
        let (client, t) = makeClient()
        let gate = await env.gate(client, enabled: true)
        for (method, path) in [("GET", "tag"), ("PATCH", "tag"), ("POST", ""), ("POST", "/api/v1/"),
                               ("POST", "tag/../config/naming"), ("POST", "tag/%2E%2E/config"),
                               ("POST", "https://evil.example/api/v1/tag"), ("POST", "tag;x=1"), ("POST", "tag#frag"),
                               ("POST", "t\u{0430}g"), ("POST", "t%D0%B0g"), ("DELETE", "artist/1?d\u{0435}leteFiles=true"),
                               ("DELETE", "artist/1?%C3%A9=1")] {
            await #expect(throws: WriteGateError.self, "\(method) \(path)") {
                _ = try await gate.send(method, path, body: nil)
            }
        }
        #expect(t.requests.isEmpty)
    }

    @Test func allowedWritesAreSentUnderTheBasePath() async throws {
        let env = GateEnv()
        let t = MockTransport()
        t.stub(method: "POST", pathSuffix: "/api/v1/tag", body: json(#"{"id":4,"label":"magpie"}"#))
        t.stub(method: "DELETE", pathSuffix: "/api/v1/artist/12", body: json("{}"))
        t.stub(method: "PUT", pathSuffix: "/api/v1/album/monitor", body: json("[]"))
        t.stub(method: "POST", pathSuffix: "/api/v1/command", body: json(#"{"id":99}"#))
        let (client, _) = makeClient(t)
        let gate = await env.gate(client, enabled: true)

        let created = try await gate.send("POST", "tag", body: JSONValue.object(["label": .string("magpie")]))
        #expect(try JSONDecoder().decode(JSONValue.self, from: created)["id"]?.intValue == 4)
        _ = try await gate.send("DELETE", "/api/v1/artist/12?addImportListExclusion=false&deleteFiles=false", body: nil)
        _ = try await gate.send("PUT", "album/monitor", body: JSONValue.object(["albumIds": .array([.int(3)]), "monitored": .bool(false)]))
        _ = try await gate.send("POST", "command", body: JSONValue.object(["name": .string("AlbumSearch"), "albumIds": .array([.int(3)])]))

        let requests = t.requests
        #expect(requests.map { $0.httpMethod ?? "" } == ["POST", "DELETE", "PUT", "POST"])
        #expect(requests[0].url?.absoluteString == "https://music.example/lidarr/api/v1/tag")
        #expect(requests[0].value(forHTTPHeaderField: "X-Api-Key") == testKey)
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(Set(query) == [URLQueryItem(name: "addImportListExclusion", value: "false"),
                               URLQueryItem(name: "deleteFiles", value: "false")])
        let log = await gate.changeLog()
        #expect(log.map(\.method) == ["POST", "DELETE", "PUT", "POST"])
        #expect(log[1].path == "/api/v1/artist/12?addImportListExclusion=false&deleteFiles=false")
        #expect(log.allSatisfy { $0.status == 200 })
    }

    @Test func errorStatusesThrowAndAreLogged() async throws {
        let env = GateEnv()
        let t = MockTransport()
        t.stub(method: "POST", pathSuffix: "/tag", status: 400, body: json(#"[{"errorMessage":"bad"}]"#))
        let (client, _) = makeClient(t)
        let gate = await env.gate(client, enabled: true)
        await #expect(throws: LidarrError.http(status: 400)) {
            _ = try await gate.send("POST", "tag", body: JSONValue.object(["label": .string("x")]))
        }
        #expect(await gate.changeLog().map(\.status) == [400])
    }

    @Test func logsWithoutSecrets() async throws {
        let env = GateEnv()
        let t = MockTransport()
        t.stub(method: "POST", pathSuffix: "/artist", body: json("{}"))
        let (client, _) = makeClient(t)
        let gate = await env.gate(client, enabled: true)
        let body = JSONValue.object([
            "label": .string("magpie"),
            "apiKey": .string("sekrit-1"),
            "nested": .object(["password": .string("sekrit-2"), "authToken": .string("sekrit-3")]),
            "list": .array([.object(["clientSecret": .string("sekrit-4")])]),
            "echo": .string("key is \(testKey)"),
            "padding": .string(String(repeating: "x", count: 5_000)),
        ])
        _ = try await gate.send("POST", "artist", body: body)

        let entry = try #require(await gate.changeLog().first)
        #expect(entry.method == "POST")
        #expect(entry.path == "/api/v1/artist")
        // Query secrets are masked in the logged path (no allowed shape takes them today; belt and braces).
        #expect(try WriteTarget(method: "POST", path: "x?apikey=sekrit-5&token=sekrit-6&keep=yes").logPath
                == "/api/v1/x?apikey=•••&token=•••&keep=yes")
        #expect(entry.bodySummary.contains(#""label":"magpie""#))
        #expect(entry.bodySummary.count <= LidarrWriteGate.maxBodySummary)
        let onDisk = try String(contentsOf: env.logURL, encoding: .utf8)
        for secret in ["sekrit-1", "sekrit-2", "sekrit-3", "sekrit-4", testKey] {
            #expect(!entry.bodySummary.contains(secret) && !entry.path.contains(secret), "\(secret) in summary")
            #expect(!onDisk.contains(secret), "\(secret) on disk")
        }

        // Persisted, kept out of backups, and read back by a new gate.
        #expect(try env.logURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let reopened = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults)
        #expect(await reopened.changeLog() == [entry])
    }

    @Test func unwritableLogBlocksTheWrite() async throws {
        let env = GateEnv()
        // The log's folder is a plain file, so the log cannot be saved.
        let blocker = FileManager.default.temporaryDirectory.appending(path: "magpie-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        let (client, t) = makeClient()
        t.stub(method: "POST", pathSuffix: "/tag", body: json(#"{"id":1}"#))
        let gate = LidarrWriteGate(client: client, logURL: blocker.appending(path: "log.json"), defaultsSuite: env.defaults)
        await gate.setEnabled(true)
        await #expect(throws: WriteGateError.logUnavailable) {
            _ = try await gate.send("POST", "tag", body: JSONValue.object(["label": .string("x")]))
        }
        #expect(t.requests.isEmpty)
    }
}

@Suite struct LedgerTests {
    @Test func recordsUpsertsAndPersists() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "magpie-ledger-\(UUID().uuidString)/ledger.json")
        let rg = MBID("0a3f5a6e-2f0b-4d8e-9d55-1b2c3d4e5f60")!
        let ledger = Ledger(fileURL: url)
        let first = LedgerEntry(lidarrArtistId: 5, albumId: 50, rgMbid: rg, createdArtist: true,
                                wasMonitoredBefore: false, root: "/music/library", mode: .fallback)
        try await ledger.record(first)
        var kept = first
        kept.keptAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await ledger.record(kept)
        try await ledger.record(LedgerEntry(lidarrArtistId: 6, albumId: 60, rgMbid: rg, createdArtist: false,
                                            wasMonitoredBefore: true, root: "/music/samples", mode: .finds))

        #expect(try await ledger.entries.count == 2)
        #expect(try await ledger.entry(albumId: 50) == kept)
        #expect(try await ledger.entry(albumId: 7) == nil)
        let reopened = Ledger(fileURL: url)
        #expect(try await reopened.entries == ledger.entries)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// Two instances on one file: neither caches, so neither loses the other's entries.
    @Test func instancesOnOneFileStayConsistent() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "magpie-ledger-\(UUID().uuidString)/ledger.json")
        let rg = MBID("0a3f5a6e-2f0b-4d8e-9d55-1b2c3d4e5f60")!
        let a = Ledger(fileURL: url), b = Ledger(fileURL: url)
        _ = try await a.entries   // a has read the (empty) file
        try await b.record(LedgerEntry(lidarrArtistId: 1, albumId: 10, rgMbid: rg, createdArtist: true,
                                       wasMonitoredBefore: false, root: "/m", mode: .fallback))
        #expect(try await a.entry(albumId: 10) != nil)
        try await a.record(LedgerEntry(lidarrArtistId: 2, albumId: 20, rgMbid: rg, createdArtist: false,
                                       wasMonitoredBefore: true, root: "/m", mode: .fallback))
        #expect(try await b.entries.map(\.albumId) == [10, 20])
        #expect(try await b.entry(rgMbid: rg)?.albumId == 20)
    }
}

@Suite struct WriteGateAllowListTests {
    typealias Call = WriteGateTests.Call

    /// Every shape on the allow list (fix round 1), including case / prefix / `//` variants.
    static let allowed: [Call] = [
        Call("POST", "tag", #"{"label":"magpie"}"#),
        Call("POST", "/api/v1/tag/", #"{"label":"magpie"}"#),
        Call("POST", "qualityprofile", #"{"name":"Magpie Lossless"}"#),
        Call("POST", "metadataprofile", #"{"name":"Magpie Finds"}"#),
        Call("POST", "artist", #"{"foreignArtistId":"x","addOptions":{"monitor":"none"}}"#),
        Call("PUT", "artist/12", #"{"id":12,"monitored":true}"#),
        Call("PUT", "//API//V1//Artist//Editor//", #"{"artistIds":[12],"tags":[2],"applyTags":"remove"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[12],"tags":[2],"applyTags":"add"}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[12],"rootFolderPath":"/music/library","moveFiles":true}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[12],"monitorNewItems":"new"}"#),
        Call("PUT", "artist/editor", #"{"ArtistIds":[12],"MonitorNewItems":"New"}"#),
        Call("PUT", "album/monitor", #"{"albumIds":[3],"monitored":true}"#),
        Call("PUT", "album/monitor", #"{"albumIds":[3,4,5],"monitored":true}"#),
        Call("PUT", "album/3", #"{"id":3,"monitored":true}"#),
        Call("DELETE", "artist/12?deleteFiles=false&addImportListExclusion=false"),
        Call("DELETE", "artist/12?AddImportListExclusion=FALSE&deleteFiles=False"),
        Call("POST", "command", #"{"name":"AlbumSearch","albumIds":[3]}"#),
        Call("POST", "command", #"{"name":"RefreshArtist","artistId":12}"#),
        Call("DELETE", "trackfile/9"),
        Call("DELETE", "/API/V1/TrackFile/9/"),
        Call("DELETE", "trackfile/bulk", #"{"trackFileIds":[9,10]}"#),
        Call("DELETE", "/api/v1/TrackFile/Bulk", #"{"trackFileIds":[9]}"#),
    ]

    @Test(arguments: allowed)
    func allowedShapeIsSent(_ call: Call) async throws {
        let env = GateEnv()
        let t = MockTransport()
        for m in ["POST", "PUT", "DELETE"] { t.stub(method: m, pathSuffix: "", body: json(#"{"id":1}"#)) }
        let (client, _) = makeClient(t)
        let gate = await env.gate(client, enabled: true)
        let body = call.body.map { try! JSONDecoder().decode(JSONValue.self, from: json($0)) }
        _ = try await gate.send(call.method, call.path, body: body)
        let sent = try #require(t.requests.first)
        #expect(sent.url?.path.lowercased().hasPrefix("/lidarr/api/v1/") == true)
        #expect(sent.httpMethod == call.method)
        #expect(await gate.changeLog().count == 1)
    }

    @Test func twoGatesShareTheSwitchAndTheLog() async throws {
        let env = GateEnv()
        let t = MockTransport()
        t.stub(method: "POST", pathSuffix: "/tag", body: json(#"{"id":1}"#))
        let (client, _) = makeClient(t)
        let a = await env.gate(client, enabled: true)
        let b = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults)
        #expect(await b.enabled)

        _ = try await a.send("POST", "tag", body: JSONValue.object(["label": .string("a")]))
        _ = try await b.send("POST", "tag", body: JSONValue.object(["label": .string("b")]))
        // Concurrent appends from both instances all survive.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                let gate = i.isMultiple(of: 2) ? a : b
                group.addTask { _ = try await gate.send("POST", "tag", body: JSONValue.object(["label": .string("c\(i)")])) }
            }
            try await group.waitForAll()
        }
        let onDisk = try JSONDecoder().decode([ChangeLogEntry].self, from: Data(contentsOf: env.logURL))
        #expect(onDisk.count == 12)
        #expect(await a.changeLog() == onDisk)
        #expect(await b.changeLog() == onDisk)

        // Turning it off through one instance stops writes through the other.
        await a.setEnabled(false)
        await #expect(throws: WriteGateError.disabled) {
            _ = try await b.send("POST", "tag", body: JSONValue.object(["label": .string("late")]))
        }
        #expect(t.requests.count == 12)
    }

    @Test func unreadableLogRefusesTheWriteAndKeepsTheFile() async throws {
        let env = GateEnv()
        // Something exists at the log path but cannot be read as a file (stands in for protected data).
        try FileManager.default.createDirectory(at: env.logURL, withIntermediateDirectories: true)
        let (client, t) = makeClient()
        t.stub(method: "POST", pathSuffix: "/tag", body: json(#"{"id":1}"#))
        let gate = await env.gate(client, enabled: true)
        await #expect(throws: WriteGateError.logUnavailable) {
            _ = try await gate.send("POST", "tag", body: JSONValue.object(["label": .string("x")]))
        }
        #expect(t.requests.isEmpty)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: env.logURL.path, isDirectory: &isDir) && isDir.boolValue)
    }
}

@Suite struct LocalFileTests {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "magpie-lf-\(UUID().uuidString)/f.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func readFailureThrowsAndLeavesTheFile() throws {
        let url = try tempFile(#"[1,2,3]"#)
        struct Locked: Error {}
        #expect(throws: LocalFileError.unavailable) {
            _ = try LocalFile.load([Int].self, from: url, fallback: [], category: "test", read: { _ in throw Locked() })
        }
        #expect(try LocalFile.load([Int].self, from: url, fallback: [], category: "test") == [1, 2, 3])
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["f.json"])
    }

    @Test func damagedFileIsMovedAsideAndFallbackReturned() throws {
        let url = try tempFile("not json {")
        #expect(try LocalFile.load([Int].self, from: url, fallback: [7], category: "test") == [7])
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(!names.contains("f.json"))
        #expect(names.contains { $0.hasPrefix("f.json.unreadable-") })
    }

    @Test func missingFileIsFallback() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "magpie-lf-\(UUID().uuidString)/none.json")
        #expect(try LocalFile.load([Int].self, from: url, fallback: [], category: "test") == [])
    }

    @Test func unreadableLedgerRefusesEverything() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "magpie-ledger-\(UUID().uuidString)/ledger.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let ledger = Ledger(fileURL: url)
        let e = LedgerEntry(lidarrArtistId: 1, albumId: 2, rgMbid: MBID("0a3f5a6e-2f0b-4d8e-9d55-1b2c3d4e5f60")!,
                            createdArtist: true, wasMonitoredBefore: false, root: "/music/library", mode: .fallback)
        await #expect(throws: LocalFileError.unavailable) { try await ledger.record(e) }
        await #expect(throws: LocalFileError.unavailable) { _ = try await ledger.entries }
        await #expect(throws: LocalFileError.unavailable) { _ = try await ledger.entry(albumId: 2) }
    }
}

@Suite struct BodyKeyScanTests {
    typealias Call = WriteGateTests.Call

    /// Fix round 2: keys .NET would fold onto a checked name (U+017F "ſ" upper-cases to "S"), at any depth.
    static let nonASCIIKeys: [Call] = [
        Call("PUT", "artist/editor", #"{"artistIds":[1],"tags":[],"applyTagſ":"replace"}"#),
        Call("PUT", "artist/editor", #"{"deleteFileſ":true}"#),
        Call("POST", "artist", #"{"addOptions":{"addImportListExcluſion":true}}"#),
        Call("PUT", "artist/editor", #"{"artistIds":[1],"x":[{"ok":1},{"deleteFileſ":true}]}"#),
        Call("POST", "command", #"{"name":"AlbumSearch","nAme":"x"}"#),
    ]

    @Test(arguments: nonASCIIKeys)
    func refusedThroughTheGate(_ call: Call) async throws {
        let env = GateEnv()
        let t = MockTransport()
        for m in ["POST", "PUT", "DELETE"] { t.stub(method: m, pathSuffix: "", body: json("{}")) }
        let (client, _) = makeClient(t)
        let gate = await env.gate(client, enabled: true)
        let body = try JSONDecoder().decode(JSONValue.self, from: json(call.body!))
        await #expect(throws: WriteGateError.self) { _ = try await gate.send(call.method, call.path, body: body) }
        #expect(t.requests.isEmpty)
    }

    private func reason(_ method: String, _ path: String, raw: String) throws -> String? {
        ForbiddenWrites.reason(try WriteTarget(method: method, path: path), body: Data(raw.utf8))
    }

    @Test func rawBodiesAreScannedAsSent() throws {
        // Duplicate keys JSONSerialization would collapse (keeps the first; System.Text.Json takes the last).
        #expect(try reason("POST", "command", raw: #"{"name":"AlbumSearch","name":"RenameFiles"}"#) != nil)
        #expect(try reason("POST", "command", raw: #"{"name":"AlbumSearch","NAME":"AlbumSearch"}"#) != nil)
        #expect(try reason("PUT", "artist/editor",
                           raw: #"{"artistIds":[1],"tags":[{"a":1,"A":2}],"applyTags":"add"}"#) != nil)
        #expect(try reason("PUT", "artist/editor", raw: #"{"applyTags":"add","applyTags":"replace"}"#) != nil)
        // Non-ASCII keys, raw UTF-8 or escaped.
        #expect(try reason("PUT", "artist/editor", raw: #"{"applyTagſ":"replace"}"#) != nil)
        #expect(try reason("PUT", "artist/editor", raw: #"{"deleteFileſ":true}"#) != nil)
        #expect(try reason("POST", "artist", raw: #"{"a":[[{"addImportListExcluſion":true}]]}"#) != nil)
        // Escaped ASCII is decoded before comparing.
        #expect(try reason("POST", "command", raw: #"{"name":"AlbumSearch","name":"RenameFiles"}"#) != nil)
        // Not JSON / trailing data.
        #expect(try reason("POST", "tag", raw: #"{"label":"x"} {"label":"y"}"#) != nil)
        #expect(try reason("POST", "tag", raw: #"{"label":"x""#) != nil)
        // Non-ASCII values are fine; same key in sibling objects is fine.
        #expect(try reason("POST", "tag", raw: #"{"label":"café ſ"}"#) == nil)
        #expect(try reason("PUT", "album/monitor", raw: #" {"albumIds":[1,2],"monitored":true,"x":[{"id":1},{"id":2}]} "#) == nil)
        #expect(try reason("POST", "command", raw: #"{"name":"AlbumSearch","albumIds":[3]}"#) == nil)
    }

    /// Security L6 (audit E5): `\\uXXXX` and other escapes in raw bodies. The backslash is built at runtime so
    /// the bytes scanned really contain an escape (a Swift literal would decode it first).
    static let escapeCases: [(method: String, path: String, body: String, refused: Bool)] = [
        ("PUT", "artist/editor", #"{"artistIds":[1],"deleteFilBSu0065s":true}"#, true),
        ("PUT", "artist/editor", #"{"artistIds":[1],"applyTagBSu017f":"replace"}"#, true),
        ("PUT", "artist/editor", #"{"artistIds":[1],"applyTags":"replBSu0061ce"}"#, true),
        ("PUT", "artist/editor", #"{"artistIds":[1],"applyTags":"add","applyTagBSu0073":"replace"}"#, true),
        ("PUT", "artist/editor", #"{"artistIds":[1],"applyTags":"add","APPLYTAGBSu0053":"replace"}"#, true),
        ("POST", "command", #"{"name":"AlbumSearch","NBSu0041ME":"RenameFiles"}"#, true),
        ("POST", "command", #"{"nBSu0061me":"DeleteArtist"}"#, true),
        ("POST", "command", #"{"name":"AlbumBSu0053earch","albumIds":[1]}"#, false),
        ("POST", "artist", #"{"addOptions":{"addImportListExclusioBSu006E":true}}"#, true),
        ("POST", "artist", #"{"BSud83dBSude00":1}"#, true),
        ("POST", "artist", #"{"deleteFiles":"BSu0074rue"}"#, true),
        ("POST", "artist", #"{"deleteFileBSu0053":true}"#, true),
        // Hardening: control characters in keys, escaped or not, are refused (the scanner's key identity
        // must match the parser's).
        ("POST", "artist", #"{"deleteFilesBSu0000":true}"#, true),
        ("POST", "artist", #"{"deleteFilesBSu001f":true}"#, true),
        ("POST", "artist", #"{"deleteFilesBSt":true}"#, true),
        ("POST", "artist", #"{"deleteFilesBSn":true}"#, true),
        ("POST", "artist", #"{"aBSbBSfBSr":1}"#, true),
        ("POST", "artist", "{\"deleteFiles\u{09}\":true}", true),
        // Escapes that are not control characters stay fine in keys; control escapes in values stay fine.
        ("POST", "tag", #"{"laBSu0062el":"x"}"#, false),
        ("POST", "tag", #"{"label":"aBStbBSnBSu0001"}"#, false),
        ("POST", "tag", #"{"label":"aBSu0020b"}"#, false),
    ]

    @Test(arguments: escapeCases.indices)
    func escapesInRawBodies(_ n: Int) throws {
        let c = Self.escapeCases[n]
        let backslash = String(UnicodeScalar(0x5C))
        let raw = c.body.replacingOccurrences(of: "BS", with: backslash)
        let bytes = Data(raw.utf8)
        // The bytes hold real escapes: one backslash per "BS" and no literal "BS" left.
        #expect(bytes.filter { $0 == 0x5C }.count == c.body.components(separatedBy: "BS").count - 1)
        #expect(!raw.contains("BS"))
        let reason = ForbiddenWrites.reason(try WriteTarget(method: c.method, path: c.path), body: bytes)
        #expect((reason != nil) == c.refused, "\(c.method) \(c.path) \(raw): \(reason ?? "allowed")")
    }
}
