import Foundation
import MagpieCore
import MagpieTestSupport
import ListenBrainzKit
import NavidromeKit
import os
import Playback
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func prefs(navidrome: Bool = true, listenBrainz: Bool) -> ScrobblePreferences {
    var p = ScrobblePreferences.defaultValue
    p.viaNavidrome = navidrome; p.viaListenBrainz = listenBrainz
    return p
}
private let bothOn = prefs(listenBrainz: true)

@MainActor private func song(_ id: String) -> Song { PlayerTests.song(id) }

private func queryValue(_ r: URLRequest, _ name: String) -> String? {
    r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
}

/// Holds requests whose path ends with `pathSuffix` until `release()` (counting those that arrived), then passes
/// everything to `inner`.
private final class GateTransport: HTTPTransport {
    private struct Gate { var pathSuffix: String?; var arrived = 0; var waiting: [CheckedContinuation<Void, Never>] = [] }
    let inner: MockTransport
    private let gate = OSAllocatedUnfairLock(initialState: Gate())
    init(_ inner: MockTransport) { self.inner = inner }

    func hold(_ pathSuffix: String) { gate.withLock { $0.pathSuffix = pathSuffix } }
    var arrived: Int { gate.withLock { $0.arrived } }
    func release() {
        let waiting = gate.withLock { g in
            defer { g.pathSuffix = nil; g.waiting = [] }
            return g.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let held = gate.withLock { g -> Bool in
                guard let suffix = g.pathSuffix, path.hasSuffix(suffix) else { return false }
                g.arrived += 1
                g.waiting.append(c)
                return true
            }
            if !held { c.resume() }
        }
        return try await inner.send(request)
    }
}

/// The router over a mock transport: Navidrome's stubs answer `ndStatus`, submit-listens answers `lbStatus`.
private final class RouterRig: Sendable {
    private struct Statuses {
        var nd = 200, lb = 200, lbOKBeforeFailure: Int?
        /// Listens with these track names make a submit-listens answer 400.
        var lbRefused: Set<String> = []
        /// Songs whose scrobble Navidrome answers with this Subsonic error code.
        var ndErrors: [String: Int] = [:]
    }
    private let statuses = OSAllocatedUnfairLock(initialState: Statuses())
    let t = MockTransport()
    let gate: GateTransport
    let box = ClientBox()
    let counting = PlayCounting(on: true)
    let finds = FindsIdentity()
    let settings: ScrobbleSettings
    let queueURL = FileManager.default.temporaryDirectory.appending(path: "ScrobbleRouterTests-\(UUID())/scrobble-queue.json")
    let queue: ScrobbleQueue
    let tokens = MemoryTokenStore("tok-secret")
    let offline = OfflineBox(false)
    let router: ScrobbleRouter

    var ndStatus: Int {
        get { statuses.withLock { $0.nd } }
        set { statuses.withLock { $0.nd = newValue } }
    }
    var lbStatus: Int {
        get { statuses.withLock { $0.lb } }
        set { statuses.withLock { $0.lb = newValue } }
    }

    func refuseLB(_ trackName: String) { statuses.withLock { _ = $0.lbRefused.insert(trackName) } }
    func failND(_ songId: String, code: Int) { statuses.withLock { $0.ndErrors[songId] = code } }

