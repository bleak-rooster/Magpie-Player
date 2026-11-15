import Foundation
import MagpieCore
import MagpieTestSupport
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
/// Subsonic's "data not found": the library no longer has the song.
private let notFound = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"Song not found"}}}"#.utf8)

private func queryValue(_ r: URLRequest, _ name: String) -> String? {
    r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
}

/// Round 28 O4 (owner, 2026-11-15; D349, D350): plays heard offline go when the library answers again, each with when it
/// was heard, to both destinations; a find is never sent from that queue (D29, failing closed); a song the library no
/// longer has (Subsonic error 70) is dropped, not retried for ever, and plays from the phone online and offline (D55).
/// Through the app's own router and offline switch, against a mock library (never the owner's).
@MainActor @Suite(.serialized) final class ScrobbleOfflineAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "ScrobbleOfflineAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "ScrobbleOfflineAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = HostSwitchTransport()
    let engine = FakeEngine()
    /// The songs the library no longer has.
    nonisolated static let gone: Set<String> = ["gone"]

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/rest/scrobble") { r in
            MockTransport.Response(status: 200, body: Self.gone.contains(queryValue(r, "id") ?? "") ? notFound : ok)
        }
        t.stub(pathSuffix: "/rest/getSong", body: notFound)
        t.stub(pathSuffix: "/rest/stream") { _ in MockTransport.Response(status: 404, body: Data()) }
        t.stub(method: "POST", pathSuffix: "/1/submit-listens", body: Data(#"{"status":"ok"}"#.utf8))
        t.stub(pathSuffix: "/1/validate-token", body: Data(#"{"valid":true,"user_name":"jordan"}"#.utf8))
    }

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedIn(listenBrainz: Bool = true) async throws -> AppModel {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                             engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences {
            $0.downloads.preDownload = 0
            $0.scrobbling.viaNavidrome = true
            $0.scrobbling.viaListenBrainz = listenBrainz
        }
        if listenBrainz { try model.setListenBrainzToken("test-key") }
        return model
    }

    func song(_ id: String, libraryId: Int? = 1) -> Song {
        Song(id: id, title: "T\(id)", artist: "A", album: "B", albumId: "al-\(id)", duration: 200, libraryId: libraryId)
    }

    var navidromeScrobbles: [URLRequest] {
        transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/scrobble") == true && queryValue($0, "submission") == "true" }
    }

    /// Each submit-listens request's listens, as (track name, listened at).
    var listens: [[(String, Int?)]] {
        transport.inner.requests.filter { $0.url?.path.hasSuffix("/1/submit-listens") == true }.compactMap { r in
            guard let body = r.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let payload = json["payload"] as? [[String: Any]] else { return nil }
            return payload.map { (($0["track_metadata"] as? [String: Any])?["track_name"] as? String ?? "", $0["listened_at"] as? Int) }
        }
    }

    func queued(_ model: AppModel) async -> Int {
        await model.scrobbles.queue.pending(.navidrome).count + model.scrobbles.queue.pending(.listenBrainz).count
    }

    func goOffline(_ model: AppModel) {
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.isOffline)
    }

    /// Leaving Offline mode: online once the login answers (O1, design H1), then the queue drains.
    func goOnline(_ model: AppModel) async {
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually(10) { !model.isOffline })
    }

    // MARK: - D350

    @Test func scrobble_offlinePlaysSendWithTheirTime() async throws {
        let model = try await signedIn()
        goOffline(model)
        let before = transport.inner.requests.count
        try await model.scrobbles.scrobble(song("s1"), submission: true, at: t0)
        try await model.scrobbles.scrobble(song("s2"), submission: true, at: t0.addingTimeInterval(300))
        #expect(transport.inner.requests.count == before, "Offline mode sends nothing")
        #expect(await queued(model) == 4, "two plays for each destination")
        await goOnline(model)
        #expect(await eventually(10) { await self.queued(model) == 0 })
        #expect(navidromeScrobbles.map { queryValue($0, "id") } == ["s1", "s2"])
        #expect(navidromeScrobbles.map { queryValue($0, "time") } == ["1700000000000", "1700000300000"], "when they were heard")
        #expect(listens.flatMap { $0 }.map(\.1) == [1_700_000_000, 1_700_000_300])
        model.signOut()
    }

    @Test func scrobble_findsNeverSentFromTheOfflineQueue() async throws {
        let model = try await signedIn()
        goOffline(model)
        // A find heard offline is never queued.
        model.scrobbles.findsIdentity.markLanded("find-now")
        try await model.scrobbles.scrobble(song("find-now", libraryId: nil), submission: true, at: t0)
        #expect(await queued(model) == 0)
        // Queued before the Finds library was known (offline at launch), then known before the library answers: the
        // find in it is dropped unsent, and so is a song whose library the server never said (fail closed).
        try await model.scrobbles.scrobble(song("s1"), submission: true, at: t0)
        try await model.scrobbles.scrobble(song("find-later", libraryId: 7), submission: true, at: t0.addingTimeInterval(60))
        try await model.scrobbles.scrobble(song("unsure", libraryId: nil), submission: true, at: t0.addingTimeInterval(120))
        #expect(await queued(model) == 6, "three plays for each destination")
        model.scrobbles.findsIdentity.set(libraryId: 7, songIds: nil)
        await goOnline(model)
        #expect(await eventually(10) { await self.queued(model) == 0 })
        #expect(navidromeScrobbles.map { queryValue($0, "id") } == ["s1"])
        #expect(listens.flatMap { $0 }.map(\.0) == ["Ts1"])
        model.signOut()
    }

    @Test func scrobble_unknownSongDropped() async throws {
        let model = try await signedIn(listenBrainz: false)
        goOffline(model)
        try await model.scrobbles.scrobble(song("gone"), submission: true, at: t0)
        try await model.scrobbles.scrobble(song("s1"), submission: true, at: t0.addingTimeInterval(200))
        await goOnline(model)
        #expect(await eventually(10) { await self.queued(model) == 0 }, "error 70: dropped, and the rest goes on")
        #expect(navidromeScrobbles.map { queryValue($0, "id") } == ["gone", "s1"])
        await model.scrobbles.drain()
        #expect(navidromeScrobbles.count == 2, "never sent again")
        model.signOut()
    }

    // MARK: - D349, D55

    @Test func playback_songGoneFromServerPlaysFromPhone() async throws {
        let model = try await signedIn(listenBrainz: false)
        model.download([song("gone")], reason: .song)
        await model.downloads!.settled()
        model.player.play([song("gone")], startAt: 0)
        #expect(engine.setItemsCalls.last?.items.first?.1.isFileURL == true, "online: from the phone")
        goOffline(model)
        model.player.play([song("gone")], startAt: 0)
        #expect(engine.setItemsCalls.last?.items.first?.1.isFileURL == true && model.player.isPlaying, "offline too")
        #expect(model.player.lastError == nil)
        model.signOut()
    }
}
