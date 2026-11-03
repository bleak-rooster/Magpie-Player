import Foundation
import MagpieCore
import MagpieTestSupport
import os
import Testing
@testable import AurralKit

/// Round 13 item 1: Magpie signs in to Aurral as a user (Aurral 2.10.0's `POST /api/auth/login` → a Bearer session
/// token, 30 days by default, no refresh route), re-logs in once on a 401 with the password kept in the Keychain, and
/// sees only that user's flows. The API key is gone.
@Suite struct AurralLoginTests {
    let stub = StubAurral()
    let log = LogSink()

    /// Saved logins, as the app's Keychain would see them.
    final class Saved: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [AurralLogin]())
        var all: [AurralLogin] { lock.withLock { $0 } }
        var sink: @Sendable (AurralLogin) -> Void { { [lock] login in lock.withLock { $0.append(login) } } }
    }

    func signIn(_ username: String = StubAurral.defaultUsername, _ password: String = StubAurral.defaultPassword) async throws -> AurralLogin {
        try await AurralClient.signIn(base: stub.base, username: username, password: password, transport: stub, log: log.sink)
    }

    func client(_ session: AurralSession) -> AurralClient {
        AurralClient(base: stub.base, session: session, transport: stub, log: log.sink)
    }

    // MARK: - Login

    @Test func loginReturnsTokenUserAndExpiry() async throws {
        let login = try await signIn()
        #expect(!login.token.isEmpty)
        #expect(login.user.username == StubAurral.defaultUsername)
        #expect(login.user.id == 1)
        #expect(login.user.isAdmin)
        #expect(login.expiresAt != nil, "Aurral says when the session ends (ms since 1970)")
        let request = try #require(stub.requests.last)
        #expect(stub.asked == ["POST /api/auth/login"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "nothing to authorise a login with")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == nil, "never an API key")
        let body = try #require(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["username": StubAurral.defaultUsername, "password": StubAurral.defaultPassword])
    }

    @Test func wrongPasswordIsRefused() async throws {
        await #expect(throws: AurralError.badLogin) { _ = try await signIn(StubAurral.defaultUsername, "nope") }
        await #expect(throws: AurralError.badLogin) { _ = try await signIn("nobody", StubAurral.defaultPassword) }
        stub.setLoginRateLimited(true)
        await #expect(throws: AurralError.rateLimited) { _ = try await signIn() }
    }

    /// The token is sent as `Authorization: Bearer`, and `/api/health` (public) carries nothing.
    @Test func callsCarryTheBearerToken() async throws {
        let login = try await signIn()
        let client = client(AurralSession(username: StubAurral.defaultUsername, password: nil, login: login))
        stub.setFlows([.init(id: "flow-1", name: "Discover Weekly")])
        _ = try await client.health()
        _ = try await client.status()
        let health = try #require(stub.requests.first { $0.url?.path == "/api/health" })
        #expect(health.value(forHTTPHeaderField: "Authorization") == nil)
        let status = try #require(stub.requests.last)
        #expect(status.value(forHTTPHeaderField: "Authorization") == "Bearer \(login.token)")
        #expect(status.value(forHTTPHeaderField: "X-Api-Key") == nil)
    }

    // MARK: - Expiry and re-login

    /// Aurral forgot the session (expired, or signed out elsewhere): one 401, one re-login with the saved password,
    /// the call sent again, and the new login handed back to be saved.
    @Test func expiredSessionLogsInAgainOnce() async throws {
        let first = try await signIn()
        let saved = Saved()
        let session = AurralSession(username: StubAurral.defaultUsername, password: StubAurral.defaultPassword, login: first,
                                    onLogin: saved.sink)
        let client = client(session)
        stub.expireAllSessions()
        let before = stub.requests.count
        _ = try await client.status()
        #expect(Array(stub.asked.dropFirst(before)) == ["GET /api/playlists/status", "POST /api/auth/login",
                                                         "GET /api/playlists/status"])
        let renewed = try #require(saved.all.last)
        #expect(renewed.token != first.token)
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(renewed.token)")
        #expect(await session.currentToken == renewed.token)
    }

    /// A session past its `expiresAt` is renewed before anything is sent (no 401 needed).
    @Test func pastExpiryRenewsFirst() async throws {
        var first = try await signIn()
        first.expiresAt = Date(timeIntervalSinceNow: -60)
        let session = AurralSession(username: StubAurral.defaultUsername, password: StubAurral.defaultPassword, login: first)
        let before = stub.requests.count
        _ = try await client(session).status()
        #expect(Array(stub.asked.dropFirst(before)) == ["POST /api/auth/login", "GET /api/playlists/status"])
    }

    /// Several calls meeting one 401 log in once (Aurral allows 10 logins in 15 minutes).
    @Test func concurrentCallsShareOneRelogin() async throws {
        let first = try await signIn()
        let session = AurralSession(username: StubAurral.defaultUsername, password: StubAurral.defaultPassword, login: first)
        let client = client(session)
        stub.setFlows([.init(id: "flow-1", name: "Discover Weekly")])
        stub.expireAllSessions()
        let before = stub.loginCount
        async let a = client.status()
        async let b = client.status()
        async let c = client.jobs()
        _ = try await (a, b, c)
        #expect(stub.loginCount - before == 1)
    }

    /// The saved password stopped working (changed in Aurral): one try, then nothing more until the owner signs in
    /// again; never a loop of logins.
    @Test func changedPasswordStopsAndAsksToSignInAgain() async throws {
        let first = try await signIn()
        let session = AurralSession(username: StubAurral.defaultUsername, password: StubAurral.defaultPassword, login: first)
        let client = client(session)
        stub.setPassword("changed", for: StubAurral.defaultUsername)
        stub.expireAllSessions()
        let before = stub.loginCount
        await #expect(throws: AurralError.signInNeeded) { _ = try await client.status() }
        await #expect(throws: AurralError.signInNeeded) { _ = try await client.status() }
        #expect(stub.loginCount - before == 1, "the refused password is tried once")
        #expect(await session.needsSignIn)
    }

    /// Without a saved password a 401 can't be healed: sign in again.
    @Test func noPasswordMeansSignInAgain() async throws {
        let first = try await signIn()
        let client = client(AurralSession(username: StubAurral.defaultUsername, password: nil, login: first))
        stub.expireAllSessions()
        let before = stub.loginCount
        await #expect(throws: AurralError.signInNeeded) { _ = try await client.status() }
        #expect(stub.loginCount == before)
    }

    /// A network failure while logging in again is not a refused password: the session stays usable.
    @Test func networkFailureDuringReloginKeepsTheSession() async throws {
        let first = try await signIn()
        let session = AurralSession(username: StubAurral.defaultUsername, password: StubAurral.defaultPassword, login: first)
        stub.expireAllSessions()
        stub.setLoginDown(true)
        await #expect(throws: URLError.self) { _ = try await client(session).status() }
        #expect(await !session.needsSignIn)
        stub.setLoginDown(false)
        _ = try await client(session).status()
    }

    // MARK: - Sign-out

    @Test func logoutEndsTheSessionInAurral() async throws {
        let login = try await signIn()
        let client = client(AurralSession(username: StubAurral.defaultUsername, password: nil, login: login))
        try await client.logout()
        #expect(stub.asked.last == "POST /api/auth/logout")
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(login.token)")
        #expect(!stub.isSessionLive(login.token))
        // Logging out never logs in again, even when Aurral had already forgotten the session.
        let before = stub.loginCount
        try await client.logout()
        #expect(stub.loginCount == before)
    }

    // MARK: - User scoping

    /// Aurral shows an admin every user's flows; Magpie keeps only the signed-in user's (Aurral playlists are per
    /// user). A non-admin is already scoped by Aurral itself.
    @Test func onlyTheSignedInUsersFlows() async throws {
        stub.addUser(id: 2, username: "sam", password: "sam-pw", role: "user")
        stub.setFlows([.init(id: "mine", name: "Discover Weekly", ownerUserId: 1),
                       .init(id: "sams", name: "Sam's Mix", ownerUserId: 2),
                       .init(id: "legacy", name: "Old Flow", ownerUserId: nil)])
        let admin = try await signIn()
        let adminStatus = try await client(AurralSession(username: StubAurral.defaultUsername, password: nil, login: admin)).status()
        #expect(adminStatus.flows.map(\.id) == ["mine", "legacy"], "an ownerless flow is the admin's")
        #expect(adminStatus.flowStats["sams"] == nil)
        let sam = try await signIn("sam", "sam-pw")
        #expect(!sam.user.isAdmin)
        let samStatus = try await client(AurralSession(username: "sam", password: nil, login: sam)).status()
        #expect(samStatus.flows.map(\.id) == ["sams"])
        #expect(samStatus.flowStats.keys.sorted() == ["sams"])
    }

    @Test func flowOwnershipRule() {
        let me = AurralUser(id: 3, username: "Jordan", role: "user")
        #expect(AurralFlow(id: "a", name: "A", ownerUserId: 3).belongs(to: me))
        #expect(!AurralFlow(id: "a", name: "A", ownerUserId: 4, ownerUsername: "jordan").belongs(to: me), "the id wins")
        #expect(AurralFlow(id: "a", name: "A", ownerUsername: "jordan").belongs(to: me), "else the name, folded")
        #expect(!AurralFlow(id: "a", name: "A").belongs(to: me), "no owner: an admin's")
        #expect(AurralFlow(id: "a", name: "A").belongs(to: AurralUser(id: 1, username: "admin", role: "admin")))
    }

    // MARK: - Redaction

    /// The password and the token are never in a URL, a log line, an error or a description.
    @Test func secretsAreNeverLoggedOrPrinted() async throws {
        let login = try await signIn()
        let session = AurralSession(username: StubAurral.defaultUsername, password: StubAurral.defaultPassword, login: login)
        let client = client(session)
        stub.expireAllSessions()
        _ = try await client.status()
        try await client.logout()
        await #expect(throws: AurralError.badLogin) { _ = try await signIn(StubAurral.defaultUsername, "wrong-secret-pw") }
        let token = await session.currentToken ?? ""
        let secrets = [StubAurral.defaultPassword, "wrong-secret-pw", login.token, token]
        for request in stub.requests {
            for secret in secrets { #expect(request.url?.absoluteString.contains(secret) == false) }
        }
        #expect(!log.all.isEmpty)
        for line in log.all {
            for secret in secrets { #expect(!line.contains(secret), "logged: \(line)") }
        }
        #expect(log.all.filter { $0.contains("Authorization") }.allSatisfy { $0.contains("Authorization: \(Redactor.mask)") })
        for text in ["\(login)", String(reflecting: login), String(reflecting: session), String(reflecting: client),
                     "\(AurralError.badLogin)", String(reflecting: Mirror(reflecting: login).children.map(\.value))] {
            for secret in secrets { #expect(!text.contains(secret), "printed: \(text)") }
        }
    }

    /// A saved login round-trips through Codable (the Keychain), and decodes Aurral's answer leniently.
    @Test func loginDecoding() throws {
        let json = Data(#"{"token":"abc","expiresAt":1767225600000,"user":{"id":7,"username":"jordan","role":"admin","permissions":{}}}"#.utf8)
        let login = try AurralLogin.decode(json)
        #expect(login.token == "abc")
        #expect(login.user == AurralUser(id: 7, username: "jordan", role: "admin"))
        #expect(login.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
        let again = try JSONDecoder().decode(AurralLogin.self, from: JSONEncoder().encode(login))
        #expect(again == login)
        #expect(throws: AurralError.decoding) { _ = try AurralLogin.decode(Data(#"{"user":{"id":1}}"#.utf8)) }
        #expect(throws: AurralError.decoding) { _ = try AurralLogin.decode(Data("<html>".utf8)) }
    }
}
