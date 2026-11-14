import Foundation
import os
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// Round 27 R (owner, 2026-11-14): "search for all missing albums in monitored artists" (D289). The gate's
/// `ConfinedShape.missingAlbumSearch`: `POST /command` with a body of exactly `{"name": "MissingAlbumSearch"}`, named by
/// that shape and nothing else; not checked against the ledger, but only with "Allow Magpie to change your library" on,
/// no such command queued or started in a fresh `GET /command`, at least 10 minutes after the gate's own record of the
/// last one, and with that record saved before anything is sent (M6).
@Suite struct MissingAlbumSearchGateTests {
    static let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    /// A fake Lidarr: `GET /command` answers `running` (or 503), every write answers 201. The clock is the test's.
    final class Fake: Sendable {
        let env = GateEnv()
        let transport = MockTransport()
        let client: LidarrClient
        let clock = OSAllocatedUnfairLock(initialState: MissingAlbumSearchGateTests.t0)
        /// `GET /command`'s rows: (id, name, status).
        let running = OSAllocatedUnfairLock(initialState: [(Int, String, String)]())
        let commandsDown = OSAllocatedUnfairLock(initialState: false)
        /// The gate's record as it stood on disk when each write arrived (M6: saved first).
        let recordAtSend = OSAllocatedUnfairLock(initialState: [Date?]())

        init() {
            client = LidarrClient(base: testBase, apiKey: testKey, transport: transport)
            let key = MissingAlbumSearch.recordKey(scope: client.instanceScope)
            let suite = env.defaults
            transport.stub(pathSuffix: "/api/v1/command") { [running, commandsDown] _ in
                if commandsDown.withLock({ $0 }) { return MockTransport.Response(status: 503) }
                let rows = running.withLock { $0 }.map { ["id": $0.0, "name": $0.1, "status": $0.2] as [String: Any] }
                return MockTransport.Response(status: 200, body: try JSONSerialization.data(withJSONObject: rows))
            }
            for method in ["POST", "PUT", "DELETE"] {
                transport.stub(method: method, pathSuffix: "") { [recordAtSend] _ in
                    recordAtSend.withLock { $0.append(UserDefaults(suiteName: suite)?.object(forKey: key) as? Date) }
                    return MockTransport.Response(status: 201, body: json(#"{"id":90,"name":"MissingAlbumSearch","status":"queued"}"#))
                }
            }
        }

        func gate(enabled: Bool = true, confinement: WriteConfinement? = nil) async -> LidarrWriteGate {
            let clock = self.clock
            let gate = LidarrWriteGate(client: client, logURL: env.logURL, defaultsSuite: env.defaults,
                                       now: { clock.withLock { $0 } }, confinement: confinement)
            await gate.setEnabled(enabled)
            return gate
        }

        func advance(to date: Date) { clock.withLock { $0 = date } }

        var writes: [URLRequest] { transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" } }
        var commandReads: Int { transport.requests.filter { ($0.httpMethod ?? "GET") == "GET" && $0.url?.path.hasSuffix("/command") == true }.count }
    }

    private func send(_ gate: LidarrWriteGate, _ body: String? = nil, shape: ConfinedShape? = .missingAlbumSearch,
                      method: String = "POST", path: String = "command") async throws {
        let value = try body.map { try JSONDecoder().decode(JSONValue.self, from: json($0)) }
        if let shape {
            if let value {
                _ = try await gate.send(method, path, body: value, confinedAs: shape)
            } else {
                _ = try await gate.send(method, path, body: MissingAlbumSearch.Body(), confinedAs: shape)
            }
        } else {
            _ = try await gate.send(method, path, body: value ?? .object(["name": .string("MissingAlbumSearch")]))
        }
    }

    private func outcome(_ gate: LidarrWriteGate, _ body: String? = nil, shape: ConfinedShape? = .missingAlbumSearch,
                         method: String = "POST", path: String = "command") async -> String {
        do {
            try await send(gate, body, shape: shape, method: method, path: path)
            return "sent"
        } catch WriteGateError.forbidden(let why) {
            return "refused: \(why)"
        } catch {
            return "error: \(error)"
        }
    }

    @Test func missing_exactBodyOnly() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        #expect(await outcome(gate) == "sent")
        let sent = try #require(fake.writes.first)
        #expect(fake.writes.count == 1)
        #expect(sent.url?.path == "/lidarr/api/v1/command")
        let body = try #require(sent.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body.count == 1 && body["name"] as? String == "MissingAlbumSearch")
        #expect(fake.commandReads == 1, "one fresh read of Lidarr's commands before it went")
        #expect(await gate.changeLog().map(\.bodySummary) == [#"{"name":"MissingAlbumSearch"}"#])
        // Any case for the key, the value case-insensitive (another Lidarr, so the floor doesn't apply).
        let other = Fake()
        #expect(await outcome(await other.gate(), #"{"NAME":"missingalbumsearch"}"#) == "sent")
    }

    @Test(arguments: [
        #"{"name":"MissingAlbumSearch","artistId":3}"#,
        #"{"name":"MissingAlbumSearch","albumIds":[1]}"#,
        #"{"name":"MissingAlbumSearch","artistIds":[3]}"#,
        #"{"name":"MissingAlbumSearch","sendUpdatesToClient":true}"#,
        #"{"name":"MissingAlbumSearch","Name":"MissingAlbumSearch"}"#,
        #"{"name":["MissingAlbumSearch"]}"#,
    ])
    func missing_artistIdRefused(_ body: String) async throws {
        let fake = Fake()
        let gate = await fake.gate()
        #expect(await outcome(gate, body) != "sent")
        #expect(fake.transport.requests.isEmpty, "refused before anything is read or sent")
        #expect(await gate.changeLog().isEmpty)
    }

    @Test func missing_unnamedRefused() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        for body in [#"{"name":"MissingAlbumSearch"}"#, #"{"NAME":"missingAlbumSearch"}"#] {
            #expect(await outcome(gate, body, shape: nil).hasPrefix("refused"))
        }
        // Nor under any other shape a caller can name.
        for shape in [ConfinedShape.queueRestartAny, .restartSearch, .trialDelete, .keptSingleDelete, .singlesSwitch,
                      .blocklistCleanup] {
            #expect(await outcome(gate, #"{"name":"MissingAlbumSearch"}"#, shape: shape).hasPrefix("refused"), "\(shape)")
        }
        #expect(fake.transport.requests.isEmpty)
    }

