import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 24 B (owner, 2026-11-08): Aurral writes for the owner's own items: delete a flow or a shared playlist, and
/// approve or deny ("Try another source") a song Aurral held for review. Aurral 2.13: `DELETE /api/playlists/flows/:id`
/// and `DELETE /api/playlists/shared-playlists/:id` queue the delete (`{success, queued, operationId}`; 404 when it isn't
/// the caller's or is gone); `POST /api/playlists/jobs/:jobId/approve` and `/deny` act only on a job `blocked` for review
/// (404 "Blocked job not found" otherwise, 409 when the job was removed meanwhile). (D207–D209)
@Suite struct Round24ManageTests {
    let stub: StubAurral
    let client: AurralClient

    init() {
        stub = StubAurral()
        stub.useAurral213()
        client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
    }

    /// A signed-in non-admin `jordan`, with or without accessFlow.
    static func jordan(_ stub: StubAurral, accessFlow: Bool) -> AurralClient {
        stub.addUser(id: 2, username: "jordan", password: "pw", role: "user")
        stub.setPermissions(.init(accessFlow: accessFlow, addArtist: true, addAlbum: true), for: "jordan")
        let session = AurralSession(username: "jordan", password: "pw",
                                    login: AurralLogin(token: stub.issueToken(username: "jordan"), expiresAt: nil,
                                                       user: AurralUser(id: 2, username: "jordan", role: "user")))
        return AurralClient(base: stub.base, session: session, transport: stub)
    }

    static func held(_ stub: StubAurral) {
        stub.setFlows([.init(id: "flow-1", name: "Weekly")])
        stub.setJobs([.init(flowId: "flow-1", artistName: "Artist", trackName: "Song", status: "blocked"),
                      .init(flowId: "flow-1", artistName: "Artist", trackName: "Other", status: "done")])
    }

    // MARK: - Routes (D207)

    @Test func routes_deleteFlow_exactPath() async throws {
        #expect(AurralRoute.route(method: "DELETE", path: "api/playlists/flows/flow-1") == .recipeFlowDelete)
        stub.setFlows([.init(id: "flow-1", name: "Weekly")])
        let result = try await client.deleteFlow("flow-1")
        #expect(result == .queued(operationId: "op-delete-flow"))
        #expect(stub.asked == ["DELETE /api/playlists/flows/flow-1"])
        let sent = try #require(stub.requests.last)
        #expect(sent.httpBody == nil && sent.url?.query == nil, "no body, no query")
    }

    @Test func routes_deleteShared_exactPath() async throws {
        #expect(AurralRoute.route(method: "DELETE", path: "api/playlists/shared-playlists/pl-1") == .chartFlowDelete)
        stub.addSharedPlaylist(id: "pl-1", name: "Mine", provider: nil, songs: [(title: "Song", artist: "Artist", durationMs: 1000)])
        let result = try await client.deleteSharedPlaylist("pl-1")
        #expect(result == .queued(operationId: "op-delete"))
        #expect(stub.asked == ["DELETE /api/playlists/shared-playlists/pl-1"])
        let sent = try #require(stub.requests.last)
        #expect(sent.httpBody == nil && sent.url?.query == nil, "no body, no query")
    }

    @Test func routes_approveDeny_plainIdOnly() async throws {
        #expect(AurralRoute.route(method: "POST", path: "api/playlists/jobs/job-1/approve") == .jobApprove)
        #expect(AurralRoute.route(method: "POST", path: "api/playlists/jobs/job-1/deny") == .jobDeny)
        #expect(AurralRoute.jobApprove.isAuthorised && AurralRoute.jobDeny.isAuthorised)
        #expect(AurralRoute.jobApprove.queryNames.isEmpty && AurralRoute.jobDeny.queryNames.isEmpty)
        for (method, path) in [("GET", "api/playlists/jobs/job-1/approve"), ("PUT", "api/playlists/jobs/job-1/deny"),
                               ("DELETE", "api/playlists/jobs/job-1/approve"), ("POST", "api/playlists/jobs/job-1/approve/x"),
                               ("POST", "api/playlists/jobs/../approve"), ("POST", "api/playlists/jobs/a b/deny"),
                               ("POST", "api/playlists/jobs/a%2Fb/deny"), ("POST", "api/playlists/jobs//approve"),
                               ("POST", "api/playlists/jobs/approve"), ("POST", "api/playlists/jobs/job-1/Approve"),
                               ("POST", "api/playlists/jobs/\(String(repeating: "a", count: 101))/approve")] {
            #expect(AurralRoute.route(method: method, path: path) == nil, "\(method) \(path)")
        }
        for bad in ["", "../settings", "a/b", "a b", "job.1", "a%2Fb", String(repeating: "a", count: 101)] {
            await #expect(throws: AurralError.self, "\(bad)") { try await client.approveHeldSong(bad) }
            await #expect(throws: AurralError.self, "\(bad)") { try await client.denyHeldSong(bad) }
            await #expect(throws: AurralError.self, "\(bad)") { _ = try await client.deleteFlow(bad) }
            await #expect(throws: AurralError.self, "\(bad)") { _ = try await client.deleteSharedPlaylist(bad) }
        }
        #expect(stub.requests.isEmpty, "nothing was sent")
    }

