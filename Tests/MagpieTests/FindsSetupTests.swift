import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!

/// Task 6.1: the Finds folder is confirmed by the owner (G2), matched to a Navidrome library (B6), kept per
/// Lidarr + Navidrome, and setting it up writes nothing to Lidarr (G5).
@MainActor
@Suite(.serialized) struct FindsSetupTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    func stub(roots: [String], libraries: [(Int, String)], recycleBin: String = "") {
        let rows = roots.enumerated().map { #"{"id":\#($0.offset + 1),"path":"\#($0.element)"}"# }.joined(separator: ",")
        transport.inner.stub(pathSuffix: "/api/v1/rootfolder", body: Data("[\(rows)]".utf8))
        let libs = libraries.map { #"{"id":\#($0.0),"name":"Lib \#($0.0)","path":"\#($0.1)"}"# }.joined(separator: ",")
        transport.inner.stub(pathSuffix: "/api/library", body: Data("[\(libs)]".utf8))
        transport.inner.stub(pathSuffix: "/api/v1/config/mediamanagement", body: Data(#"{"recycleBin":"\#(recycleBin)"}"#.utf8))
    }

    func connected(key: String = "key") async throws -> AppModel {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: key)
        return model
    }

    func cleanUp(_ model: AppModel) {
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    @Test func offByDefaultAndTryUnchanged() async throws {
        stub(roots: ["/music/library", "/music/samples"], libraries: [(1, "/music/library"), (2, "/music/samples")])
        let model = try await connected()
        let setup = try #require(model.findsSetup)
        #expect(setup.useFindsFolder == false, "\u{201C}Use a Finds folder\u{201D} is off by default")
        #expect(setup.findsRoot == nil, "G2: a root named samples is never picked by itself")
        #expect(setup.isComplete == false)
        let before = model.tryAvailability
        model.setUseFindsFolder(true)
        #expect(model.findsSetup?.useFindsFolder == true)
        #expect(model.tryAvailability == before, "Try stays available; only where it goes depends on Finds")
        cleanUp(model)
    }

    @Test func rootMustBeItsOwnFolder() async throws {
        stub(roots: ["/music/library", "/music/library/samples", "/music/samples", "/music/samples-old"],
             libraries: [(1, "/music/library"), (2, "/music/samples")])
        let model = try await connected()
        model.chooseRoot("/music/library")
        #expect(model.findsRootProblem("/music/library/samples") == .nested)
        #expect(model.findsRootProblem("/music/library") == .isMainRoot)
        #expect(model.findsRootProblem("/music/samples") == nil, "a sibling with a longer name is not nested")
        #expect(model.findsRootProblem("/music/elsewhere") == .notARootFolder)
        #expect(throws: FindsProblem.nested) { try model.confirmFindsRoot("/music/library/samples") }
        #expect(model.findsSetup?.findsRoot == nil)
        try model.confirmFindsRoot("/music/samples")
        #expect(model.findsSetup?.findsRoot == "/music/samples")
        // The main root can't then be moved onto the Finds folder.
        model.chooseRoot("/music/samples")
        #expect(model.lidarrSetup?.rootFolderPath == "/music/library")
        cleanUp(model)
    }

    @Test func onlyRootIsNeverTheFindsFolder() async throws {
        stub(roots: ["/music"], libraries: [(1, "/music")])
        let model = try await connected()
        #expect(model.lidarrSetup?.rootFolderPath == "/music")
        #expect(model.findsRootProblem("/music") == .isMainRoot)
        cleanUp(model)
    }

    @Test func libraryMustBeTheSameFolder() async throws {
        stub(roots: ["/music/library", "/music/samples"], libraries: [(1, "/music/library"), (2, "/music/samples")])
        let model = try await connected()
        let libraries = try await model.navidromeLibraries()
        #expect(libraries.map(\.id) == [1, 2])
        try model.confirmFindsRoot("/music/samples")
        #expect(throws: FindsProblem.mainRootFirst) { try model.chooseFindsLibrary(libraries[1], among: libraries, mapping: nil) }
        model.chooseRoot("/music/library")
        #expect(throws: FindsProblem.pathsDiffer) { try model.chooseFindsLibrary(libraries[0], among: libraries, mapping: nil) }
        try model.chooseFindsLibrary(libraries[1], among: libraries, mapping: nil)
        #expect(model.findsSetup?.library?.id == 2)
        #expect(model.findsSetup?.isComplete == false, "still off")
        model.setUseFindsFolder(true)
        #expect(model.findsSetup?.isComplete == true)
        // Confirming another root starts the library step again.
        model.lidarrSetup?.rootFolderPath = nil
        try model.confirmFindsRoot("/music/library")
        #expect(model.findsSetup?.library == nil)
        #expect(model.findsSetup?.isComplete == false)
        cleanUp(model)
    }

    /// B6: Lidarr sees /data/music, Navidrome /music.
    @Test func mappingWhenPathsDiffer() async throws {
        stub(roots: ["/data/music/library", "/data/music/samples"], libraries: [(1, "/music/library"), (2, "/music/samples")])
        let model = try await connected()
        let libraries = try await model.navidromeLibraries()
        model.chooseRoot("/data/music/library")
        try model.confirmFindsRoot("/data/music/samples")
        #expect(throws: FindsProblem.pathsDiffer) { try model.chooseFindsLibrary(libraries[1], among: libraries, mapping: nil) }
        let wrong = PathMapping(lidarrPrefix: "/data/music/samples", navidromePrefix: "/music/library")
        #expect(throws: FindsProblem.mappingMismatch) { try model.chooseFindsLibrary(libraries[1], among: libraries, mapping: wrong) }
        let mapping = PathMapping(lidarrPrefix: "/data/music", navidromePrefix: "/music")
        try model.chooseFindsLibrary(libraries[1], among: libraries, mapping: mapping)
        #expect(model.findsSetup?.mapping == mapping)
        #expect(model.findsSetup?.navidromeRoot == "/music/samples")
        cleanUp(model)
    }

    @Test func libraryInsideAnotherLibraryRefused() async throws {
        // G2: the Finds folder must not sit inside the main Navidrome library either.
        stub(roots: ["/data/library", "/data/samples"], libraries: [(1, "/music"), (2, "/music/samples")])
        let model = try await connected()
        let libraries = try await model.navidromeLibraries()
        model.chooseRoot("/data/library")
        try model.confirmFindsRoot("/data/samples")
        let mapping = PathMapping(lidarrPrefix: "/data", navidromePrefix: "/music")
        #expect(throws: FindsProblem.overlapsLibrary) { try model.chooseFindsLibrary(libraries[1], among: libraries, mapping: mapping) }
        #expect(model.findsSetup?.library == nil)
        cleanUp(model)
    }

    /// Review fix 2: one Navidrome library `/music` holds the main library; a root-to-root "mapping" onto it
    /// must not pass.
    @Test func mainLibraryIsNeverTheFindsLibrary() async throws {
        stub(roots: ["/music/library", "/music/samples"], libraries: [(1, "/music")])
        let model = try await connected()
        let libraries = try await model.navidromeLibraries()
        model.chooseRoot("/music/library")
        try model.confirmFindsRoot("/music/samples")
        let swap = PathMapping(lidarrPrefix: "/music/samples", navidromePrefix: "/music")
        #expect(throws: FindsProblem.mainRootNotMapped) { try model.chooseFindsLibrary(libraries[0], among: libraries, mapping: swap) }
        // A real mount mapping that covers the main root doesn't put the Finds folder on `/music` either.
        let mount = PathMapping(lidarrPrefix: "/music", navidromePrefix: "/music")
        #expect(throws: FindsProblem.mappingMismatch) { try model.chooseFindsLibrary(libraries[0], among: libraries, mapping: mount) }
        // The view's pre-fill is a mount-prefix guess, not the root-to-root swap.
        #expect(PathMapping.suggested(lidarr: "/music/samples", navidrome: "/music") == swap,
                "nothing shared to drop: the guess still has to pass the main-root check")
        #expect(model.findsSetup?.library == nil)
        cleanUp(model)
    }

    @Test func keptPerLidarrAndNavidromeAndForgotten() async throws {
        stub(roots: ["/music/library", "/music/samples"], libraries: [(1, "/music/library"), (2, "/music/samples")])
        let model = try await connected()
        let libraries = try await model.navidromeLibraries()
        model.chooseRoot("/music/library")
        model.setUseFindsFolder(true)
        try model.confirmFindsRoot("/music/samples")
        try model.chooseFindsLibrary(libraries[1], among: libraries, mapping: nil)
        let restored = makeModel()
        restored.resumeSavedSession()
        #expect(restored.findsSetup?.findsRoot == "/music/samples", "kept across launches")
        #expect(restored.findsSetup?.library?.id == 2)

        // Another Lidarr (new key) starts afresh, and so does the first one after a disconnect.
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "other-key")
        #expect(model.findsSetup?.findsRoot == nil)
        try model.confirmFindsRoot("/music/samples")
        model.disconnectLidarr()
        #expect(model.findsSetup == nil)
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "other-key")
        #expect(model.findsSetup?.findsRoot == nil, "disconnect forgets the Finds folder")

        try model.confirmFindsRoot("/music/samples")
        model.signOut()
        #expect(model.findsSetup == nil)
        let again = try await connected(key: "other-key")
        #expect(again.findsSetup?.findsRoot == nil, "sign-out forgets the Finds folder")
        #expect(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("magpie.finds.") } == false)
        cleanUp(again)
    }

