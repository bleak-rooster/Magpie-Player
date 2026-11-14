import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Testing
@testable import Magpie

private let okJSON = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"jordan"}
"""#.utf8)
private func extensions(_ names: [String]) -> Data {
    let list = names.map { #"{"name":"\#($0)","versions":[1]}"# }.joined(separator: ",")
    return Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","openSubsonicExtensions":[\#(list)]}}"#.utf8)
}
private func lyricsJSON(_ words: String) -> Data {
    Data(#"""
    {"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[{"lang":"eng","synced":true,"line":[{"start":1000,"value":"\#(words)"}]}]}}}
    """#.utf8)
}
private let noLyricsJSON = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[]}}}"#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

/// Navidrome and LRCLIB to the mock (by path), Aurral to its stub; a held song's lyrics read answers only once released
/// (at most 10 s, so a test that forgets fails rather than hangs). Every request is recorded, and every lyrics read
/// whose wait was cancelled.
final class LyricsRouting: HTTPTransport, @unchecked Sendable {
    let aurral = StubAurral()
    let mock = MockTransport()
    private struct State {
        var held: Set<String> = []
        var sent: [URLRequest] = []
        var cancelled: [URLRequest] = []
        var down: Set<String> = []
        var failOnce: Set<String> = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func hold(_ songId: String) { state.withLock { _ = $0.held.insert(songId) } }
    func release(_ songId: String) { state.withLock { _ = $0.held.remove(songId) } }
    var sent: [URLRequest] { state.withLock { $0.sent } }
    var cancelled: [URLRequest] { state.withLock { $0.cancelled } }
    /// The Navidrome host fails like an unplugged server.
    func setDown(_ down: Bool) { state.withLock { $0.down = down ? ["192.168.1.2"] : [] } }
    func setDown(hosts: Set<String>) { state.withLock { $0.down = hosts } }
    /// The song's next lyrics read fails like a dropped connection (once).
    func failOnce(_ songId: String) { state.withLock { _ = $0.failOnce.insert(songId) } }
    /// LRCLIB calls whose wait was cancelled.
    var cancelledOnline: Int { cancelled.filter { $0.url?.host() == "lrclib.net" }.count }

    /// Lyrics reads sent for `id`.
    func lyricsReads(_ id: String) -> Int { sent.filter { lyricsRead($0) == id }.count }
    func cancelledReads(_ id: String) -> Int { cancelled.filter { lyricsRead($0) == id }.count }

    /// The song a lyrics read is for (nil for any other request).
    func lyricsRead(_ r: URLRequest) -> String? {
        r.url?.path.hasSuffix("/rest/getLyricsBySongId") == true ? query(r)["id"] : nil
    }
    var lrclibCalls: [URLRequest] { sent.filter { $0.url?.host() == "lrclib.net" } }

    func query(_ r: URLRequest) -> [String: String] {
        let items = r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withLock { $0.sent.append(request) }
        // A held song's lyrics read, or every LRCLIB call while "lrclib" is held.
        let song = lyricsRead(request) ?? (request.url?.host() == "lrclib.net" ? "lrclib" : nil)
        let until = Date().addingTimeInterval(10)
        while let song, state.withLock({ $0.held.contains(song) }) {
            guard Date() < until else { throw URLError(.timedOut) }
            do { try await Task.sleep(for: .milliseconds(5)) } catch {
                state.withLock { $0.cancelled.append(request) }
                throw error
            }
        }
        if let host = request.url?.host, state.withLock({ $0.down.contains(host) }) { throw URLError(.cannotConnectToHost) }
        if let song = lyricsRead(request), state.withLock({ $0.failOnce.remove(song) != nil }) {
            throw URLError(.networkConnectionLost)
        }
        if request.url?.host == aurral.host { return try await aurral.send(request) }
        return try await mock.send(request)
    }
}

/// Round 27 L (owner, 2026-11-14, items 14 and 15): every song played asks the server for its lyrics in the background
/// (nd-lyrics' trigger), once per song per session, and the pane uses what came back (D310); Find lyrics online (off by
/// default) asks LRCLIB only when the server had none or took more than 6 s, and the server's read goes on (D311); the
/// footer says where the lyrics came from (D313); identical in all four setups (D314). No test reaches the internet:
/// LRCLIB's host answers from the mock.
@MainActor @Suite(.serialized) final class LyricsTriggerAppTests {
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "LyricsTriggerAppTests.\(UUID().uuidString)")!
    let aurralStore = MemoryAurralStore()
    let transport = LyricsRouting()
    /// Song ids the server has lyrics for.
    let withLyrics = OSAllocatedUnfairLock(initialState: Set(["s1"]))

    deinit { store.clear() }

    func model(songLyrics: Bool = true, lidarr: Bool = false, aurral: Bool = false, urls: [URL] = [home]) async throws -> AppModel {
        let mock = transport.mock
        mock.stub(pathSuffix: "/rest/ping", body: okJSON)
        mock.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        mock.stub(pathSuffix: "/rest/scrobble", body: okJSON)
        mock.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        mock.stub(pathSuffix: "/rest/getOpenSubsonicExtensions",
                  body: extensions(songLyrics ? ["songLyrics", "formPost"] : ["formPost"]))
        let have = withLyrics
        mock.stub(pathSuffix: "/rest/getLyricsBySongId") { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
            return .init(status: 200, body: have.withLock { $0.contains(id) } ? lyricsJSON("words of \(id)") : noLyricsJSON)
        }
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: URL(string: "http://192.168.1.2:8686")!, apiKey: "test-key")) }
        if aurral { transport.aurral.useAurral213() }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), aurralStore: aurralStore,
                             matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), previewTransport: transport, defaults: defaults, systemNowPlaying: false,
                             notifications: false, network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        model.aurralFeeds.phoneRegion = { nil }
        // LRCLIB answers from the mock: the app's own transport would go to the internet.
        model.lyricsKeeper.lrclib = LrcLib(transport: transport, userAgent: LrcLib.userAgent(version: AppModel.marketingVersion))
        try await model.signIn(urls: urls, username: "jordan", password: "pw")
        if aurral {
            _ = try await model.connectAurral(base: transport.aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return model
    }

    func song(_ id: String) -> Song { PlayerTests.song(id) }

    static let found = Data(#"{"id":7,"trackName":"Ts2","artistName":"A","albumName":"B","duration":200,"instrumental":false,"plainLyrics":"found words","syncedLyrics":null}"#.utf8)

    func stubLrclib(status: Int = 200, body: Data = LyricsTriggerAppTests.found) {
        transport.mock.stub(pathSuffix: "/api/get", status: status, body: body)
    }

    // MARK: - D310: the trigger

    @Test func trigger_asksServerWhenSongStartsEvenWithPaneClosed() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.play([song("s1"), song("s2")], startAt: 0)
        #expect(await eventually { self.transport.lyricsReads("s1") == 1 }, "asked with no pane open")
        #expect(await eventually { model.lyricsKeeper.shown("s1") != nil })
        model.player.next()
        #expect(await eventually { self.transport.lyricsReads("s2") == 1 })
        #expect(await eventually { model.lyricsKeeper.library("s2") == .some(nil) }, "a none is kept too")
        #expect(transport.lrclibCalls.isEmpty, "the trigger never asks LRCLIB")
    }

    @Test func trigger_oncePerSongPerSession() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.play([song("s1"), song("s2")], startAt: 0)
        #expect(await eventually { model.lyricsKeeper.library("s1") != nil })
        model.player.next()
        #expect(await eventually { model.lyricsKeeper.library("s2") != nil })
        model.player.previous()
        model.play([song("s2"), song("s1")], startAt: 0)
        model.play([song("s1")], startAt: 0)
        #expect(await eventually(0.3) { self.transport.lyricsReads("s1") > 1 || self.transport.lyricsReads("s2") > 1 } == false)
        #expect(transport.lyricsReads("s1") == 1 && transport.lyricsReads("s2") == 1)
    }

    @Test func trigger_notOfflineOrWithoutSongLyrics() async throws {
        let without = try await model(songLyrics: false)
        without.play([song("s1")], startAt: 0)
        #expect(await eventually(0.3) { self.transport.lyricsReads("s1") > 0 } == false, "no songLyrics: not asked")
        without.signOut()

        let offline = try await model()
        defer { offline.signOut() }
        offline.updatePreferences { $0.downloads.offlineMode = .on }
        offline.play([song("s1")], startAt: 0)
        #expect(await eventually(0.3) { self.transport.lyricsReads("s1") > 0 } == false, "offline: nothing asked")
        #expect(try await offline.lyricsForPane(song("s1")) == nil, "offline: only what's kept")
        #expect(transport.lyricsReads("s1") == 0)
    }

    /// L fix round 1 (I1): a skip never abandons the older song's read (nd-lyrics may be fetching for it): it runs to
    /// its answer and is kept, and the older song is never sent again.
    @Test func trigger_newSongDoesNotResendOld() async throws {
        let model = try await model()
        defer { model.signOut() }
        transport.hold("s1")
        model.play([song("s1"), song("s2")], startAt: 0)
        #expect(await eventually { self.transport.lyricsReads("s1") == 1 })
        model.player.next()
        #expect(await eventually { self.transport.lyricsReads("s2") == 1 })
        #expect(await eventually(0.3) { self.transport.cancelledReads("s1") > 0 } == false, "the older read goes on")
        transport.release("s1")
        #expect(await eventually { model.lyricsKeeper.library("s1") != nil }, "the older answer completes and is kept")
        #expect(model.lyricsKeeper.shown("s1")?.source == .library)
        model.player.previous()
        #expect(await eventually { model.player.queue.current?.song.id == "s1" })
        #expect(await eventually(0.3) { self.transport.lyricsReads("s1") > 1 } == false, "the older song isn't asked again")
    }

    /// I1: at most three background reads at once. With three out, the current song waits for a slot; a song that is no
    /// longer current when a slot frees isn't asked (nor marked asked), so it is asked when it plays again.
    @Test func trigger_atMostThreeInFlight() async throws {
        let model = try await model()
        defer { model.signOut() }
        for id in ["s1", "s2", "s3", "s4"] { transport.hold(id) }
        model.play(["s1", "s2", "s3", "s4", "s5"].map(song), startAt: 0)
        for id in ["s1", "s2", "s3"] {
            #expect(await eventually { self.transport.lyricsReads(id) == 1 }, "\(id)")
            if id != "s3" { model.player.next() }
        }
        model.player.next()   // s4, with three out
        #expect(await eventually { model.lyricsKeeper.waiting == "s4" })
        #expect(transport.lyricsReads("s4") == 0 && !model.lyricsKeeper.hasAskedServer("s4"))
        transport.release("s1")
        #expect(await eventually { self.transport.lyricsReads("s4") == 1 }, "a slot freed while s4 is current")
        model.player.next()   // s5: s2, s3, s4 out
        #expect(await eventually { model.lyricsKeeper.waiting == "s5" })
        model.player.previous()   // back to s4 (asked already)
        #expect(await eventually { model.player.queue.current?.song.id == "s4" })
        transport.release("s2")
        #expect(await eventually { model.lyricsKeeper.waiting == nil })
        #expect(await eventually(0.3) { self.transport.lyricsReads("s5") > 0 } == false, "s5 isn't current: not sent")
        #expect(!model.lyricsKeeper.hasAskedServer("s5"))
        model.player.next()   // s5 again, two out
        #expect(await eventually { self.transport.lyricsReads("s5") == 1 })
        for id in ["s3", "s4"] { transport.release(id) }
    }

    /// M2: a song that started while offline is asked once Magpie is back online.
    @Test func trigger_asksOnComingBackOnline() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.play([song("s1")], startAt: 0)
        #expect(await eventually(0.3) { self.transport.lyricsReads("s1") > 0 } == false)
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually { self.transport.lyricsReads("s1") == 1 }, "asked once back online")
    }

    /// I2: the pane's read goes through `request`: after the network changed (home address gone), a failed background
    /// read is tried again by the pane on the address that answers.
    @Test func pane_readFailsOverAfterANetworkChange() async throws {
        let away = URL(string: "https://music.example.com/navidrome")!
        let model = try await model(urls: [home, away])
        defer { model.signOut() }
        #expect(await model.lyricsQuietlyAdvertised())
        transport.setDown(hosts: ["192.168.1.2"])
        // The background ask's read, without playing (playback's own requests would fail over first).
        _ = await model.startLyricsRead("s1", quiet: true).value
        #expect(transport.lyricsReads("s1") == 1 && model.lyricsKeeper.readsInFlight == 0, "the quiet background read failed")
        #expect(model.lyricsKeeper.library("s1") == nil)
        let shown = try await model.lyricsForPane(song("s1"))
        #expect(shown?.source == .library, "the pane's read failed over")
        #expect(transport.sent.contains { self.transport.lyricsRead($0) == "s1" && $0.url?.host == "music.example.com" })
        transport.setDown(hosts: [])
    }

    /// Fix round 2 (N1, and the I2 gap): the pane waits for a quiet read still in flight; when it fails, the pane tries
    /// once more through `request`, and the slot the quiet read held goes to the song waiting for one.
    @Test func pane_retriesAFailedQuietReadAndFreesItsSlot() async throws {
        let model = try await model()
        defer { model.signOut() }
        for id in ["s1", "s2", "s3"] { transport.hold(id) }
        transport.failOnce("s1")
        model.play(["s1", "s2", "s3", "s4"].map(song), startAt: 0)
        for id in ["s1", "s2", "s3"] {
            #expect(await eventually { self.transport.lyricsReads(id) == 1 }, "\(id)")
            model.player.next()
        }
        #expect(await eventually { model.lyricsKeeper.waiting == "s4" })
        let pane = Task { try await model.lyricsForPane(self.song("s1")) }
        #expect(await eventually { self.transport.lyricsReads("s1") == 1 && model.lyricsKeeper.inFlight["s1"]?.quiet == true })
        transport.release("s1")   // the quiet read fails; the pane's retry goes through `request`
        let shown = try await pane.value
        #expect(shown?.source == .library && transport.lyricsReads("s1") == 2, "retried once through request")
        #expect(await eventually { self.transport.lyricsReads("s4") == 1 }, "the freed slot went to the waiting song")
        for id in ["s2", "s3"] { transport.release(id) }
    }

    /// M1: offline with nothing kept, the pane says it's offline.
    @Test func pane_offlineSaysSo() {
        #expect(LyricsContent.emptyTitle(offline: true) == AppModel.offlineCopy)
        #expect(LyricsContent.emptyTitle(offline: false) == "No lyrics for this song")
        #expect(LyricsContent.emptySymbol(offline: true) == "wifi.slash")
    }

    /// M4: LRCLIB's kept lyrics aren't shown once Find lyrics online is off.
    @Test func lrclib_keptOnlineHiddenWhenSwitchedOff() async throws {
        let model = try await model()
        defer { model.signOut() }
        stubLrclib()
        model.lyricsKeeper.findOnline = true
        #expect(try await model.lyricsForPane(song("s2"))?.source == .online)
        model.lyricsKeeper.findOnline = false
        #expect(model.lyricsKeeper.shown("s2") == nil)
        #expect(try await model.lyricsForPane(song("s2")) == nil)
        #expect(transport.lrclibCalls.count == 1)
    }

    /// LL3: an LRCLIB call that doesn't answer is given up after 15 s (shortened here); nothing is kept.
    @Test func lrclib_overallTimeLimit() async throws {
        #expect(LyricsKeeper().onlineDeadline == .seconds(15))
        let model = try await model()
        defer { model.signOut() }
        stubLrclib()
        model.lyricsKeeper.findOnline = true
        model.lyricsKeeper.onlineDeadline = .milliseconds(150)
        transport.hold("lrclib")
        let started = Date()
        #expect(try await model.lyricsForPane(song("s2")) == nil)
        #expect(Date().timeIntervalSince(started) < 5, "given up, not waited out")
        #expect(model.lyricsKeeper.online("s2") == nil, "nothing kept")
        #expect(model.lyricsKeeper.hasAskedOnline("s2"), "a call that timed out still counts: once per song")
        transport.release("lrclib")
    }

    /// LL4: an LRCLIB call the pane gave up on (closed, or another song) is neither kept as none nor counted as asked.
    @Test func lrclib_cancelledCallIsNotKept() async throws {
        let model = try await model()
        defer { model.signOut() }
        stubLrclib()
        model.lyricsKeeper.findOnline = true
        transport.hold("lrclib")
        let pane = Task { try await model.lyricsForPane(self.song("s2")) }
        #expect(await eventually { self.transport.lrclibCalls.count == 1 })
        pane.cancel()
        #expect(await eventually { !model.lyricsKeeper.hasAskedOnline("s2") })
        #expect(model.lyricsKeeper.online("s2") == nil)
        transport.release("lrclib")
        let again = try await model.lyricsForPane(song("s2"))
        #expect(again?.source == .online && transport.lrclibCalls.count == 2, "asked again next time")
    }

    /// Found by the full suite (OfflineAppTests.threeSecondBlipNeitherGoesOfflineNorSkips): the background ask is quiet.
    /// A read that fails during a blip never fails over and never counts towards going offline.
    @Test func trigger_failedBackgroundReadNeverCountsTowardsOffline() async throws {
        let model = try await model()
        defer { model.signOut() }
        transport.setDown(true)
        let before = transport.sent.count
        // The two reads the trigger makes, without playing (playback's own reads would muddy the count).
        #expect(await model.lyricsQuietlyAdvertised() == false)
        let result = await model.startLyricsRead("s1", quiet: true).value
        #expect((try? result.get()) == nil, "the read failed")
        let sent = transport.sent.dropFirst(before)
        #expect(sent.contains { $0.url?.path.hasSuffix("/rest/getOpenSubsonicExtensions") == true })
        #expect(transport.lyricsReads("s1") == 1, "sent once: no failover retry")
        #expect(!model.reachability.isSuspect && model.serverReachable && !model.isOffline)
        transport.setDown(false)
    }

    @Test func trigger_answerFromAnotherSessionIsForgotten() async throws {
        let model = try await model()
        model.play([song("s1")], startAt: 0)
        #expect(await eventually { model.lyricsKeeper.shown("s1") != nil })
        model.signOut()
        #expect(model.lyricsKeeper.shown("s1") == nil && model.lyricsKeeper.entries.isEmpty)
        #expect(!model.lyricsKeeper.hasAskedServer("s1"))
    }

    // MARK: - The pane

    @Test func pane_usesKeptAnswerWithoutARead() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.play([song("s1")], startAt: 0)
        #expect(await eventually { model.lyricsKeeper.shown("s1") != nil })
        let before = transport.sent.count
        let shown = try await model.lyricsForPane(song("s1"))
        guard case .lines(let lyrics, .library)? = shown else { Issue.record("expected the library's lyrics, got \(String(describing: shown))"); return }
        #expect(lyrics.lines.map(\.text) == ["words of s1"])
        #expect(transport.sent.count == before, "no read: the kept answer")
    }

    @Test func pane_keptNoneIsNotAskedAgainButTryAgainIs() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.play([song("s2")], startAt: 0)
        #expect(await eventually { model.lyricsKeeper.library("s2") == .some(nil) })
        #expect(try await model.lyricsForPane(song("s2")) == nil)
        #expect(transport.lyricsReads("s2") == 1, "a none isn't asked again this session")
        withLyrics.withLock { _ = $0.insert("s2") }
        let fresh = try await model.lyricsForPane(song("s2"), fresh: true)
        #expect(fresh?.source == .library && transport.lyricsReads("s2") == 2, "Try again reads afresh")
    }

    // MARK: - D311: Find lyrics online

    @Test func lrclib_offByDefault() async throws {
        let model = try await model()
        defer { model.signOut() }
        stubLrclib()
        #expect(model.lyricsKeeper.findOnline == false)
        #expect(defaults.object(forKey: LyricsKeeper.findOnlineKey) == nil)
        model.play([song("s2")], startAt: 0)
        #expect(try await model.lyricsForPane(song("s2")) == nil)
        #expect(transport.lrclibCalls.isEmpty)
    }

    @Test func lrclib_switchIsThePhones() async throws {
        let model = try await model()
        model.lyricsKeeper.findOnline = true
        #expect(defaults.bool(forKey: LyricsKeeper.findOnlineKey))
        model.signOut()
        #expect(model.lyricsKeeper.findOnline, "sign-out keeps the phone's switch")
        let again = try await self.model()
        defer { again.signOut() }
        #expect(again.lyricsKeeper.findOnline)
    }

    @Test func lrclib_onlyAfterServerNoneOrSixSeconds() async throws {
        #expect(LyricsKeeper().serverWait == .seconds(6) && LyricsKeeper().serverDeadline == .seconds(20))
        let model = try await model()
        defer { model.signOut() }
        stubLrclib()
        model.lyricsKeeper.findOnline = true
        // The server has lyrics: LRCLIB isn't asked.
        let s1 = try await model.lyricsForPane(song("s1"))
        #expect(s1?.source == .library && transport.lrclibCalls.isEmpty)
        // The server has none: LRCLIB is asked, once.
        let s2 = try await model.lyricsForPane(song("s2"))
        guard case .lines(let lyrics, .online)? = s2 else { Issue.record("expected LRCLIB's lyrics, got \(String(describing: s2))"); return }
        #expect(lyrics.lines.map(\.text) == ["found words"] && transport.lrclibCalls.count == 1)
        _ = try await model.lyricsForPane(song("s2"))
        _ = try await model.lyricsForPane(song("s2"), fresh: true)
        #expect(transport.lrclibCalls.count == 1, "once per song per session")
        // The server is slow: LRCLIB once the wait has passed (6 s, shortened here), while the read is still out.
        model.lyricsKeeper.serverWait = .milliseconds(100)
        transport.hold("s3")
        let s3 = try await model.lyricsForPane(song("s3"))
        #expect(s3?.source == .online && transport.lrclibCalls.count == 2)
        #expect(transport.lyricsReads("s3") == 1)
        transport.release("s3")
    }

    @Test func lrclib_serverReadContinuesInBackground() async throws {
        let model = try await model()
        defer { model.signOut() }
        stubLrclib()
        model.lyricsKeeper.findOnline = true
        model.lyricsKeeper.serverWait = .milliseconds(100)
        withLyrics.withLock { _ = $0.insert("s3") }
        transport.hold("s3")
        let first = try await model.lyricsForPane(song("s3"))
        #expect(first?.source == .online, "LRCLIB's while the server is slow")
        transport.release("s3")
        #expect(await eventually { model.lyricsKeeper.library("s3") != nil }, "the server's read went on and was kept")
        #expect(transport.cancelledReads("s3") == 0)
        // D313: next time, the server's.
        let next = try await model.lyricsForPane(song("s3"))
        #expect(next?.source == .library)
        #expect(transport.lyricsReads("s3") == 1 && transport.lrclibCalls.count == 1)
    }

    @Test func lrclib_sendsOnlyTheSongsWords() async throws {
        let model = try await model()
        defer { model.signOut() }
        stubLrclib(status: 404)
        model.lyricsKeeper.findOnline = true
        #expect(try await model.lyricsForPane(Song(id: "s9", title: "Wide Open", artist: "Aurora Field", album: "First Light",
                                                   duration: 240)) == nil)
        let call = try #require(transport.lrclibCalls.first)
        #expect(call.url?.scheme == "https" && call.url?.path == "/api/get" && call.httpMethod == "GET")
        #expect(transport.query(call) == ["track_name": "Wide Open", "artist_name": "Aurora Field", "album_name": "First Light",
                                          "duration": "240"])
        #expect(call.value(forHTTPHeaderField: "User-Agent") == "Magpie/\(AppModel.marketingVersion)")
        #expect(Set((call.allHTTPHeaderFields ?? [:]).keys) == ["User-Agent", "Accept-Language"])
        let text = call.url?.absoluteString ?? ""
        for leak in ["192.168.1.2", "jordan", "tok", "jwt", "salt"] { #expect(!text.contains(leak), "\(leak)") }
    }

    @Test func lrclib_instrumentalNote() async throws {
        let model = try await model()
        defer { model.signOut() }
        stubLrclib(body: Data(#"{"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#.utf8))
        model.lyricsKeeper.findOnline = true
        let shown = try await model.lyricsForPane(song("s2"))
        #expect(shown == .instrumental(.online))
        #expect(ShownLyrics.instrumentalNote == "No lyrics: it\u{2019}s an instrumental.")
    }

    @Test func lrclib_offlineAsksNothing() async throws {
        let model = try await model()
        defer { model.signOut() }
        stubLrclib()
        model.lyricsKeeper.findOnline = true
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(try await model.lyricsForPane(song("s2")) == nil)
        #expect(transport.lrclibCalls.isEmpty)
    }

    // MARK: - D313, D314

    @Test func footer_libraryVsOnline() {
        let words = Lyrics(synced: false, lines: [LyricLine(text: "a")])
        #expect(ShownLyrics.lines(words, .library).footer == "Lyrics from your library")
        #expect(ShownLyrics.lines(words, .online).footer == "Lyrics found online")
        #expect(ShownLyrics.instrumental(.online).footer == "Lyrics found online")
        #expect(PlaybackSettingsView.findOnlineFooter == "When your library has no lyrics for a song, Magpie looks them up on LRCLIB, a free lyrics site. It sends only the song\u{2019}s title, artist, album and length.")
    }

    @Test func lyricsButton_showsWithSwitchWithoutSongLyrics() async throws {
        let model = try await model(songLyrics: false)
        defer { model.signOut() }
        #expect(await model.lyricsButtonAvailable() == false, "today's: no songLyrics, switch off, no button")
        model.lyricsKeeper.findOnline = true
        #expect(await model.lyricsButtonAvailable())
        // Without songLyrics the pane goes straight to LRCLIB (no lyrics read the server can't answer).
        stubLrclib()
        let shown = try await model.lyricsForPane(song("s1"))
        #expect(shown?.source == .online && transport.lyricsReads("s1") == 0)
    }

    @Test func fourSetups() async throws {
        for (lidarr, aurral) in [(false, false), (true, false), (false, true), (true, true)] {
            let model = try await model(lidarr: lidarr, aurral: aurral)
            let id = "s1-\(lidarr)-\(aurral)"
            withLyrics.withLock { _ = $0.insert(id) }
            #expect(await model.lyricsButtonAvailable(), "lidarr \(lidarr), aurral \(aurral)")
            model.play([song(id)], startAt: 0)
            #expect(await eventually { model.lyricsKeeper.shown(id)?.source == .library }, "lidarr \(lidarr), aurral \(aurral)")
            #expect(transport.lyricsReads(id) == 1 && transport.lrclibCalls.isEmpty)
            model.signOut()
        }
        #expect(!transport.sent.contains { $0.url?.port == 8686 && $0.url?.path.contains("lyric") == true })
    }
}