    @Test func routes_noOtherDelete() async throws {
        let deletes = AurralRoute.allCases.filter { $0.method == "DELETE" }
        #expect(Set(deletes) == [.chartFlowDelete, .recipeFlowDelete], "only a flow's and a shared playlist's delete")
        for path in ["api/playlists/jobs/job-1", "api/playlists/jobs/all", "api/playlists/jobs",
                     "api/playlists/shared-playlists/pl-1/tracks/job-1", "api/playlists/shared-playlists",
                     "api/playlists/flows", "api/playlists/flows/flow-1/enabled", "api/library/tracks/1",
                     "api/discover/feedback/1", "api/playlists/status", "api/auth/me", "api/users/2",
                     "api/playlists/flows/flow-1/x", "api/playlists/flows/../x"] {
            #expect(!AurralRoute.isAllowed(method: "DELETE", path: path), "DELETE \(path)")
            await #expect(throws: AurralError.forbidden("DELETE \(path)")) { _ = try await client.send(method: "DELETE", path: path) }
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func routes_noRetryNoCancel() async throws {
        let refused = ["api/playlists/jobs/job-1/retry", "api/playlists/jobs/job-1/cancel", "api/playlists/research-missing",
                       "api/playlists/jobs/job-1/manual-search", "api/playlists/jobs/job-1/manual-search/select",
                       "api/playlists/jobs/job-1/manual-search/sources", "api/playlists/jobs/job-1/files"]
        for path in refused {
            for method in ["GET", "POST", "PUT", "DELETE"] {
                #expect(!AurralRoute.isAllowed(method: method, path: path), "\(method) \(path)")
            }
        }
        let writes = AurralRoute.allCases.filter { $0.method != "GET" }
        #expect(writes.count == 18, "round 16's sixteen writes plus approve and deny")
        #expect(AurralRoute.allCases.count == 37)
    }

    // MARK: - Delete (D208)

    @Test func delete_404_isAlreadyGone() async throws {
        #expect(try await client.deleteFlow("no-such-flow") == .alreadyGone)
        #expect(try await client.deleteSharedPlaylist("no-such-playlist") == .alreadyGone)
        // Another user's flow is 404 to a non-admin (2.13 getAccessibleFlow): nothing of theirs is touched.
        stub.setFlows([.init(id: "flow-9", name: "Theirs", ownerUserId: 1)])
        let jordan = Self.jordan(stub, accessFlow: true)
        #expect(try await jordan.deleteFlow("flow-9") == .alreadyGone)
        #expect(stub.chartFlowDeletedFiles.isEmpty)
    }

    @Test func delete_403_isNotPermitted() async throws {
        stub.setFlows([.init(id: "flow-2", name: "Mine", ownerUserId: 2)])
        let jordan = Self.jordan(stub, accessFlow: false)
        await #expect(throws: AurralError.notPermitted) { _ = try await jordan.deleteFlow("flow-2") }
        await #expect(throws: AurralError.notPermitted) { _ = try await jordan.deleteSharedPlaylist("pl-2") }
        #expect(stub.asked == ["DELETE /api/playlists/flows/flow-2", "DELETE /api/playlists/shared-playlists/pl-2"],
                "each sent once, never again")
        #expect(stub.loginCount == 0, "a 403 is a permission, never a new login")
    }

    @Test func delete_sentOnce() async throws {
        let mock = MockTransport()
        mock.stub(method: "DELETE", pathSuffix: "/api/playlists/flows/flow-1", status: 500)
        mock.stub(method: "DELETE", pathSuffix: "/api/playlists/shared-playlists/pl-1", status: 502)
        let session = AurralSession(username: "jordan", password: nil,
                                    login: AurralLogin(token: "t", expiresAt: nil, user: Self.user))
        let client = AurralClient(base: URL(string: "http://nas.local:3001")!, session: session, transport: mock)
        await #expect(throws: AurralError.http(status: 500)) { _ = try await client.deleteFlow("flow-1") }
        await #expect(throws: AurralError.http(status: 502)) { _ = try await client.deleteSharedPlaylist("pl-1") }
        #expect(mock.requests.count == 2, "a failed delete is never sent again by itself")

        // The one resend: a 401 a fresh login cures (the session renewed, the same delete sent once more).
        stub.setFlows([.init(id: "flow-1", name: "Weekly")])
        stub.expireAllSessions()
        #expect(try await self.client.deleteFlow("flow-1") == .queued(operationId: "op-delete-flow"))
        #expect(stub.asked == ["DELETE /api/playlists/flows/flow-1", "POST /api/auth/login", "DELETE /api/playlists/flows/flow-1"])
    }

    static let user = AurralUser(id: 2, username: "jordan", role: "user")

    // MARK: - Approve and deny (D209)

    @Test func approve_importsTheHeldCopy() async throws {
        Self.held(stub)
        try await client.approveHeldSong("job-0")
        #expect(stub.asked == ["POST /api/playlists/jobs/job-0/approve"])
        #expect(stub.requests.last?.httpBody == nil)
        #expect(stub.jobStatus("job-0") == "done")
        #expect(stub.deniedJobs.isEmpty)
    }

    @Test func deny_blocksThatCopyAndLooksAgain() async throws {
        Self.held(stub)
        try await client.denyHeldSong("job-0")
        #expect(stub.asked == ["POST /api/playlists/jobs/job-0/deny"])
        #expect(stub.requests.last?.httpBody == nil)
        #expect(stub.jobStatus("job-0") == "pending", "Aurral looks for another source")
        #expect(stub.deniedJobs == ["job-0"])
    }

    @Test func approve_409or404_mapsToNotHeldAnyMore() async throws {
        Self.held(stub)
        // Not held (done already): Aurral's 404 "Blocked job not found".
        await #expect(throws: AurralError.notHeldAnyMore) { try await client.approveHeldSong("job-1") }
        await #expect(throws: AurralError.notHeldAnyMore) { try await client.denyHeldSong("job-1") }
        // No such job.
        await #expect(throws: AurralError.notHeldAnyMore) { try await client.approveHeldSong("job-9") }
        // Removed meanwhile: Aurral's 409 "Download job was removed".
        let mock = MockTransport()
        mock.stub(method: "POST", pathSuffix: "/approve", status: 409, body: Data(#"{"error":"Download job was removed"}"#.utf8))
        mock.stub(method: "POST", pathSuffix: "/deny", status: 409, body: Data(#"{"error":"Download job was removed"}"#.utf8))
        let session = AurralSession(username: "jordan", password: nil,
                                    login: AurralLogin(token: "t", expiresAt: nil, user: Self.user))
        let other = AurralClient(base: URL(string: "http://nas.local:3001")!, session: session, transport: mock)
        await #expect(throws: AurralError.notHeldAnyMore) { try await other.approveHeldSong("job-1") }
        await #expect(throws: AurralError.notHeldAnyMore) { try await other.denyHeldSong("job-1") }
        #expect(mock.requests.count == 2)
        // A server error stays what it is (the owner may try again).
        let failing = MockTransport()
        failing.stub(method: "POST", pathSuffix: "/approve", status: 500)
        let third = AurralClient(base: URL(string: "http://nas.local:3001")!, session: session, transport: failing)
        await #expect(throws: AurralError.http(status: 500)) { try await third.approveHeldSong("job-1") }
        #expect(failing.requests.count == 1, "sent once")
    }

    @Test func approveDeny_403_isNotPermitted() async throws {
        Self.held(stub)
        let jordan = Self.jordan(stub, accessFlow: false)
        await #expect(throws: AurralError.notPermitted) { try await jordan.approveHeldSong("job-0") }
        await #expect(throws: AurralError.notPermitted) { try await jordan.denyHeldSong("job-0") }
        #expect(stub.jobStatus("job-0") == "blocked")
    }

    // MARK: - Capability (D207)

    @Test func canManage_needsFlowsOn213AndAccessFlow() {
        let on = AurralCapabilities(appVersion: "2.13.0", apiVersion: 1, features: ["flows"])
        let off = AurralCapabilities(appVersion: "2.13.0", apiVersion: 1, features: ["discover"])
        let old = AurralCapabilities(appVersion: "2.10.0", apiVersion: nil, features: ["flows"])
        #expect(on.manage && !off.manage && !old.manage && !AurralCapabilities.none.manage)
        let admin = AurralUser(id: 1, username: "magpie", role: "admin")
        let allowed = AurralUser(id: 2, username: "jordan", role: "user",
                                 permissions: .init(accessFlow: true, addArtist: true, addAlbum: true))
        let refused = AurralUser(id: 2, username: "jordan", role: "user",
                                 permissions: .init(accessFlow: false, addArtist: true, addAlbum: true))
        let unknown = AurralUser(id: 2, username: "jordan", role: "user")
        #expect(on.canManage(as: admin) && on.canManage(as: allowed))
        #expect(!on.canManage(as: refused) && !on.canManage(as: unknown) && !on.canManage(as: nil))
        #expect(!off.canManage(as: admin))
    }
}
