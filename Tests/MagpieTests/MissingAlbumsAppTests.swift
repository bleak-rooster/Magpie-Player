import Foundation
@testable import LidarrKit
import MagpieCore
import MagpieTestSupport
import Requests
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"jordan"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let lidarrScope = LidarrClient(base: lidarrBase, apiKey: "key", transport: MockTransport()).instanceScope

/// Round 27 R (owner, 2026-11-14, D289–D294): Settings › Lidarr › Missing albums. "Search for missing albums now"
/// (confirmed), "Search automatically" (Off / Every day / Every week, checked when Magpie becomes active) and "Clear all
/// downloads and search again" (confirmed, counting what it acts on; another app's too, per Q2). The plan's words, hidden
/// without Lidarr, disabled without "Allow Magpie to change your library", in all four setups.
@MainActor @Suite(.serialized) struct MissingAlbumsAppTests {
    typealias Copy = MissingAlbumsCopy

    @Test func theCopyIsThePlans() {
        #expect(Copy.section == "Missing albums")
        #expect(Copy.searchNow == "Search for missing albums now")
        #expect(Copy.confirmTitle == "Search for every missing album?")
        #expect(Copy.confirmMessage == "Lidarr looks for every album it watches that you don\u{2019}t have yet. This can take a while and may bring in a lot of music.")
        #expect(Copy.confirmButton == "Search")
        #expect(Copy.every == "Search automatically")
        #expect(MissingAlbumSchedule.Every.allCases.map(Copy.title) == ["Off", "Every day", "Every week"])
        #expect(Copy.everyFooter == "Magpie asks Lidarr when you open it, once the time has passed.")
        #expect(Copy.lastAsked(nil, now: Date()) == "Not asked yet")
        #expect(Copy.lastAsked(Date(timeIntervalSinceNow: -7_200), now: Date()).hasPrefix("Last asked: "))
        #expect(Copy.answer(.sent).text == "Lidarr is looking for your missing albums.")
        #expect(Copy.answer(.sent).symbol == "magnifyingglass")
        #expect(Copy.answer(.alreadyRunning).text == "Lidarr is already looking for missing albums.")
        #expect(Copy.answer(.alreadyRunning).symbol == "clock")
        #expect(Copy.answer(.refused).text == "Couldn\u{2019}t ask Lidarr just now. Nothing was sent.")
        #expect(Copy.answer(.lostAnswer).text == "Magpie couldn\u{2019}t hear back from Lidarr. It may already be looking.")
        #expect(Copy.answer(.refused).symbol == "exclamationmark.triangle" && Copy.answer(.lostAnswer).symbol == "exclamationmark.triangle")
        #expect(Copy.clearAll == "Clear all downloads and search again")
        #expect(Copy.clearConfirmButton == "Clear and search again")
        #expect(Copy.clearProgress(12, of: 40) == "Clearing downloads: 12 of 40")
    }

    /// The confirmation counts what it will act on; its second line names another app's (Q2).
    @Test func confirmationCountsRows() {
        #expect(Copy.clearTitle(40) == "Clear 40 downloads and search again?")
        #expect(Copy.clearTitle(1) == "Clear 1 download and search again?")
        let base = "Each one is stopped, removed and blocked so the same copy isn\u{2019}t picked again. Once they\u{2019}re all gone, "
            + "Magpie asks Lidarr to look for those albums again. Anything importing is left alone."
        #expect(Copy.clearMessage(foreign: 0, more: 0) == base)
        #expect(Copy.clearMessage(foreign: 3, more: 0) == base + "\n\n3 of them were started by another app.")
        #expect(Copy.clearMessage(foreign: 1, more: 0) == base + "\n\n1 of them was started by another app.")
        #expect(Copy.clearMessage(foreign: 0, more: 7).contains("7 more downloads are still in the queue."))
    }