    @Test func setupWritesNothingToLidarr() async throws {
        stub(roots: ["/music/library", "/music/samples"], libraries: [(1, "/music/library"), (2, "/music/samples")])
        let model = try await connected()
        await model.setChangesAllowed(true)
        let libraries = try await model.navidromeLibraries()
        model.chooseRoot("/music/library")
        model.setUseFindsFolder(true)
        try model.confirmFindsRoot("/music/samples")
        try model.chooseFindsLibrary(libraries[1], among: libraries, mapping: nil)
        let lidarrCalls = transport.inner.requests.filter { $0.url?.port == 8686 }
        #expect(!lidarrCalls.isEmpty)
        #expect(lidarrCalls.allSatisfy { ($0.httpMethod ?? "GET") == "GET" }, "G5: setting up Finds is local only")
        cleanUp(model)
    }

    @Test func recycleBinWarning() async throws {
        stub(roots: ["/music/library", "/music/samples"], libraries: [], recycleBin: "")
        let model = try await connected()
        #expect(model.findsNeedsRecycleBinWarning)
        #expect(FindsCopy.recycleBinOff.contains("recycle bin"))
        cleanUp(model)
    }

    @Test func recycleBinSetNoWarning() async throws {
        stub(roots: ["/music/library", "/music/samples"], libraries: [], recycleBin: "/trash")
        let model = try await connected()
        #expect(!model.findsNeedsRecycleBinWarning)
        cleanUp(model)
    }

    @Test func confirmationCopy() {
        #expect(FindsCopy.confirmTitle("/music/samples") == "Use /music/samples for Finds?")
        #expect(FindsCopy.confirmMessage == "Magpie will only delete files it brought in here.")
        for problem in [FindsProblem.notAbsolute, .notARootFolder, .sameAsOther, .nested, .isMainRoot, .pathsDiffer, .mappingMismatch,
                        .overlapsLibrary, .mainRootFirst, .mainRootNotMapped, .notConnected] {
            #expect(!problem.message.isEmpty)
        }
    }
}
