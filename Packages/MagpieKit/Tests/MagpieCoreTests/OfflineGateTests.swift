import Foundation
import MagpieTestSupport
import Testing
@testable import MagpieCore

/// Round 28 O1 (owner, 2026-11-15): one gate for everything Magpie sends (D328). Manual offline lets nothing out;
/// automatic offline only the reconnect ping (no credentials) and, while a reconnect runs, its login.
@Suite struct OfflineGateTests {
    let ping = URLRequest(url: URL(string: "http://nas.local:4533/rest/ping?v=1.16.1&c=Magpie&f=json")!)
    let pingWithAuth = URLRequest(url: URL(string: "http://nas.local:4533/rest/ping?u=jordan&t=abc&s=salt&v=1.16.1&c=Magpie&f=json")!)
    let page = URLRequest(url: URL(string: "http://nas.local:4533/rest/getAlbumList2?u=jordan&t=abc&s=salt&type=newest")!)
    var login: URLRequest {
        var r = URLRequest(url: URL(string: "http://nas.local:4533/auth/login")!)
        r.httpMethod = "POST"   // a login handed to MockTransport (check-writes allow-list: auth/login)
        r.httpBody = Data(#"{"username":"jordan","password":"pw"}"#.utf8)
        return r
    }

    func transport(_ gate: OfflineGate, _ role: OfflineGate.Role) -> (GatedTransport, MockTransport) {
        let inner = MockTransport()
        inner.stub(pathSuffix: "/rest/ping", body: Data("{}".utf8))
        inner.stub(pathSuffix: "/rest/getAlbumList2", body: Data("{}".utf8))
        inner.stub(method: "POST", pathSuffix: "/auth/login", body: Data("{}".utf8))
        return (GatedTransport(inner, gate: gate, role: role), inner)
    }

    func refused(_ t: GatedTransport, _ r: URLRequest) async -> Bool {
        do { _ = try await t.send(r); return false } catch let e as URLError { return e.code == .notConnectedToInternet } catch { return false }
    }

    @Test func gate_openPassesEverything() async throws {
        let gate = OfflineGate()
        for role in OfflineGate.Role.allCases {
            let (t, inner) = transport(gate, role)
            _ = try await t.send(page)
            _ = try await t.send(login)
            #expect(inner.requests.count == 2)
        }
        #expect(gate.refusedCount == 0 && gate.passedCount == 2 * OfflineGate.Role.allCases.count)
    }

    @Test func gate_manualRefusesEveryRoleBeforeSending() async {
        let gate = OfflineGate()
        gate.setMode(.manual)
        gate.beginReconnect()   // even a reconnect: manual offline never probes
        for role in OfflineGate.Role.allCases {
            let (t, inner) = transport(gate, role)
            for r in [ping, pingWithAuth, page, login] { #expect(await refused(t, r), "\(role) \(r.url!.path)") }
            await #expect(throws: URLError.self) { _ = try await t.send(page, maxBytes: 10) }
            #expect(inner.requests.isEmpty, "nothing reached the network for \(role)")
        }
        #expect(gate.passedCount == 0 && gate.refusedCount == 5 * OfflineGate.Role.allCases.count)
    }

    @Test func gate_automaticPassesOnlyThePingWithoutCredentials() async throws {
        let gate = OfflineGate()
        gate.setMode(.automatic)
        let (probe, probed) = transport(gate, .probe)
        _ = try await probe.send(ping)
        #expect(await refused(probe, pingWithAuth), "a ping carrying credentials is not the reconnect ping")
        #expect(await refused(probe, page))
        #expect(await refused(probe, login), "the probe transport never logs in")
        #expect(probed.requests.map { $0.url!.path } == ["/rest/ping"])
        // The main transport: the ping too (the login's own address check), never a page.
        let (main, mained) = transport(gate, .main)
        _ = try await main.send(ping)
        #expect(await refused(main, page))
        #expect(mained.requests.count == 1)
        // Outside hosts (LRCLIB, outside art, previews): nothing at all.
        let (outside, outsided) = transport(gate, .outside)
        #expect(await refused(outside, ping))
        #expect(await refused(outside, login))
        #expect(outsided.requests.isEmpty)
        // A ping with a key header is refused too.
        var keyed = ping
        keyed.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        #expect(await refused(main, keyed))
    }

    @Test func gate_automaticLoginOnlyDuringAReconnect() async throws {
        let gate = OfflineGate()
        gate.setMode(.automatic)
        let (main, inner) = transport(gate, .main)
        #expect(await refused(main, login), "no reconnect under way")
        gate.beginReconnect()
        #expect(await refused(main, login), "fix round 1 (L2): a reconnect without the login it is about to send")
        gate.permitLoginOnce(login.url!)
        _ = try await main.send(login)
        #expect(await refused(main, page), "a reconnect lets only its login out")
        var getLogin = login
        getLogin.httpMethod = "GET"
        #expect(await refused(main, getLogin), "the login is a POST with a body")
        gate.endReconnect()
        #expect(await refused(main, login))
        #expect(inner.requests.count == 1)
        // Nested reconnects count: the login stays allowed until the last one ends.
        gate.beginReconnect(); gate.beginReconnect(); gate.endReconnect()
        gate.permitLoginOnce(login.url!)
        _ = try await main.send(login)
        #expect(await refused(main, login), "fix round 1 (L2): one login per permission")
        gate.endReconnect(); gate.endReconnect()   // one too many is harmless
        #expect(await refused(main, login))
        gate.setMode(.open)
        _ = try await main.send(page)
    }

    /// Fix round 1 (L2): during a reconnect, only the exact login URL it is about to use; Aurral's login (also
    /// `…/auth/login`) on the same transport is refused.
    @Test func gate_aurralLoginRefusedDuringAReconnect() async throws {
        let gate = OfflineGate()
        gate.setMode(.automatic)
        let (main, inner) = transport(gate, .main)
        inner.stub(method: "POST", pathSuffix: "/api/auth/login", body: Data("{}".utf8))
        var aurral = URLRequest(url: URL(string: "http://aurral.local:3001/api/auth/login")!)   // auth/login
        aurral.httpMethod = "POST"
        aurral.httpBody = Data("{}".utf8)
        gate.beginReconnect()
        gate.permitLoginOnce(login.url!)
        #expect(await refused(main, aurral))
        _ = try await main.send(login)
        gate.endReconnect()
        #expect(inner.requests.map { $0.url!.host() } == ["nas.local"])
    }

    /// Fix round 1 (L3): the main transport keeps and sends no cookies.
    @Test func transport_keepsNoCookies() {
        let config = URLSessionTransport.defaultConfiguration()
        #expect(config.httpCookieStorage == nil && !config.httpShouldSetCookies && config.httpCookieAcceptPolicy == .never)
        #expect(URLSessionTransport().sessionConfiguration.httpCookieStorage == nil)
    }

    @Test func gate_forwardsTheCappedSend() async throws {
        let gate = OfflineGate()
        let (t, _) = transport(gate, .main)
        await #expect(throws: ResponseTooLarge.self) { _ = try await t.send(page, maxBytes: 1) }
        let (data, _) = try await t.send(page, maxBytes: 100)
        #expect(data == Data("{}".utf8))
    }

    @Test func gate_permitsIsPure() {
        #expect(OfflineGate.permits(page, role: .main, mode: .open, reconnecting: false))
        #expect(!OfflineGate.permits(ping, role: .main, mode: .manual, reconnecting: true))
        #expect(OfflineGate.permits(ping, role: .probe, mode: .automatic, reconnecting: false))
        #expect(OfflineGate.permits(login, role: .main, mode: .automatic, reconnecting: true, loginURL: login.url))
        #expect(!OfflineGate.permits(login, role: .main, mode: .automatic, reconnecting: true, loginURL: nil))
        #expect(!OfflineGate.permits(login, role: .main, mode: .automatic, reconnecting: false, loginURL: login.url))
        #expect(!OfflineGate.permits(URLRequest(url: URL(string: "http://nas.local/rest/ping.view?x=1")!), role: .outside,
                                     mode: .automatic, reconnecting: true))
        #expect(!OfflineGate.permits(URLRequest(url: URL(string: "http://nas.local/rest/pingX")!), role: .probe,
                                     mode: .automatic, reconnecting: false))
        #expect(!OfflineGate.permits(URLRequest(url: URL(string: "http://nas.local/rest/ping?p=enc:70")!), role: .probe,
                                     mode: .automatic, reconnecting: false), "a password parameter is a credential")
    }
}