    @Test func clearOutcomeReadsPlainly() {
        var o = ClearAllOutcome()
        o.cleared = 40; o.searchedAlbums = 38
        #expect(Copy.clearOutcome(o) == "Cleared 40 downloads. Looking for 38 albums again.")
        o.clearedWithoutSearch = 2; o.notCleared = 3; o.left = 5
        #expect(Copy.clearOutcome(o) == "Cleared 40 downloads. Looking for 38 albums again. 2 were cleared without a new search. "
                + "Couldn\u{2019}t clear 3 downloads. They were left as they were. 5 more downloads are still in the queue.")
        var one = ClearAllOutcome()
        one.cleared = 1; one.searchedAlbums = 1
        #expect(Copy.clearOutcome(one) == "Cleared 1 download. Looking for 1 album again.")
        var off = ClearAllOutcome()
        off.changesOff = true
        #expect(Copy.clearOutcome(off) == Copy.changesOff)
        #expect(Copy.clearOutcome(ClearAllOutcome()) == LidarrDownloadsCopy.empty)
    }

    /// §5: Settings may name Lidarr; nothing names Soulseek or Tubifarry, or says "blocklist".
    @Test func copyNamesOnlyLidarr() {
        var o = ClearAllOutcome()
        o.cleared = 2; o.searchedAlbums = 1; o.clearedWithoutSearch = 1; o.notCleared = 1; o.left = 1
        let texts = [Copy.section, Copy.searchNow, Copy.confirmTitle, Copy.confirmMessage, Copy.every, Copy.everyFooter,
                     Copy.clearAll, Copy.clearTitle(3), Copy.clearMessage(foreign: 2, more: 4), Copy.clearOutcome(o),
                     Copy.clearProgress(1, of: 2), Copy.changesOff]
            + MissingAlbumSchedule.Every.allCases.map(Copy.title)
            + [MissingAlbumSchedule.Answer.sent, .alreadyRunning, .refused, .lostAnswer].map { Copy.answer($0).text }
        for text in texts {
            for word in ["Soulseek", "Tubifarry", "slskd", "blocklist", "Navidrome", "Aurral", "torrent"] {
                #expect(!text.localizedCaseInsensitiveContains(word), "\(text)")
            }
        }
    }

    // MARK: - With a model

    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!
    let data = FileManager.default.temporaryDirectory.appending(path: "MissingAlbumsAppTests-\(UUID().uuidString)")

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music"}]"#.utf8))
        t.stub(pathSuffix: "/api/v1/command", body: Data("[]".utf8))
        t.stub(method: "POST", pathSuffix: "/api/v1/command", status: 201,
               body: Data(#"{"id":90,"name":"MissingAlbumSearch","status":"queued"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/queue/details", body: Data("[]".utf8))
    }

    private func model() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: data, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    private func tearDown(_ model: AppModel) {
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
        try? FileManager.default.removeItem(at: data)
    }

    private var missingSearches: [URLRequest] {
        transport.inner.requests.filter { r in
            r.httpMethod == "POST" && r.url?.path.hasSuffix("/api/v1/command") == true
                && (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["name"] as? String) == "MissingAlbumSearch"
        }
    }

    @Test func section_hiddenWithoutLidarr() async throws {
        let model = model()
        defer { tearDown(model) }
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        #expect(!model.showsMissingAlbums)
        model.missingAlbumsSceneChanged(active: true)
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(model.showsMissingAlbums)
        model.disconnectLidarr()
        #expect(!model.showsMissingAlbums)
    }

    @Test func section_disabledWithoutChangesAllowed() async throws {
        let model = model()
        defer { tearDown(model) }
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(!model.missingAlbumsUsable, "off until changes are allowed")
        #expect(Copy.footer(changesAllowed: false) == "Turn on \u{201C}Allow Magpie to change your library\u{201D} first.")
        #expect(Copy.footer(changesAllowed: true) == Copy.everyFooter)
        await model.searchMissingAlbumsNow()
        #expect(missingSearches.isEmpty)
        #expect(model.missingAlbums.searchAnswer == .refused)
        await model.setChangesAllowed(true)
        #expect(model.missingAlbumsUsable)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(!model.missingAlbumsUsable, "offline: disabled under the offline notice")
        await model.runMissingAlbumSchedule()
        #expect(missingSearches.isEmpty, "nothing scheduled while offline")
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
    }

    @Test func searchNowSendsOnceAndSaysSo() async throws {
        let model = model()
        defer { tearDown(model) }
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        #expect(model.missingSearchLastAsked == nil)
        await model.searchMissingAlbumsNow()
        #expect(missingSearches.count == 1)
        #expect(model.missingAlbums.searchAnswer == .sent)
        #expect(model.missingSearchLastAsked != nil)
        // At once again: the gate's ten minutes.
        await model.searchMissingAlbumsNow()
        #expect(missingSearches.count == 1)
        #expect(model.missingAlbums.searchAnswer == .alreadyRunning)
    }

    /// Checked when Magpie becomes active; due once a day; changes off asks nothing and keeps the time.
    @Test func scheduleRunsWhenActive() async throws {
        let model = model()
        defer { tearDown(model) }
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(model.missingSearchEvery == .off, "Off by default")
        model.missingSearchEvery = .day
        await model.runMissingAlbumSchedule()
        #expect(missingSearches.isEmpty, "changes off: nothing")
        #expect(model.missingSearchLastAsked == nil)
        await model.setChangesAllowed(true)
        model.missingAlbumsSceneChanged(active: true)
        #expect(await eventually { self.missingSearches.count == 1 })
        #expect(await eventually { model.missingSearchLastAsked != nil })
        await model.runMissingAlbumSchedule()
        #expect(missingSearches.count == 1, "not due again for a day")
        // A day on (the gate's own ten-minute record runs on the real clock, so it is cleared as a day would).
        UserDefaults(suiteName: gateSuite)?.removeObject(forKey: MissingAlbumSearch.recordKey(scope: lidarrScope))
        let tomorrow = Date().addingTimeInterval(25 * 3_600)
        await model.runMissingAlbumSchedule(now: tomorrow)
        #expect(missingSearches.count == 2)
        #expect(model.missingSearchLastAsked == tomorrow)
        model.missingAlbumsSceneChanged(active: false)
        #expect(missingSearches.count == 2)
    }

    @Test func forgottenOnDisconnect() async throws {
        let model = model()
        defer { tearDown(model) }
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        model.missingSearchEvery = .week
        await model.searchMissingAlbumsNow()
        let suite = try #require(UserDefaults(suiteName: gateSuite))
        #expect(suite.object(forKey: MissingAlbumSearch.recordKey(scope: lidarrScope)) != nil)
        model.disconnectLidarr()
        for key in [MissingAlbumSearch.recordKey(scope: lidarrScope), MissingAlbumSchedule.everyKey(scope: lidarrScope),
                    MissingAlbumSchedule.askedKey(scope: lidarrScope)] {
            #expect(suite.object(forKey: key) == nil, "\(key)")
        }
    }

    /// Navidrome alone and + Aurral: no section, nothing scheduled or sent. + Lidarr and all: shown.
    @Test func fourSetups() async throws {
        for (lidarr, aurral) in [(false, false), (false, true), (true, false), (true, true)] {
            #expect(MissingAlbumsPresentation.shows(lidarrConnected: lidarr, aurralConnected: aurral) == lidarr)
        }
        let model = model()
        defer { tearDown(model) }
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        UserDefaults(suiteName: gateSuite)?.set("day", forKey: MissingAlbumSchedule.everyKey(scope: lidarrScope))
        await model.runMissingAlbumSchedule()
        await model.searchMissingAlbumsNow()
        #expect(await model.prepareClearAll() == nil)
        #expect(missingSearches.isEmpty && transport.inner.requests.allSatisfy { !($0.url?.path.contains("/api/v1/") ?? false) })
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(model.showsMissingAlbums)
    }

    /// Clear all with nothing to clear says so; Lidarr unreachable says so; nothing is sent either way.
    @Test func clearAllPrepares() async throws {
        let model = model()
        defer { tearDown(model) }
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        #expect(await model.prepareClearAll() == nil, "an empty queue: no confirmation")
        #expect(model.missingAlbums.clearMessage == LidarrDownloadsCopy.empty)
        #expect(transport.inner.requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" || !($0.url?.path.contains("/api/v1/queue") ?? false) })
    }
}
