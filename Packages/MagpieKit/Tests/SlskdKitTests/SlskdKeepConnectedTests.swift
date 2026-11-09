import Foundation
import os
import Testing
import MagpieCore
import MagpieTestSupport
@testable import SlskdKit

/// Round 24 (owner, 2026-11-08): "Keep Soulseek connected". Magpie reads slskd's server state (`GET /api/v0/server`)
/// and, only when slskd says it is disconnected and not already connecting, asks it once to reconnect (`PUT
/// /api/v0/server`, no body) through `SlskdWriteGate`, only while the owner's switch is on in the record saved first,
/// for the saved address and key, never twice within 60 s. It never disconnects slskd. The owner is told only after three
/// failed checks spanning at least ten minutes, once per outage; a check that can't be read is not a failure.
/// (D217, D218, D219)
@Suite struct SlskdKeepConnectedTests {
    static let base = URL(string: "https://nas.local/slskd")!

    /// A clock the test moves by hand (no sleeps).
    final class Clock: Sendable {
        private let time = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { time.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    /// An outage the expectations can record into (`#expect` can't call a mutating method).
    final class Tracker {
        var outage = SlskdOutage()
        func record(_ check: SlskdCheck, at date: Date) -> Bool { outage.record(check, at: date) }
    }

    struct Env {
        let slskd = FakeSlskd()
        let suite = "magpie-slskd-keep-\(UUID().uuidString)"
        let clock = Clock()
        let client: SlskdClient
        let gate: SlskdWriteGate

        init(keep: Bool = true, base: URL = SlskdKeepConnectedTests.base) async {
            client = SlskdClient(base: base, apiKey: "test-slskd-key", transport: slskd)
            let clock = self.clock
            gate = SlskdWriteGate(client: client, defaultsSuite: suite, now: { clock.now })
            if keep { await gate.setKeepConnected(true) }
        }

        func check() async -> SlskdCheck { await SlskdKeepConnected.check(client: client, gate: gate) }
        var connects: [URLRequest] { slskd.requests.filter { $0.httpMethod == "PUT" } }
    }

    // MARK: - Routes

    @Test func route_serverState_exactPath() throws {
        #expect(SlskdRoute.serverState.url(base: Self.base)?.absoluteString == "https://nas.local/slskd/api/v0/server")
        #expect(SlskdRoute.serverState.method == "GET")
        #expect(SlskdRoute.serverState.query.isEmpty)
    }

    @Test func route_connect_isPUTNoBody() async throws {
        #expect(SlskdRoute.connect.url(base: Self.base)?.absoluteString == "https://nas.local/slskd/api/v0/server")
        #expect(SlskdRoute.connect.method == "PUT")
        let env = await Env()
        env.slskd.with { $0.serverConnected = false }
        _ = await env.check()
        let put = try #require(env.connects.first)
        #expect(env.connects.count == 1)
        #expect(put.httpBody == nil && put.httpBodyStream == nil, "no body")
        #expect(put.url?.absoluteString == "https://nas.local/slskd/api/v0/server")
        #expect(put.value(forHTTPHeaderField: "X-API-Key") == "test-slskd-key")
    }

    /// `DELETE /api/v0/server` (disconnect) can't be expressed: no route of the seven names it.
    @Test func route_noDisconnect() {
        let id = UUID()
        let all: [SlskdRoute] = [.downloads, .downloadsFolder("a"), .removeTransfer(username: "a", id: id),
                                 .deleteFile(folder: "a", file: "b"), .deleteFolder("a"), .serverState, .connect]
        #expect(all.count == 7)
        let server = all.filter { $0.url(base: Self.base)?.path.hasSuffix("/api/v0/server") == true }
        #expect(server == [.serverState, .connect])
        #expect(server.map(\.method) == ["GET", "PUT"])
        #expect(!all.contains { $0.method == "DELETE" && $0.segments == ["server"] })
    }

    /// Fix round 2 R1: the channel's reads refuse every write route, and its writes need the gate's pass, which only the
    /// gate's file can make: a write without the gate throws and sends nothing.
    @Test func aWriteRouteWithoutTheGatesPassThrowsAndSendsNothing() async {
        let env = await Env()
        env.slskd.with { $0.serverConnected = false }
        let writes: [SlskdRoute] = [.connect, .deleteFolder("a"), .deleteFile(folder: "a", file: "b"),
                                    .removeTransfer(username: "a", id: UUID())]
        for route in writes {
            await #expect(throws: SlskdError.forbidden) { try await env.client.connection.get(route) }
        }
        #expect(env.slskd.requests.isEmpty, "nothing sent")
    }

    // MARK: - Reading the state

    /// slskd's own camelCase JSON (`ServerState`); missing fields are unknown, never "down".
    @Test func serverStateDecodesLeniently() throws {
        let full = try SlskdServerState.decode(Data(#"""
        {"address":"vps.slsknet.org:2271","state":"Connected, LoggedIn","username":"jordan",
         "isConnected":true,"isLoggedIn":true,"isTransitioning":false}
        """#.utf8))
        #expect(full == SlskdServerState(isConnected: true, isLoggedIn: true, isTransitioning: false, state: "Connected, LoggedIn"))
        #expect(full.condition == .connected)
        let down = try SlskdServerState.decode(Data(#"{"state":"Disconnected","isConnected":false,"isTransitioning":false}"#.utf8))
        #expect(down.condition == .down)
        let connecting = try SlskdServerState.decode(Data(#"{"state":"Connecting","isConnected":false,"isTransitioning":true}"#.utf8))
        #expect(connecting.condition == .transitioning)
        // Only the flags: read from them (and "Disconnected" is not "Connected").
        #expect(try SlskdServerState.decode(Data(#"{"state":"Disconnected"}"#.utf8)).condition == .down)
        #expect(try SlskdServerState.decode(Data(#"{"state":"Connected, LoggingIn"}"#.utf8)).condition == .transitioning)
        // Nothing to go on: unknown, never down.
        #expect(try SlskdServerState.decode(Data("{}".utf8)).condition == .unknown)
        #expect(try SlskdServerState.decode(Data(#"{"isConnected":false}"#.utf8)).condition == .unknown)
        #expect(try SlskdServerState.decode(Data(#"{"isConnected":"no","state":7}"#.utf8)).condition == .unknown)
        #expect(throws: SlskdError.decoding) { try SlskdServerState.decode(Data("[]".utf8)) }
    }

    // MARK: - The gate

    @Test func gate_connect_refusedWhenToggleOff() async throws {
        let env = await Env(keep: false)
        env.slskd.with { $0.serverConnected = false }
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.connect) }
        #expect(env.slskd.requests.isEmpty, "nothing read or sent while it's off")
        #expect(await env.check() == .down(asked: false))
        #expect(env.connects.isEmpty)
        // "Allow Magpie to change Soulseek" is a different switch: it doesn't allow a connect.
        await env.gate.setEnabled(true)
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.connect) }
        #expect(env.connects.isEmpty)
    }

    @Test func gate_connect_refusedForOtherURL() async throws {
        let env = await Env()
        env.slskd.with { $0.serverConnected = false }
        // The same key at another address (sharing the switch's store): its record isn't there.
        let elsewhere = SlskdClient(base: URL(string: "https://music.example/slskd")!, apiKey: "test-slskd-key", transport: env.slskd)
        let other = SlskdWriteGate(client: elsewhere, defaultsSuite: env.suite)
        await #expect(throws: SlskdGateError.self) { try await other.perform(.connect) }
        #expect(await SlskdKeepConnected.check(client: elsewhere, gate: other) == .down(asked: false))
        // A record saved for one address and copied under another's key is refused too.
        let defaults = try #require(UserDefaults(suiteName: env.suite))
        let mine = await env.gate.keepConnectedRecordKey
        defaults.set(defaults.object(forKey: mine), forKey: await other.keepConnectedRecordKey)
        await #expect(throws: SlskdGateError.self) { try await other.perform(.connect) }
        #expect(env.connects.isEmpty)
    }

    @Test func gate_connect_onlyWhenSlskdSaysDownNow() async throws {
        let env = await Env()
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.connect) }   // connected now
        env.slskd.with { $0.down = true }
        await #expect(throws: SlskdGateError.unconfirmed) { try await env.gate.perform(.connect) }
        #expect(env.connects.isEmpty)
    }

    /// M6: the time of the ask is saved before it is sent, so a lost answer (or a relaunch) never sends it again within
    /// 60 s.
    @Test func gate_connect_savedBeforeSentAndNotRepeatedWithinAMinute() async throws {
        let env = await Env()
        env.slskd.with { s in s.serverConnected = false; s.connectReconnects = false }
        try await env.gate.perform(.connect)
        #expect(env.connects.count == 1)
        #expect(await env.gate.lastConnect == env.clock.now)
        env.clock.advance(59)
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.connect) }
        // A new gate for the same slskd (a relaunch) reads the saved time.
        let again = SlskdWriteGate(client: env.client, defaultsSuite: env.suite, now: { env.clock.now })
        await #expect(throws: SlskdGateError.self) { try await again.perform(.connect) }
        #expect(env.connects.count == 1)
        env.clock.advance(1)
        try await again.perform(.connect)
        #expect(env.connects.count == 2)
    }

    @Test func gate_connect_anyTwoHundredIsFine_readOnlyKeyIsSaid() async throws {
        let env = await Env()
        env.slskd.with { s in s.serverConnected = false; s.connectStatus = 202; s.connectReconnects = false }
        try await env.gate.perform(.connect)
        env.clock.advance(61)
        env.slskd.with { $0.connectStatus = 204 }
        try await env.gate.perform(.connect)
        env.clock.advance(61)
        env.slskd.with { $0.connectStatus = 403 }
        await #expect(throws: SlskdError.unauthorized) { try await env.gate.perform(.connect) }
    }

    // MARK: - One check

    @Test func check_connected_sendsNothing() async {
        let env = await Env()
        #expect(await env.check() == .connected)
        #expect(env.slskd.requests.map { $0.httpMethod ?? "GET" } == ["GET"])
        #expect(env.slskd.writes.isEmpty)
    }

    @Test func check_down_sendsOneConnect() async {
        let env = await Env()
        env.slskd.with { s in s.serverConnected = false; s.connectReconnects = false }
        #expect(await env.check() == .down(asked: true))
        #expect(env.connects.count == 1)
        // The next check (30 s later) judges it: still down, and the minute isn't up, so nothing is sent.
        env.clock.advance(30)
        #expect(await env.check() == .down(asked: false))
        #expect(env.connects.count == 1)
        env.clock.advance(30)
        #expect(await env.check() == .down(asked: true))
        #expect(env.connects.count == 2)
        #expect(env.slskd.writes.allSatisfy { $0.httpMethod == "PUT" }, "never a DELETE")
    }

    @Test func check_down_thenReconnected() async {
        let env = await Env()
        env.slskd.with { $0.serverConnected = false }
        #expect(await env.check() == .down(asked: true))
        env.clock.advance(30)
        #expect(await env.check() == .connected)
    }

    @Test func check_transitioning_sendsNothing() async {
        let env = await Env()
        env.slskd.with { s in s.serverConnected = false; s.serverTransitioning = true }
        #expect(await env.check() == .transitioning)
        #expect(env.slskd.writes.isEmpty)
    }

    @Test func check_unreachable_isNotAFailure() async {
        let env = await Env()
        env.slskd.with { $0.down = true }
        #expect(await env.check() == .unreachable)
        #expect(env.slskd.writes.isEmpty)
        let outage = Tracker()
        let clock = env.clock
        for _ in 0..<10 {
            #expect(!outage.record(.unreachable, at: clock.now))
            clock.advance(120)
        }
        #expect(outage.outage == SlskdOutage(), "unreadable checks count for nothing")
    }

    @Test func check_unknownStateSendsNothing() async {
        let env = await Env()
        env.slskd.with { $0.serverJSON = #"{"address":"x"}"# }
        #expect(await env.check() == .unknown)
        #expect(env.slskd.writes.isEmpty)
    }

    @Test func check_readOnlyKey() async {
        let env = await Env()
        env.slskd.with { s in s.serverConnected = false; s.connectStatus = 403 }
        #expect(await env.check() == .keyCannotReconnect)
        // Fix round 1 M3: held until the key changes: no more asks, however long.
        for _ in 0..<5 {
            env.clock.advance(120)
            #expect(await env.check() == .keyCannotReconnect)
        }
        #expect(env.connects.count == 1)
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.connect) }
        // Another key for the same slskd starts afresh.
        let client = SlskdClient(base: Self.base, apiKey: "another-key", transport: env.slskd)
        let other = SlskdWriteGate(client: client, defaultsSuite: env.suite, now: { env.clock.now })
        await other.setKeepConnected(true)
        env.slskd.with { $0.apiKey = "another-key"; $0.connectStatus = 200 }
        #expect(await SlskdKeepConnected.check(client: client, gate: other) == .down(asked: true))
        #expect(env.connects.count == 2)
    }

    /// Fix round 1 M1: a last ask in the future (the clock was set back) counts as made now, never as "never".
    @Test func gate_lastConnectInTheFutureCountsAsNow() async throws {
        let env = await Env()
        env.slskd.with { s in s.serverConnected = false; s.connectReconnects = false }
        let defaults = try #require(UserDefaults(suiteName: env.suite))
        let key = SlskdWriteGate.lastConnectKey(scope: env.client.instanceScope)
        defaults.set(env.clock.now.addingTimeInterval(86_400), forKey: key)
        #expect(await env.check() == .down(asked: false))
        #expect(env.connects.isEmpty)
        #expect(await env.gate.lastConnect == env.clock.now, "reset to now")
        env.clock.advance(59)
        #expect(await env.check() == .down(asked: false))
        env.clock.advance(1)
        #expect(await env.check() == .down(asked: true))
        #expect(env.connects.count == 1)
    }

    /// Fix round 1 M1: an outage that started "in the future" starts again from now.
    @Test func outage_sinceInTheFutureStartsAgain() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let outage = Tracker()
        _ = outage.record(.down(asked: true), at: start.addingTimeInterval(3600))
        _ = outage.record(.down(asked: true), at: start.addingTimeInterval(3660))
        #expect(!outage.record(.down(asked: true), at: start), "the clock went back an hour")
        #expect(outage.outage.failedChecks == 1 && outage.outage.since == start)
        #expect(!outage.record(.down(asked: true), at: start.addingTimeInterval(300)))
        #expect(outage.record(.down(asked: true), at: start.addingTimeInterval(600)))
    }

    // MARK: - The outage

    @Test func outage_notifiesOnlyAfterThreeChecksOverTenMinutes() {
        let outage = Tracker()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Three failed checks a minute apart: not yet (under ten minutes).
        #expect(!outage.record(.down(asked: true), at: start))
        #expect(!outage.record(.down(asked: false), at: start.addingTimeInterval(60)))
        #expect(!outage.record(.transitioning, at: start.addingTimeInterval(120)))
        #expect(outage.outage.failedChecks == 3 && outage.outage.since == start)
        #expect(!outage.record(.down(asked: false), at: start.addingTimeInterval(599)))
        #expect(outage.record(.down(asked: true), at: start.addingTimeInterval(600)), "ten minutes and more than three checks")
        #expect(outage.outage.notified)

        // Ten minutes but only two checks (iOS ran few): not yet.
        let sparse = Tracker()
        #expect(!sparse.record(.down(asked: true), at: start))
        #expect(!sparse.record(.down(asked: true), at: start.addingTimeInterval(900)))
        #expect(sparse.record(.keyCannotReconnect, at: start.addingTimeInterval(1800)), "the third check")

        // A connected read in between starts again.
        let broken = Tracker()
        _ = broken.record(.down(asked: true), at: start)
        _ = broken.record(.down(asked: true), at: start.addingTimeInterval(300))
        _ = broken.record(.connected, at: start.addingTimeInterval(400))
        #expect(broken.outage == SlskdOutage())
        #expect(!broken.record(.down(asked: true), at: start.addingTimeInterval(700)))
        #expect(!broken.record(.down(asked: true), at: start.addingTimeInterval(1000)))
        #expect(!broken.record(.down(asked: true), at: start.addingTimeInterval(1200)), "ten minutes from the new start")
        #expect(broken.outage.since == start.addingTimeInterval(700))
    }

    @Test func outage_notifiesOncePerOutage() {
        let outage = Tracker()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var told = 0
        for minute in 0..<60 where outage.record(.down(asked: minute % 2 == 0), at: start.addingTimeInterval(Double(minute) * 60)) {
            told += 1
        }
        #expect(told == 1)
        // Unknown and unreadable checks neither end the outage nor rearm it.
        #expect(!outage.record(.unknown, at: start.addingTimeInterval(4000)))
        #expect(!outage.record(.unreachable, at: start.addingTimeInterval(4100)))
        #expect(outage.outage.notified)
        // Connected again: rearmed, so the next outage is told once more.
        #expect(!outage.record(.connected, at: start.addingTimeInterval(5000)))
        #expect(!outage.outage.notified && outage.outage.since == nil)
        for minute in 0..<60 where outage.record(.down(asked: true), at: start.addingTimeInterval(6000 + Double(minute) * 60)) {
            told += 1
        }
        #expect(told == 2)
    }

    @Test func outageIsSavedAsJSON() throws {
        let outage = Tracker()
        _ = outage.record(.down(asked: true), at: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(outage.outage)
        #expect(try JSONDecoder().decode(SlskdOutage.self, from: data) == outage.outage)
    }
}