    init(prefs: ScrobblePreferences, retryInterval: Duration = .seconds(300)) {
        gate = GateTransport(t)
        settings = ScrobbleSettings(prefs)
        queue = ScrobbleQueue(fileURL: queueURL)
        let statuses = self.statuses
        let nd: @Sendable (Data) -> @Sendable (URLRequest) -> MockTransport.Response = { body in
            { _ in MockTransport.Response(status: statuses.withLock { $0.nd }, body: body) }
        }
        t.stub(pathSuffix: "/rest/ping", handler: nd(ok))
        t.stub(method: "POST", pathSuffix: "/auth/login", handler: nd(loginJSON))
        t.stub(pathSuffix: "/rest/scrobble") { r in
            if let code = statuses.withLock({ s in queryValue(r, "id").flatMap { s.ndErrors[$0] } }) {
                let failed = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":"# + "\(code)"
                    + #","message":"no"}}}"#
                return MockTransport.Response(status: 200, body: Data(failed.utf8))
            }
            return nd(ok)(r)
        }
        t.stub(method: "POST", pathSuffix: "/1/submit-listens") { r in
            let names = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
                .flatMap { $0["payload"] as? [[String: Any]] }?
                .compactMap { ($0["track_metadata"] as? [String: Any])?["track_name"] as? String } ?? []
            let status = statuses.withLock { s -> Int in
                if !s.lbRefused.isDisjoint(with: names) { return 400 }
                if let left = s.lbOKBeforeFailure {
                    if left == 0 { s.lbOKBeforeFailure = nil; return 500 }
                    if (200..<300).contains(s.lb) { s.lbOKBeforeFailure = left - 1 }
                }
                return s.lb
            }
            return MockTransport.Response(status: status, body: Data(#"{"status":"ok"}"#.utf8))
        }
        box.set(NavidromeClient(endpoint: ServerEndpoint(bases: [home]),
                                credentials: NavidromeCredentials(username: "a", password: "b"), transport: gate))
        let gate = self.gate, tokens = self.tokens, offline = self.offline
        router = ScrobbleRouter(box: box, counting: counting, findsIdentity: finds, settings: settings, queue: queue,
                                listenBrainz: { tokens.load().map { ListenBrainzClient(transport: gate, token: $0, clientVersion: "test") } },
                                isOffline: { offline.isOffline }, retryInterval: retryInterval)
    }

    /// Once `chunks` submit-listens requests have succeeded, the next one answers 500 (then this resets).
    func failLBAfter(chunks: Int) { statuses.withLock { $0.lbOKBeforeFailure = chunks } }

    /// How many plays are queued for Navidrome and for ListenBrainz.
    func queued() async -> (nd: Int, lb: Int) {
        (await queue.pending(.navidrome).count, await queue.pending(.listenBrainz).count)
    }

    var allScrobbles: [URLRequest] { t.requests.filter { $0.url?.path.hasSuffix("/rest/scrobble") == true } }

    func scrobbles(submission: Bool) -> [URLRequest] {
        t.requests.filter { $0.url?.path.hasSuffix("/rest/scrobble") == true && queryValue($0, "submission") == String(submission) }
    }

    var lbPayloads: [(type: String, count: Int, firstListenedAt: Int?)] {
        t.requests.filter { $0.url?.path.hasSuffix("/1/submit-listens") == true }.compactMap { r in
            guard let body = r.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let type = json["listen_type"] as? String, let payload = json["payload"] as? [[String: Any]] else { return nil }
            return (type, payload.count, payload.first?["listened_at"] as? Int)
        }
    }
}

@MainActor @Suite(.serialized) struct ScrobbleRouterTests {
    @Test func bothDestinationsGetSubmission() async throws {
        let r = RouterRig(prefs: bothOn)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        let nd = try #require(r.scrobbles(submission: true).first)
        #expect(queryValue(nd, "id") == "s1" && queryValue(nd, "time") == "1700000000000")
        #expect(r.lbPayloads.map(\.type) == ["single"] && r.lbPayloads[0].firstListenedAt == 1_700_000_000)
        let q = await r.queued()
        #expect(q.nd == 0 && q.lb == 0)
    }

    @Test func listenBrainzOffByDefault() async throws {
        let r = RouterRig(prefs: .defaultValue)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(r.scrobbles(submission: true).count == 1 && r.lbPayloads.isEmpty)
    }

    @Test func navidromeOffSendsOnlyToListenBrainz() async throws {
        let r = RouterRig(prefs: prefs(navidrome: false, listenBrainz: true))
        try await r.router.scrobble(song("s1"), submission: false, at: nil)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(r.allScrobbles.isEmpty)
        #expect(r.lbPayloads.map(\.type) == ["playing_now", "single"])
    }

    @Test func listenBrainzNeedsAToken() async throws {
        let r = RouterRig(prefs: bothOn); r.tokens.clear()
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        let q = await r.queued()
        #expect(r.lbPayloads.isEmpty && q.lb == 0)
        #expect(r.scrobbles(submission: true).count == 1)
    }

    @Test func findNeverSentEitherPath() async throws {      // D29
        let r = RouterRig(prefs: bothOn)
        r.finds.markLanded("s1")
        try await r.router.scrobble(song("s1"), submission: false, at: nil)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(r.scrobbles(submission: false).isEmpty && r.scrobbles(submission: true).isEmpty && r.lbPayloads.isEmpty)
        let q = await r.queued()
        #expect(q.nd == 0 && q.lb == 0)
    }

    @Test func failedSendIsQueuedAndRetried() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        let q = await r.queued()
        #expect(q.lb == 1 && q.nd == 0)
        r.lbStatus = 200
        await r.router.drain()
        #expect(r.lbPayloads.last?.type == "import" && r.lbPayloads.last?.count == 1 && r.lbPayloads.last?.firstListenedAt == 1_700_000_000)
        #expect(await r.queue.pending(.listenBrainz).isEmpty)
    }

    /// T16 review: a permanent refusal (400) isn't queued: the same listen would be refused again.
    @Test func permanentRefusalIsNotQueued() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 400
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(r.lbPayloads.map(\.type) == ["single"])
        #expect(await r.queue.pending(.listenBrainz).isEmpty)
    }

