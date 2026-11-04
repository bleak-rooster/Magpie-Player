import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 14 A1 (D82): the four Aurral writes, each exactly as Aurral 2.13 takes it and only on the owner's tap:
/// Add flow (`POST /api/discover/editorial/:id/library`, no body), Not for me (`POST /api/discover/feedback`),
/// Download songs (`POST /api/playlists/flows/:flowId/download`, no body) and Retry a song
/// (`POST /api/playlists/shared-playlists/:playlistId/tracks/:jobId/research`, no body).
@Suite struct Round14WritesTests {
    let stub: StubAurral
    let client: AurralClient

    init() {
        stub = StubAurral()
        stub.useAurral213()
        client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
    }

    // MARK: - Add flow

    @Test func addFlowSendsNoBodyAndReadsTheAnswer() async throws {
        let first = try await client.addEditorialPlaylist("908622995")
        #expect(first == AurralEditorialAddResult(playlistId: "static-908622995", name: "Indie Pop Picks", alreadyAdded: false,
                                                  tracksQueued: 4))
        let again = try await client.addEditorialPlaylist("908622995")
        #expect(again.alreadyAdded && again.playlistId == "static-908622995" && again.tracksQueued == nil)
        #expect(stub.asked == ["POST /api/discover/editorial/908622995/library", "POST /api/discover/editorial/908622995/library"])
        for request in stub.requests {
            #expect(request.httpBody == nil, "no body")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
            #expect(request.url?.query == nil)
        }
    }

    /// Without Aurral's accessFlow Aurral refuses (403); Magpie hides the button (`canAddFlow`) and reads the refusal
    /// as `notPermitted` (fix M2), never as "signed out".
    @Test func addFlowWithoutPermissionIsRefused() async throws {
        stub.addUser(id: 2, username: "kid", password: "pw", role: "user")
        let kid = AurralClient(base: stub.base, session: AurralSession(username: "kid", password: "pw", login: nil), transport: stub)
        #expect(try await kid.me().canAddFlow == false)
        await #expect(throws: AurralError.notPermitted) { _ = try await kid.addEditorialPlaylist("908622995") }
        await #expect(throws: AurralError.notPermitted) { _ = try await kid.downloadFlow("flow-1") }
        #expect(stub.loginCount == 1, "a 403 is not a lost session: no second login")
        #expect(stub.discoverWrites.isEmpty)
    }

    @Test func addFlowRefusesOddIdsUnsent() async throws {
        for id in ["", "abc", "1/library", "../settings", "1?x=1", String(repeating: "1", count: 21), "١٢٣"] {
            await #expect(throws: AurralError.self, "\(id)") { _ = try await client.addEditorialPlaylist(id) }
        }
        #expect(stub.requests.isEmpty)
    }

    /// Fix M2: a 401 that a fresh login doesn't cure stays `unauthorized` (signed out); a 403 is `notPermitted`.
    @Test func a401AndA403AreTold() async throws {
        let stale = AurralClient(base: stub.base, session: AurralSession(username: StubAurral.defaultUsername, password: nil,
            login: AurralLogin(token: "stale", expiresAt: nil, user: StubAurral.defaultUser)), transport: stub)
        await #expect(throws: AurralError.signInNeeded) { _ = try await stale.trending() }
        stub.setDiscoverFailure(403)
        await #expect(throws: AurralError.notPermitted) { _ = try await client.trending() }
        stub.setDiscoverFailure(401)
        await #expect(throws: AurralError.unauthorized) { _ = try await client.trending() }
    }

    // MARK: - Not for me

    /// Not for me tells Aurral `block_artist` (Aurral then leaves the artist out of this user's recommendations, as
    /// Magpie hides it), with exactly Aurral's feedback fields.
    @Test func notForMeSendsTheExactFeedbackBody() async throws {
        let artist = AurralRecommendedArtist(mbid: MBID("a74b1b7f-71a5-4011-9441-d0b5e4122711"), name: "Stub Arrows",
                                             matchedTags: ["indie pop", "dream pop"], supportingSeeds: ["Seed One"])
        try await client.notForMe(artist)
        let request = try #require(stub.requests.first)
        #expect(stub.asked == ["POST /api/discover/feedback"])
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body == #"{"action":"block_artist","artistId":"a74b1b7f-71a5-4011-9441-d0b5e4122711","artistName":"Stub Arrows","#
                + #""seedContext":["Seed One"],"sourceContext":"recommended","tagContext":["indie pop","dream pop"]}"#)
    }

    /// An artist without an MBID is named only; the context lists are capped at Aurral's 8.
    @Test func notForMeWithoutAnMBID() async throws {
        let artist = AurralRecommendedArtist(mbid: nil, name: "No Id Band", matchedTags: (1...12).map { "tag \($0)" })
        try await client.notForMe(artist)
        let body = try #require(stub.requests.first?.httpBody)
        let o = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(o.keys) == ["action", "artistName", "sourceContext", "tagContext", "seedContext"])
        #expect((o["tagContext"] as? [String])?.count == 8)
        let blank = AurralRecommendedArtist(mbid: nil, name: "  ")
        await #expect(throws: AurralError.self) { try await client.notForMe(blank) }
        #expect(stub.requests.count == 1)
    }

    // MARK: - Download songs, Retry a song

    @Test func downloadSongsAndRetryAreBodilessPosts() async throws {
        let queued = try await client.downloadFlow("flow-1")
        #expect(queued == AurralQueued(queued: true, operationId: "op-download"))
        let retried = try await client.retrySong(playlistId: "static-908622995", jobId: "job-7")
        #expect(retried.queued)
        #expect(stub.asked == ["POST /api/playlists/flows/flow-1/download",
                               "POST /api/playlists/shared-playlists/static-908622995/tracks/job-7/research"])
        #expect(stub.requests.allSatisfy { $0.httpBody == nil })
    }

    /// No download source on the server: Aurral answers 409, which Magpie reads as "Waiting for a downloader".
    @Test func downloadWithoutADownloaderSaysSo() async throws {
        stub.setDownloadSources(configured: false)
        await #expect(throws: AurralError.noDownloader) { _ = try await client.downloadFlow("flow-1") }
    }

    @Test func writesRefuseOddIdsUnsent() async throws {
        for (flow, job) in [("", "j"), ("a/b", "j"), ("p", ""), ("p", "../x"), ("p", "j/research")] {
            await #expect(throws: AurralError.self) { _ = try await client.retrySong(playlistId: flow, jobId: job) }
        }
        for flow in ["", "../settings", "a b"] {
            await #expect(throws: AurralError.self) { _ = try await client.downloadFlow(flow) }
        }
        #expect(stub.requests.isEmpty)
    }

    /// Each write is sent once: a 401 logs in again and resends (as every call does), nothing else retries.
    @Test func eachWriteIsSentOnce() async throws {
        stub.setDiscoverFailure(500)
        await #expect(throws: AurralError.http(status: 500)) { _ = try await client.addEditorialPlaylist("1") }
        await #expect(throws: AurralError.http(status: 500)) { _ = try await client.downloadFlow("f") }
        #expect(stub.requests.count == 2)
    }
}