    @Test func missing_shapeOnOtherRequestRefused() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        let others: [(String, String, String?)] = [
            ("POST", "command", #"{"name":"AlbumSearch","albumIds":[41]}"#),
            ("POST", "command", #"{"name":"ArtistSearch","artistId":9}"#),
            ("POST", "command", #"{"name":"RefreshArtist","artistId":9}"#),
            ("POST", "tag", #"{"label":"magpie"}"#),
            ("PUT", "album/monitor", #"{"albumIds":[41],"monitored":true}"#),
            ("DELETE", "queue/601?removeFromClient=true&blocklist=true&skipRedownload=true", nil),
            ("POST", "command/1", #"{"name":"MissingAlbumSearch"}"#),
            ("PUT", "command", #"{"name":"MissingAlbumSearch"}"#),
        ]
        for (method, path, body) in others {
            let value = try body.map { try JSONDecoder().decode(JSONValue.self, from: json($0)) }
            await #expect(throws: WriteGateError.self, "\(method) \(path)") {
                _ = try await gate.send(method, path, body: value, confinedAs: .missingAlbumSearch)
            }
        }
        #expect(fake.transport.requests.isEmpty)
        #expect(await gate.changeLog().isEmpty)
    }

    @Test func missing_switchOffRefused() async throws {
        let fake = Fake()
        let gate = await fake.gate(enabled: false)
        await #expect(throws: WriteGateError.disabled) { try await send(gate) }
        #expect(fake.transport.requests.isEmpty, "not even the command read while the switch is off")
        #expect(UserDefaults(suiteName: fake.env.defaults)?.object(forKey: MissingAlbumSearch.recordKey(scope: fake.client.instanceScope)) == nil)
    }

    @Test(arguments: ["queued", "started", "Started"])
    func missing_alreadyRunningRefused(_ status: String) async throws {
        let fake = Fake()
        fake.running.withLock { $0 = [(7, "RssSync", "started"), (8, "MissingAlbumSearch", status)] }
        let gate = await fake.gate()
        #expect(await outcome(gate) == "refused: " + MissingAlbumSearch.alreadyRunning)
        #expect(fake.writes.isEmpty)
        #expect(UserDefaults(suiteName: fake.env.defaults)?.object(forKey: MissingAlbumSearch.recordKey(scope: fake.client.instanceScope)) == nil,
                "nothing sent, so nothing recorded")
        // One that finished (or failed) doesn't hold the next back.
        fake.running.withLock { $0 = [(8, "MissingAlbumSearch", "completed"), (9, "missingalbumsearch", "failed")] }
        #expect(await outcome(gate) == "sent")
    }

    @Test func missing_commandsUnreadableRefuses() async throws {
        let fake = Fake()
        fake.commandsDown.withLock { $0 = true }
        let gate = await fake.gate()
        await #expect(throws: WriteGateError.unconfirmed) { try await send(gate) }
        #expect(fake.writes.isEmpty)
        #expect(fake.commandReads == 1)
    }

    @Test func missing_tenMinuteFloor() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        #expect(await outcome(gate) == "sent")
        fake.advance(to: Self.t0.addingTimeInterval(599))
        #expect(await outcome(gate) == "refused: " + MissingAlbumSearch.tooSoon)
        #expect(fake.writes.count == 1)
        fake.advance(to: Self.t0.addingTimeInterval(600))
        #expect(await outcome(gate) == "sent")
        #expect(fake.writes.count == 2)
        // The record is the gate's: another gate on the same Lidarr and defaults sees it.
        let again = await fake.gate()
        fake.advance(to: Self.t0.addingTimeInterval(900))
        #expect(await outcome(again) == "refused: " + MissingAlbumSearch.tooSoon)
    }

    @Test func missing_futureTimeCountsAsNow() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        fake.advance(to: Self.t0.addingTimeInterval(86_400))   // the phone's clock was a day ahead
        #expect(await outcome(gate) == "sent")
        fake.advance(to: Self.t0)                              // and is put right
        #expect(await outcome(gate) == "refused: " + MissingAlbumSearch.tooSoon)
        fake.advance(to: Self.t0.addingTimeInterval(599))
        #expect(await outcome(gate) == "refused: " + MissingAlbumSearch.tooSoon)
        fake.advance(to: Self.t0.addingTimeInterval(600))
        #expect(await outcome(gate) == "sent", "ten minutes after the clock was put right, not a day")
    }

    struct FailingStore: MissingAlbumSearchStore {
        struct Failed: Error {}
        func last(scope: String) -> Date? { nil }
        func save(_ date: Date, scope: String) throws { throw Failed() }
    }

    @Test func missing_savedBeforeSend() async throws {
        let fake = Fake()
        let gate = await fake.gate()
        #expect(await outcome(gate) == "sent")
        #expect(fake.recordAtSend.withLock { $0 } == [Self.t0], "the record was on disk when the write arrived")
        // A record that can't be saved: nothing is sent.
        let other = Fake()
        let failing = await other.gate()
        await failing.useMissingSearchStore(FailingStore())
        await #expect(throws: WriteGateError.logUnavailable) { try await send(failing) }
        #expect(other.writes.isEmpty)
        #expect(await failing.changeLog().isEmpty)
    }

    /// Supersedes the ledger confinement of commands for this shape only: an owner's library, nothing of it in the
    /// ledger, even a ledger of another Lidarr, and no confinement at all.
    @Test func missing_ledgerNotConsulted() async throws {
        for ledgerScope in ["other-lidarr", nil] as [String?] {
            let fake = Fake()
            let confinement = ledgerScope.map { scope in
                WriteConfinement(ledger: Ledger(fileURL: nil, instance: scope), roots: {
                    WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: nil, findTagId: nil)
                })
            }
            let gate = await fake.gate(confinement: confinement)
            #expect(await outcome(gate) == "sent")
            #expect(fake.writes.count == 1)
        }
    }

    /// The other commands are still the ledger's: an AlbumSearch for an owner's album is refused.
    @Test func albumSearchStillLedgerConfined() async throws {
        let fake = Fake()
        let ledger = Ledger(fileURL: nil, instance: fake.client.instanceScope)
        let gate = await fake.gate(confinement: WriteConfinement(ledger: ledger, roots: {
            WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: nil, findTagId: nil)
        }))
        #expect(await outcome(gate, #"{"name":"AlbumSearch","albumIds":[41]}"#, shape: nil)
                == "refused: a search only for albums Magpie asked for")
        #expect(await outcome(gate, #"{"name":"ArtistSearch","artistId":9}"#, shape: nil) != "sent")
        #expect(fake.writes.isEmpty)
    }
}
