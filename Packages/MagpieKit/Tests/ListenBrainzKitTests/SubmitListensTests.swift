import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import ListenBrainzKit

@Suite struct SubmitListensTests {
    static func listen(_ i: Int) -> Listen {
        Listen(listenedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + i)), trackName: "T\(i)", artistName: "A")
    }
    static func payload(_ r: URLRequest) throws -> (type: String?, items: [[String: Any]]) {
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        return (body["listen_type"] as? String, body["payload"] as! [[String: Any]])
    }
    static func okTransport() -> MockTransport {
        let t = MockTransport()
        t.stub(method: "POST", pathSuffix: "/1/submit-listens", body: Data(#"{"status":"ok"}"#.utf8))
        return t
    }

    @Test func singleListenBody() async throws {
        let t = Self.okTransport()
        let client = ListenBrainzClient(transport: t, token: "tok", clientVersion: "9.9.9")
        try await client.submitListens([Listen(listenedAt: Date(timeIntervalSince1970: 1_700_000_000), trackName: "T",
                                               artistName: "A", releaseName: "B", durationMs: 200_000)], type: .single)
        let r = try #require(t.requests.last)
        #expect(r.httpMethod == "POST" && r.url?.host == "api.listenbrainz.org")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Token tok")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        #expect(body["listen_type"] as? String == "single")
        let item = (body["payload"] as! [[String: Any]])[0]
        #expect(item["listened_at"] as? Int == 1_700_000_000)
        let meta = item["track_metadata"] as! [String: Any]
        #expect(meta["artist_name"] as? String == "A" && meta["track_name"] as? String == "T" && meta["release_name"] as? String == "B")
        let info = meta["additional_info"] as! [String: Any]
        #expect(info["submission_client"] as? String == "Magpie" && info["submission_client_version"] as? String == "9.9.9")
        #expect(info["media_player"] as? String == "Magpie")
        #expect(info["duration_ms"] as? Int == 200_000)
    }

    @Test func recordingMBIDGoesInAdditionalInfo() async throws {
        let t = Self.okTransport()
        let mbid = try #require(MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d"))
        try await ListenBrainzClient(transport: t, token: "tok").submitListens(
            [Listen(listenedAt: Date(timeIntervalSince1970: 1_700_000_000), trackName: "T", artistName: "A", recordingMBID: mbid)],
            type: .single)
        let meta = try #require(Self.payload(t.requests[0]).items[0]["track_metadata"] as? [String: Any])
        let info = try #require(meta["additional_info"] as? [String: Any])
        #expect(info["recording_mbid"] as? String == "c2272a15-8f3a-4cdc-8f32-7e723352d44d")
        #expect(meta["release_name"] == nil && info["duration_ms"] == nil)
    }

    @Test func playingNowHasNoTimestamp() async throws {
        let t = Self.okTransport()
        try await ListenBrainzClient(transport: t, token: "tok").submitListens([Self.listen(1)], type: .playingNow)
        let p = try Self.payload(t.requests.last!)
        #expect(p.type == "playing_now" && p.items.count == 1 && p.items[0]["listened_at"] == nil)
    }

    @Test func singleAndPlayingNowTakeExactlyOneListen() async {
        let t = Self.okTransport()
        let client = ListenBrainzClient(transport: t, token: "tok")
        for type in [ListenType.single, .playingNow] {
            await #expect(throws: ListenBrainzError.http(status: 413)) { try await client.submitListens([Self.listen(1), Self.listen(2)], type: type) }
            await #expect(throws: ListenBrainzError.http(status: 413)) { try await client.submitListens([], type: type) }
        }
        #expect(t.requests.isEmpty)
    }

    @Test func noTokenSendsNothing() async {
        let t = MockTransport()
        await #expect(throws: ListenBrainzError.unauthorized) {
            try await ListenBrainzClient(transport: t, token: nil).submitListens([Self.listen(1)], type: .single)
        }
        #expect(t.requests.isEmpty)
    }

    @Test func importIsOneRequestAndCapped() async throws {
        let t = Self.okTransport()
        let client = ListenBrainzClient(transport: t, token: "tok")
        try await client.submitListens((0..<100).map(Self.listen), type: .importBatch)
        #expect(t.requests.count == 1)
        let p = try Self.payload(t.requests[0])
        #expect(p.type == "import" && p.items.count == 100 && p.items[99]["listened_at"] as? Int == 1_700_000_099)
        await #expect(throws: ListenBrainzError.http(status: 413)) { try await client.submitListens((0..<101).map(Self.listen), type: .importBatch) }
        #expect(t.requests.count == 1, "nothing sent for an oversized call")
    }

    @Test func unauthorizedMaps() async {
        let t = MockTransport(); t.stub(method: "POST", pathSuffix: "/1/submit-listens", status: 401)
        await #expect(throws: ListenBrainzError.unauthorized) {
            try await ListenBrainzClient(transport: t, token: "tok").submitListens([Self.listen(1)], type: .single)
        }
    }

    @Test func tokenNeverGoesToLabs() async throws {
        let t = Self.okTransport()
        try await ListenBrainzClient(transport: t, token: "tok").submitListens([Self.listen(1)], type: .single)
        #expect(t.requests.allSatisfy { $0.url?.host == "api.listenbrainz.org" })
    }

    /// T16 review: 429 and 5xx pass through as `.http` and are retried; 400, 413 and other 4xx are permanent.
    @Test(arguments: [(429, ListenBrainzError.Disposition.retry), (503, .retry), (400, .permanent)])
    func statusPassesThroughAndIsClassified(status: Int, disposition: ListenBrainzError.Disposition) async {
        let t = MockTransport(); t.stub(method: "POST", pathSuffix: "/1/submit-listens", status: status)
        await #expect(throws: ListenBrainzError.http(status: status)) {
            try await ListenBrainzClient(transport: t, token: "tok").submitListens([Self.listen(1)], type: .single)
        }
        #expect(ListenBrainzError.http(status: status).disposition == disposition)
    }

    @Test func classifier() {
        #expect(ListenBrainzError.unauthorized.disposition == .invalidToken)
        #expect(ListenBrainzError.http(status: 413).disposition == .permanent)
        #expect(ListenBrainzError.http(status: 404).disposition == .permanent)
        #expect(ListenBrainzError.http(status: 500).disposition == .retry)
        #expect(ListenBrainzError.timedOut.disposition == .retry)
        #expect(ListenBrainzError.invalidListen.disposition == .permanent)
    }

    /// T16 review: a single or import listen without `listened_at` is refused before anything is sent.
    @Test func missingListenedAtIsInvalid() async {
        let t = Self.okTransport()
        let client = ListenBrainzClient(transport: t, token: "tok")
        let bare = Listen(listenedAt: nil, trackName: "T", artistName: "A")
        await #expect(throws: ListenBrainzError.invalidListen) { try await client.submitListens([bare], type: .single) }
        await #expect(throws: ListenBrainzError.invalidListen) {
            try await client.submitListens([Self.listen(1), bare], type: .importBatch)
        }
        #expect(t.requests.isEmpty)
        try? await client.submitListens([bare], type: .playingNow)
        #expect(t.requests.count == 1, "playing_now needs no timestamp")
    }
}