    /// T16 review: 429 is retried later.
    @Test func rateLimitedIsQueued() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 429
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(await r.queue.pending(.listenBrainz).count == 1)
    }

    @Test func navidromeQueuedOfflineCarriesOriginalTime() async throws {
        let r = RouterRig(prefs: .defaultValue); r.offline.set(true)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        let q = await r.queued()
        #expect(r.scrobbles(submission: true).isEmpty && q.nd == 1)
        r.offline.set(false); await r.router.drain()
        #expect(r.scrobbles(submission: true).map { queryValue($0, "time") } == ["1700000000000"])
        #expect(await r.queue.pending(.navidrome).isEmpty)
    }

    /// Offline (forced On included) nothing is sent: plays queue, now playing is skipped, and a drain waits.
    @Test func offlineSendsNothingAtAll() async throws {
        let r = RouterRig(prefs: bothOn); r.offline.set(true)
        try await r.router.scrobble(song("s1"), submission: false, at: nil)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        await r.router.drain()
        #expect(r.t.requests.isEmpty)
        let q = await r.queued()
        #expect(q.nd == 1 && q.lb == 1)
    }

    @Test func findDroppedOnDequeue() async throws {
        let r = RouterRig(prefs: .defaultValue); r.offline.set(true)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        r.finds.markLanded("s1"); r.offline.set(false)
        await r.router.drain()
        let q = await r.queued()
        #expect(r.scrobbles(submission: true).isEmpty && q.nd == 0)
    }

    /// D29 on dequeue, the ListenBrainz path.
    @Test func findDroppedOnDequeueListenBrainz() async throws {
        let r = RouterRig(prefs: bothOn); r.offline.set(true)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        try await r.router.scrobble(song("s2"), submission: true, at: t0 + 1)
        r.finds.markLanded("s1"); r.offline.set(false)
        await r.router.drain()
        #expect(r.lbPayloads.map(\.type) == ["import"] && r.lbPayloads[0].count == 1 && r.lbPayloads[0].firstListenedAt == 1_700_000_001)
        #expect(r.scrobbles(submission: true).map { queryValue($0, "id") } == ["s2"])
        let q = await r.queued()
        #expect(q.nd == 0 && q.lb == 0)
    }

    /// D29 on dequeue judges a queued play by its library id, as the send did: a main-library song still counts while
    /// the Finds library's songs aren't known (which fails closed for songs without one), and a Finds song never queues.
    @Test func dequeueJudgesByLibraryId() async throws {
        let r = RouterRig(prefs: .defaultValue); r.offline.set(true)
        r.finds.set(libraryId: 2, songIds: nil)
        try await r.router.scrobble(PlayerTests.song("main", libraryId: 1), submission: true, at: t0)
        try await r.router.scrobble(PlayerTests.song("find", libraryId: 2), submission: true, at: t0)
        #expect(await r.queue.pending(.navidrome).map(\.song.songId) == ["main"])
        r.offline.set(false)
        await r.router.drain()
        #expect(r.scrobbles(submission: true).map { queryValue($0, "id") } == ["main"])
    }

    @Test func drainChunksBy100AndRemovesEachChunk() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500
        for i in 0..<250 { try await r.router.scrobble(song("s\(i)"), submission: true, at: t0 + Double(i)) }
        #expect(await r.queue.pending(.listenBrainz).count == 250)
        r.lbStatus = 200; r.failLBAfter(chunks: 1)   // the second import chunk answers 500
        await r.router.drain()
        #expect(r.lbPayloads.filter { $0.type == "import" }.map(\.count) == [100, 100])
        let left = await r.queue.pending(.listenBrainz)
        #expect(left.count == 150 && left.first?.song.songId == "s100", "first chunk removed, the rest kept")
        r.lbStatus = 200; await r.router.drain()
        #expect(r.lbPayloads.filter { $0.type == "import" }.map(\.count) == [100, 100, 100, 50])
        #expect(await r.queue.pending(.listenBrainz).isEmpty)
    }

    @Test func unauthorizedStopsListenBrainzDrainAndKeepsQueue() async throws {   // edge test
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500; r.offline.set(true)
        for i in 0..<3 { try await r.router.scrobble(song("s\(i)"), submission: true, at: t0) }
        r.offline.set(false); r.lbStatus = 401
        let before = r.lbPayloads.count
        await r.router.drain()
        #expect(r.lbPayloads.count - before == 1)
        #expect(await r.queue.pending(.listenBrainz).count == 3)
        #expect(await r.queue.pending(.navidrome).isEmpty, "Navidrome drained in the same call")
    }

    /// T16 review: after a 401 nothing more goes to ListenBrainz (plays queue) until a token is saved again.
    @Test func rejectedTokenStopsSendingUntilReplaced() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 401
        let rejected = OSAllocatedUnfairLock(initialState: 0)
        r.router.setOnListenBrainzRejected { rejected.withLock { $0 += 1 } }
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(r.router.listenBrainzRejected && rejected.withLock { $0 } == 1)
        try await r.router.scrobble(song("s2"), submission: false, at: nil)
        try await r.router.scrobble(song("s2"), submission: true, at: t0 + 1)
        await r.router.drain()
        #expect(r.lbPayloads.count == 1, "only the first send")
        #expect(await r.queue.pending(.listenBrainz).count == 2)
        r.lbStatus = 200
        r.router.listenBrainzTokenReplaced()
        #expect(!r.router.listenBrainzRejected)
        await r.router.drain()
        #expect(r.lbPayloads.last?.type == "import" && r.lbPayloads.last?.count == 2)
        #expect(await r.queue.pending(.listenBrainz).isEmpty)
    }

    @Test func countPlaysOffSendsNothing() async throws {
        let r = RouterRig(prefs: bothOn); r.counting.set(false)
        try await r.router.scrobble(song("s1"), submission: false, at: nil)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(r.allScrobbles.isEmpty && r.lbPayloads.isEmpty)
        #expect(await r.queue.pending(.navidrome).isEmpty)
    }

    /// Moved from TryAndSettingsTests (the old Navidrome scrobbler): turned on again, the next play counts.
    @Test func countPlaysBackOnCountsAgain() async throws {
        let r = RouterRig(prefs: .defaultValue); r.counting.set(false)
        try await r.router.scrobble(song("s1"), submission: true, at: nil)
        #expect(r.scrobbles(submission: true).isEmpty)
        r.counting.set(true)
        try await r.router.scrobble(song("s1"), submission: true, at: nil)
        #expect(r.scrobbles(submission: true).count == 1)
    }

    @Test func nowPlayingNeverQueued() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500; r.ndStatus = 500
        try await r.router.scrobble(song("s1"), submission: false, at: nil)
        #expect(r.lbPayloads.map(\.type) == ["playing_now"])
        let q = await r.queued()
        #expect(q.nd == 0 && q.lb == 0)
    }

    @Test func clearQueueEmptiesBoth() async throws {
        let r = RouterRig(prefs: bothOn); r.offline.set(true)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        r.router.clearQueue()
        #expect(await eventually { let q = await r.queued(); return q.nd == 0 && q.lb == 0 })
    }

    /// Settings' Scrobbling row (T21b: one row with a summary) and the page's fixed copy.
    @Test func settingsSummaryAndCopy() {
        #expect(AppModel.scrobblingSummary(.defaultValue, countPlays: true, hasToken: true) == "Navidrome · 50% or 4 min")
        #expect(AppModel.scrobblingSummary(bothOn, countPlays: true, hasToken: true) == "Navidrome + ListenBrainz · 50% or 4 min")
        #expect(AppModel.scrobblingSummary(bothOn, countPlays: true, hasToken: false) == "Navidrome · 50% or 4 min")
        var never = bothOn; never.rule = ScrobbleRule(percent: 70, minutes: nil)
        #expect(AppModel.scrobblingSummary(never, countPlays: true, hasToken: true) == "Navidrome + ListenBrainz · 70%")
        #expect(AppModel.scrobblingSummary(bothOn, countPlays: false, hasToken: true) == "Off")
        #expect(ScrobblingSettingsView.doubleCountNote == "If your Navidrome also sends plays to ListenBrainz, they'll be counted twice.")
        #expect(ScrobblingSettingsView.needsTokenFooter == "Add your ListenBrainz token below to send plays there directly.")
    }

    /// Fix round 1, minors 7 and 8: the footer's display logic, and the ListenBrainz switch without a token.
    @Test func destinationsFooterAndSwitch() {
        let navidromeOnly = prefs(listenBrainz: false), lbOnly = prefs(navidrome: false, listenBrainz: true)
        #expect(ScrobblingSettingsView.destinationsFooter(bothOn, hasToken: true) == ScrobblingSettingsView.doubleCountNote)
        #expect(ScrobblingSettingsView.destinationsFooter(navidromeOnly, hasToken: true) == nil)
        #expect(ScrobblingSettingsView.destinationsFooter(lbOnly, hasToken: true) == nil)
        #expect(ScrobblingSettingsView.destinationsFooter(bothOn, hasToken: false) == ScrobblingSettingsView.needsTokenFooter)
        #expect(ScrobblingSettingsView.listenBrainzShowsOn(bothOn, hasToken: true))
        #expect(!ScrobblingSettingsView.listenBrainzShowsOn(bothOn, hasToken: false), "no token: Off")
        #expect(!ScrobblingSettingsView.listenBrainzShowsOn(navidromeOnly, hasToken: true))
    }

    // MARK: - Fix round 1

    /// Ruling (a): a chunk refused as a whole (400) goes again one listen at a time; only the refused one is dropped.
    @Test func permanentChunkRefusalResendsOneByOne() async throws {
        let r = RouterRig(prefs: bothOn); r.offline.set(true)
        for i in 0..<3 { try await r.router.scrobble(song("s\(i)"), submission: true, at: t0 + Double(i)) }
        r.refuseLB("Ts1"); r.offline.set(false)
        await r.router.drain()
        #expect(r.lbPayloads.filter { $0.type == "import" }.map(\.count) == [3, 1, 1, 1])
        #expect(r.lbPayloads.suffix(3).map(\.firstListenedAt) == [1_700_000_000, 1_700_000_001, 1_700_000_002])
        #expect(await r.queue.pending(.listenBrainz).isEmpty, "s0 and s2 taken, s1 dropped")
    }

    /// Ruling (a): a failure that may pass during the one-by-one keeps what wasn't sent.
    @Test func oneByOneStopsOnRetryableFailure() async throws {
        let r = RouterRig(prefs: prefs(navidrome: false, listenBrainz: true)); r.offline.set(true)
        for i in 0..<3 { try await r.router.scrobble(song("s\(i)"), submission: true, at: t0 + Double(i)) }
        // The chunk and s0 are refused (400, checked first); the next request (s1) answers 500.
        r.refuseLB("Ts0"); r.failLBAfter(chunks: 0); r.offline.set(false)
        await r.router.drain()
        let left = await r.queue.pending(.listenBrainz).map(\.song.songId)
        #expect(left == ["s1", "s2"], "s0 dropped as refused, the 500 on s1 stops: \(left)")
    }

    /// Ruling (b): while anything is queued it is tried again on a timer, without anyone asking.
    @Test func retryTimerDrainsTheQueue() async throws {
        let r = RouterRig(prefs: bothOn, retryInterval: .milliseconds(50)); r.lbStatus = 500
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(await r.queue.pending(.listenBrainz).count == 1)
        r.lbStatus = 200
        #expect(await eventually { await r.queue.pending(.listenBrainz).isEmpty })
        #expect(r.lbPayloads.last?.type == "import")
    }

    /// Ruling (b): the timer sends nothing offline, and keeps trying until back online.
    @Test func retryTimerWaitsWhileOffline() async throws {
        let r = RouterRig(prefs: .defaultValue, retryInterval: .milliseconds(30)); r.offline.set(true)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        try await Task.sleep(for: .milliseconds(150))
        let q = await r.queued()
        #expect(r.allScrobbles.isEmpty && q.nd == 1)
        r.offline.set(false)
        #expect(await eventually { await r.queue.pending(.navidrome).isEmpty })
    }

    /// Minor 4: a Subsonic error other than auth drops that play and the rest go on; an auth error stops.
    @Test func navidromeDrainDropsRefusedPlayAndGoesOn() async throws {
        let r = RouterRig(prefs: .defaultValue); r.offline.set(true)
        for i in 0..<3 { try await r.router.scrobble(song("s\(i)"), submission: true, at: t0) }
        r.failND("s1", code: 10); r.offline.set(false)
        await r.router.drain()
        #expect(r.scrobbles(submission: true).map { queryValue($0, "id") } == ["s0", "s1", "s2"])
        #expect(await r.queue.pending(.navidrome).isEmpty)
    }

    @Test func navidromeAuthErrorStopsTheDrain() async throws {
        let r = RouterRig(prefs: .defaultValue); r.offline.set(true)
        for i in 0..<3 { try await r.router.scrobble(song("s\(i)"), submission: true, at: t0) }
        r.failND("s1", code: 41); r.offline.set(false)
        await r.router.drain()
        #expect(r.scrobbles(submission: true).map { queryValue($0, "id") } == ["s0", "s1"])
        #expect(await r.queue.pending(.navidrome).map(\.song.songId) == ["s1", "s2"])
    }

    /// Minor 2: a song that became a find while the drain was under way isn't sent.
    @Test func findCheckedJustBeforeEachSend() async throws {
        let r = RouterRig(prefs: .defaultValue); r.offline.set(true)
        for i in 0..<2 { try await r.router.scrobble(song("s\(i)"), submission: true, at: t0) }
        r.offline.set(false); r.gate.hold("/rest/scrobble")
        let drain = Task { await r.router.drain() }
        #expect(await eventually { r.gate.arrived == 1 })
        r.finds.markLanded("s1")
        r.gate.release()
        await drain.value
        #expect(r.scrobbles(submission: true).map { queryValue($0, "id") } == ["s0"])
        #expect(await r.queue.pending(.navidrome).isEmpty)
    }

    /// Minor 3: a 401 answering a token that has been replaced since doesn't mark the new one rejected.
    @Test func staleRejectionIsIgnored() {
        let r = RouterRig(prefs: bothOn)
        let old = r.router.tokenGeneration
        r.router.listenBrainzTokenReplaced()
        r.router.tokenRejected(generation: old)
        #expect(!r.router.listenBrainzRejected)
        r.router.tokenRejected(generation: r.router.tokenGeneration)
        #expect(r.router.listenBrainzRejected)
    }

    /// Minor 7: a play whose send was under way when the queue was cleared (sign-out) isn't queued afterwards.
    @Test func playDuringClearIsNotQueued() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500
        await r.queue.enqueue(QueuedScrobble(destination: .listenBrainz, song: song("old"), listenedAt: t0))
        r.gate.hold("/1/submit-listens")
        let play = Task { try await r.router.scrobble(song("s1"), submission: true, at: t0) }
        #expect(await eventually { r.gate.arrived == 1 })
        r.router.clearQueue()
        #expect(await eventually { await r.queue.pending(.listenBrainz).isEmpty }, "the clear ran")
        r.gate.release()
        try await play.value
        #expect(r.lbPayloads.map(\.type) == ["single"], "it was sent, and failed")
        let q = await r.queue.pending(.listenBrainz)
        #expect(q.isEmpty, "the failed play wasn't queued after the clear")
        #expect(!FileManager.default.fileExists(atPath: r.queueURL.path))
    }

    @Test func queueFileLacksToken() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        let text = try String(contentsOf: r.queueURL, encoding: .utf8)
        #expect(!text.contains("tok-secret") && text.contains("s1"))
    }
}

/// The router as the app builds it.
@MainActor @Suite(.serialized) final class ScrobbleRouterAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "ScrobbleRouterAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "ScrobbleRouterAppTests.\(UUID().uuidString)")!
    let tokens = MemoryTokenStore()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedInModel(fetcher: FakeFetcher, scrobbleStatus: Int = 200) async throws -> AppModel {
        let transport = HostSwitchTransport()
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/rest/scrobble", status: scrobbleStatus, body: ok)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: tokens,
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: fetcher)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        return model
    }

    @Test func signOutClearsQueue() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.offlineMode = .on }
        try await model.scrobbles.scrobble(song("s1"), submission: true, at: t0)
        #expect(await model.scrobbles.queue.pending(.navidrome).count == 1)
        #expect(FileManager.default.fileExists(atPath: ScrobbleQueue.defaultURL(in: tmp).path), "Application Support/Magpie")
        model.signOut()
        #expect(await eventually { await model.scrobbles.queue.pending(.navidrome).isEmpty })
        #expect(await eventually { !FileManager.default.fileExists(atPath: ScrobbleQueue.defaultURL(in: self.tmp).path) },
                "the file goes too")
    }

    /// Ruling (b): turning Count plays back on sends what was queued.
    @Test func countPlaysOnDrains() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.offlineMode = .on }
        try await model.scrobbles.scrobble(song("s1"), submission: true, at: t0)
        model.setCountPlays(false)
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await model.scrobbles.queue.pending(.navidrome).count == 1, "Count plays off: nothing sent")
        model.setCountPlays(true)
        #expect(await eventually { await model.scrobbles.queue.pending(.navidrome).isEmpty })
        model.signOut()
    }

    /// Minor 6: the queue belongs to one account; signing in to another (over a session) clears it first.
    @Test func anotherAccountsQueueIsCleared() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher(), scrobbleStatus: 500)
        try await model.scrobbles.scrobble(song("s1"), submission: true, at: t0)
        #expect(await model.scrobbles.queue.pending(.navidrome).count == 1)
        try await model.signIn(urls: [home], username: "other", password: "pw")
        #expect(await eventually { await model.scrobbles.queue.pending(.navidrome).isEmpty })
        try await model.scrobbles.scrobble(song("s2"), submission: true, at: t0)
        try await model.signIn(urls: [home], username: "other", password: "pw")   // the same account: kept
        try await Task.sleep(for: .milliseconds(100))
        #expect(await model.scrobbles.queue.pending(.navidrome).map(\.song.songId) == ["s2"])
        model.signOut()
    }

    /// Back online (forced On turned off), the queued play goes with its original time.
    @Test func leavingOfflineDrainsTheQueue() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.offlineMode = .on }
        try await model.scrobbles.scrobble(song("s1"), submission: true, at: t0)
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually { await model.scrobbles.queue.pending(.navidrome).isEmpty })
        let inner = try #require((model.transport as? HostSwitchTransport)?.inner)
        let sent = inner.requests.filter { $0.url?.path.hasSuffix("/rest/scrobble") == true }
        #expect(sent.map { queryValue($0, "time") } == ["1700000000000"])
        model.signOut()
    }

    /// A 401 from ListenBrainz shows in Settings › Scrobbling until a token is saved again.
    @Test func rejectedTokenSurfacesUntilSavedAgain() async throws {
        try tokens.save("old")
        let model = try await signedInModel(fetcher: FakeFetcher())
        let inner = try #require((model.transport as? HostSwitchTransport)?.inner)
        inner.stub(method: "POST", pathSuffix: "/1/submit-listens", status: 401)
        model.updatePreferences { $0.scrobbling.viaListenBrainz = true }
        try await model.scrobbles.scrobble(song("s1"), submission: true, at: t0)
        #expect(await eventually { model.listenBrainzRejected })
        try model.setListenBrainzToken("new")
        #expect(!model.listenBrainzRejected && !model.scrobbles.listenBrainzRejected)
        model.signOut()
    }
}
